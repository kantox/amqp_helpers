defmodule AMQPHelpers.Reliability.Consumer do
  @moduledoc """
  A consumer for dealing with reliability scenarios.

  A `AMQPHelpers.Reliability.Consumer` is process which manages a reliable
  consume operation over *AMQP*, where messages are acknowledge to the broker
  after processing them. Pair this process with a
  `AMQPHelpers.Reliability.Producer` to provide reliable message exchange.

  ## Example

  This `Consumer` delivers messages to a `t:message_handler/0` which processes
  these messages. The `Consumer` enforces the usage of `AMQP.Application`, so
  after defining our application connection, channels and our message handler
  we can create an instance of this process using `start_link/1` to start
  consuming messages:

      alias AMQPHelpers.Reliability.Consumer

      my_message_handler = fn payload, meta ->
        IO.inspect({payload, meta}, label: "Got a message!")
      end

      {:ok, consumer} = Consumer.start_link(
        channel_name: :my_channel_name,
        message_handler: :my_channel_name,
        queue_name: "my_queue_name"
      )

  """

  use GenServer

  require Logger

  @typedoc """
  The function that handle messages.

  A message handler is a function that will deal with the consumed messaged. It
  will receive the payload of the message as first argument, and the message
  metadata as second argument.

  A module, function, arguments triplet can also be used. For example, if
  `{Foo, :bar, [1, 2]}` is used as message handler, the consumer will call
  `Foo.bar(message, meta, 1, 2)` to handle messages.

  This function must return `:ok` if the messages was handled successfully, so
  the consumer will acknowledge the message. Any other return value will
  non-acknowledge the message.
  """
  @type message_handler :: function() | {module(), atom(), list()}

  @typedoc "Option values used by `start_link/1` function."
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

  @typedoc "Options used by `start_link/1` function."
  @type options :: [option()]

  @consumer_options ~w(adapter channel_name consume_on_init consume_options message_handler prefetch_count prefetch_size queue_name retry_interval shutdown_gracefully)a
  @default_adapter AMQPHelpers.Adapters.AMQP
  @default_retry_interval 1_000

  #
  # Client Interface
  #

  @doc """
  Starts consuming messages.

  This function is used to start consuming messages when `consume_on_init`
  option is set to false. Not required by default but useful for testing
  purposes.
  """
  @spec consume(GenServer.server()) :: :ok
  def consume(server), do: GenServer.cast(server, :consume)

  @doc """
  Starts a `Consumer` process linked to the current process.

  ## Options

  The following option can be given to `Consumer` when starting it. Note that
  `message_handler` and `queue_name` **are required**.

    * `adapter` - Sets the `AMQPHelpers.Adapter`. Defaults to
      `AMQPHelpers.Adapters.AMQP`.
    * `channel_name` - The name of the configured channel to use. See
      `AMQP.Application` for more information. Defaults to `:default`.
    * `consume_on_init` - If the consumer should start consuming messages on init
      or not. Defaults to `true`.
    * `consume_options` - The options given to `c:AMQPHelpers.Adapter.consume/4`.
    * `message_handler` - The function that will deal with messages. Required.
    * `prefetch_count` - The maximum number of unacknowledged messages in the
       channel. See `AMQP.Basic.qos\2` for more info.
    * `prefetch_size` - The maximum number of unacknowledged bytes in the
       channel. See `AMQP.Basic.qos\2` for more info.
    * `queue_name` - The name of the queue to consume. Required.
    * `retry_interval` - The number of millisecond to wait if an error happens
      when trying to consume messages or when trying to open a channel.
    * `shutdown_gracefully` - If enabled, the consumer will cancel the
      subscription when terminating. Default to `false` but enforced if
      `consumer_options` has `exclusive` set to `true`.

  `t:GenServer.options/0` are also available. See `GenServer.start_link/2` for
  more information about these.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
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
      message_handler: Keyword.fetch!(opts, :message_handler),
      queue_name: Keyword.fetch!(opts, :queue_name),
      retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval)
    }

    Process.flag(:trap_exit, shutdown_gracefully?(opts))

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
    unless is_nil(consumer_tag) do
      adapter.cancel_consume(chan, consumer_tag, [])
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

  @spec shutdown_gracefully?(keyword()) :: boolean()
  defp shutdown_gracefully?(opts) do
    shutdown_gracefully = Keyword.get(opts, :shutdown_gracefully, false)

    exclusive =
      opts
      |> Keyword.get(:consume_options, [])
      |> Keyword.get(:exclusive, false)

    shutdown_gracefully || exclusive
  end
end
