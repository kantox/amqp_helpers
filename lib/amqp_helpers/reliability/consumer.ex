defmodule AMQPHelpers.Reliability.Consumer do
  @moduledoc """
  TODO
  """

  use GenServer

  require Logger

  @typedoc "TODO"
  @type message_handler :: function() | {module(), atom(), list()}

  @typedoc "TODO"
  @type option ::
          GenServer.option()
          | {:adapter, module()}
          | {:channel_name, binary() | atom()}
          | {:consume_on_init, boolean()}
          | {:consume_options, keyword()}
          | {:message_handler, message_handler()}
          | {:prefetch_count, non_neg_integer()}
          | {:prefetch_size, non_neg_integer()}
          | {:queue_name, binary()}
          | {:retry_interval, non_neg_integer()}
          | {:shutdown_gracefully, boolean()}

  @typedoc "TODO"
  @type options :: [option()]

  @consumer_options ~w(adapter channel_name consume_on_init message_handler prefetch_count prefetch_size queue_name retry_interval shutdown_gracefully)a
  @default_adapter AMQPHelpers.Adapters.AMQP
  @default_retry_interval 1_000

  #
  # Client Interface
  #

  @spec consume(GenServer.server()) :: :ok
  def consume(server), do: GenServer.cast(server, :consume)

  @spec start_link(keyword) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(opts) do
    {consumer_opts, genserver_opts} = Keyword.split(opts, @consumer_options)
    GenServer.start_link(__MODULE__, consumer_opts, genserver_opts)
  end

  # TODO: Add a call to check the current state
  # TODO: Add an option to crash: :never, :on_failure, :always

  #
  # Server Implementation
  #

  @impl true
  def init(opts) do
    state = %{
      adapter: Keyword.get(opts, :adapter, @default_adapter),
      chan: nil,
      chan_name: Keyword.get(opts, :channel_name, :default),
      chan_opts: Keyword.take(opts, [:prefetch_size, :prefetch_count]),
      chan_retry_ref: nil,
      consume_opts: Keyword.get(opts, :consume_options, []),
      consume_retry_ref: nil,
      consumer_tag: nil,
      message_handler: Keyword.get(opts, :message_handler),
      queue_name: Keyword.fetch!(opts, :queue_name),
      retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval)
    }

    Process.flag(:trap_exit, Keyword.get(opts, :shutdown_gracefully, false))

    if Keyword.get(opts, :consume_on_init, true) do
      {:ok, state, {:continue, :try_open_channel}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_cast(:consume, state) do
    {:noreply, state, {:continue, :try_open_channel}}
  end

  @impl true
  def handle_continue(:try_open_channel, state = %{chan: chan}) when not is_nil(chan),
    do: {:noreply, state}

  def handle_continue(:try_open_channel, state = %{chan_retry_ref: ref}) when is_reference(ref),
    do: {:noreply, state}

  def handle_continue(:try_open_channel, state = %{chan: nil, chan_retry_ref: nil}) do
    %{
      adapter: adapter,
      chan_name: chan_name,
      chan_opts: chan_opts,
      retry_interval: retry_interval
    } = state

    case adapter.fetch_application_channel(chan_name) do
      {:ok, chan} ->
        with {:error, reason} <- adapter.set_channel_options(chan, chan_opts) do
          Logger.warn("Cannot set channel options: #{inspect(reason)}")
        end

        Process.monitor(chan.pid)

        {:noreply, %{state | chan: chan, chan_retry_ref: nil}, {:continue, :try_consume}}

      {:error, reason} ->
        Logger.warn("Cannot open channel: #{inspect(reason)}")

        ref = Process.send_after(self(), :chan_retry_timeout, retry_interval)

        {:noreply, %{state | chan_retry_ref: ref}}
    end
  end

  def handle_continue(:try_consume, state = %{consume_retry_ref: nil}) do
    %{
      adapter: adapter,
      chan: chan,
      queue_name: queue,
      consume_opts: opts,
      retry_interval: retry_interval
    } = state

    case do_consume(adapter, chan, queue, opts) do
      {:ok, consumer_tag} ->
        {:noreply, %{state | consumer_tag: consumer_tag}}

      {:error, reason} ->
        Logger.warn("Cannot start consuming: #{inspect(reason)}")

        ref = Process.send_after(self(), :consume_retry_timeout, retry_interval)

        {:noreply, %{state | consume_retry_ref: ref}}
    end
  end

  # Channel closed

  @impl true
  def handle_info({:DOWN, _ref, :process, chan, _reason}, state = %{chan: %{pid: chan}}) do
    state = %{state | chan: nil, chan_retry_ref: nil, consumer_tag: nil}

    {:noreply, state, {:continue, :try_open_channel}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Retry Opening Channel

  def handle_info(:chan_retry_timeout, state = %{chan_retry_ref: nil}), do: {:noreply, state}

  def handle_info(:chan_retry_timeout, state = %{chan_retry_ref: ref}) when is_reference(ref),
    do: {:noreply, %{state | chan_retry_ref: nil}, {:continue, :try_open_channel}}

  # Retry Consume

  def handle_info(:consume_retry_timeout, state = %{consume_retry_ref: nil}),
    do: {:noreply, state}

  def handle_info(:consume_retry_timeout, state = %{consume_retry_ref: ref})
      when is_reference(ref),
      do: {:noreply, %{state | consume_retry_ref: nil}, {:continue, :try_consume}}

  # Consuming

  @impl true
  def handle_info({:basic_deliver, payload, meta = %{delivery_tag: delivery_tag}}, state) do
    %{adapter: adapter, chan: chan, message_handler: handler} = state

    Logger.debug("New message received", payload: payload, meta: meta)

    case handle_message(handler, payload, meta) do
      :ok ->
        with {:error, reason} <- adapter.ack(chan, delivery_tag, []) do
          Logger.error("Cannot acknowledge #{delivery_tag} message: #{inspect(reason)}")
        end

      _error ->
        with {:error, reason} <- adapter.nack(chan, delivery_tag, []) do
          Logger.error("Cannot non-acknowledge #{delivery_tag} message: #{inspect(reason)}")
        end
    end

    {:noreply, state}
  end

  def handle_info({:basic_consume_ok, _meta}, state = %{queue_name: queue}) do
    Logger.info("Consuming requests from \"#{queue}\" queue.")

    {:noreply, state}
  end

  def handle_info({:basic_cancel, _meta}, state) do
    Logger.warn("Consumer has been unexpectedly cancelled")

    {:noreply, %{state | consumer_tag: nil}, {:continue, :try_consume}}
  end

  def handle_info({:basic_cancel_ok, _meta}, state) do
    Logger.warn("Consumer cancelled")

    {:noreply, %{state | consumer_tag: nil}, {:continue, :try_consume}}
  end

  @impl true
  def terminate(reason, %{adapter: adapter, chan: chan, consumer_tag: consumer_tag}) do
    unless is_nil(chan) do
      unless is_nil(consumer_tag) do
        adapter.cancel_consume(chan, consumer_tag, [])
      end

      adapter.close_channel(chan)
    end

    reason
  end

  #
  # Helpers
  #

  @spec do_consume(module(), AMQP.Channel.t(), String.t(), pid() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp do_consume(adapter, channel, queue, consumer_pid \\ nil, options) do
    try do
      adapter.consume(channel, queue, consumer_pid, options)
    catch
      _, _ ->
        {:error, :unknown}
    end
  end

  @spec handle_message(message_handler(), binary(), map()) :: :ok | :error | {:error, term()}
  defp handle_message(fun, payload, meta) when is_function(fun) do
    fun.(payload, meta)
  end

  defp handle_message({module, fun, args}, payload, meta) do
    apply(module, fun, [payload | [meta | args]])
  end
end
