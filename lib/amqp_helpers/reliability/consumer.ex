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
          | {:channel, AMQP.Channel.t()}
          | {:channel_name, binary() | atom()}
          | {:consume_on_init, boolean()}
          | {:consume_options, keyword()}
          | {:message_handler, message_handler()}
          | {:prefetch_count, non_neg_integer()}
          | {:prefetch_size, non_neg_integer()}
          | {:queue_name, binary()}
          | {:requeue, boolean()}
          | {:retry_interval, non_neg_integer()}
          | {:shutdown_gracefully, boolean()}
          | {:shutdown_timeout, non_neg_integer()}
          | {:task_supervisor, Supervisor.supervisor()}

  @typedoc "Options used by `start_link/1` function."
  @type options :: [option()]

  @consumer_options [
    :adapter,
    :channel,
    :channel_name,
    :consume_on_init,
    :consume_options,
    :message_handler,
    :prefetch_count,
    :prefetch_size,
    :queue_name,
    :requeue,
    :retry_interval,
    :shutdown_gracefully,
    :shutdown_timeout,
    :task_supervisor
  ]
  @default_adapter AMQPHelpers.Adapters.AMQP
  @default_drain_timeout 60_000
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
  Stops consuming new messages and, optionally, waits until pending ones are
  settled.

  Cancels the broker subscription, keeps processing the messages already
  delivered to this consumer, and returns once every one of them has been
  acknowledged. Messages that the broker delivered after the subscription was
  cancelled are non-acknowledged with requeue so they are redelivered later.

  Intended to be called from `c:Application.prep_stop/1`, before the supervision
  tree is torn down, so message handlers run while the rest of the application
  is still alive. Once drained, the consumer does not resume consumption.

  Returns `{:error, :timeout}` if `shutdown_timeout` elapses before in-flight
  messages complete, `{:error, :already_draining}` if another blocking drain is
  still pending, or `{:error, reason}` if the consumer is not reachable.

  ## Options

    * `wait` - Whether to block until pending messages are settled. When
      `false`, the drain is started asynchronously and `:ok` is returned
      immediately. Defaults to `true`.
    * `timeout` - Time in milliseconds to wait for the consumer to reply when
      `wait` is `true`. Defaults to 60000 (60 seconds).
  """
  @spec cancel(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def cancel(server, opts \\ []) do
    if Keyword.get(opts, :wait, true) do
      GenServer.call(server, :cancel, Keyword.get(opts, :timeout, @default_drain_timeout))
    else
      GenServer.cast(server, :cancel)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Starts a `Consumer` process linked to the current process.

  ## Options

  The following option can be given to `Consumer` when starting it. Note that
  `message_handler` and `queue_name` **are required**.

    * `adapter` - Sets the `AMQPHelpers.Adapter`. Defaults to
      `AMQPHelpers.Adapters.AMQP`.
    * `channel` - The channel to use to consume messages. **NOTE**: do **not**
      use this for production environments because this *Consumer* does not
      supervise the given channel. Instead, use `channel_name` which makes use 
      of `AMQP.Application`.
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
    * `requeue` - Whether to requeue messages or not after a consume error.
      Defaults to `true`.
    * `retry_interval` - The number of millisecond to wait if an error happens
      when trying to consume messages or when trying to open a channel.
    * `shutdown_gracefully` - If enabled, the consumer will cancel the
      subscription when terminating. Default to `false` but enforced if
      `consumer_options` has `exclusive` set to `true`.
    * `shutdown_timeout` - Time in milliseconds that `cancel/2` waits for
      in-flight messages to complete. Defaults to 60000 (60 seconds).
    * `task_supervisor` - The `Task.Supervisor` which runs message handling
      tasks. If not provided, the `Consumer` will handle messages
      synchronously.

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
      chan: Keyword.get(opts, :channel, nil),
      chan_name: Keyword.get(opts, :channel_name, :default),
      chan_opts: Keyword.take(opts, [:prefetch_size, :prefetch_count]),
      chan_retry_ref: nil,
      consume_opts: Keyword.get(opts, :consume_options, []),
      consume_retry_ref: nil,
      consumer_tag: nil,
      message_handler: Keyword.fetch!(opts, :message_handler),
      queue_name: Keyword.fetch!(opts, :queue_name),
      requeue: Keyword.get(opts, :requeue, true),
      retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout, @default_drain_timeout),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      shutting_down: false,
      shutdown_timer: nil,
      in_flight: MapSet.new(),
      drain_caller: nil,
      drain_fenced: false
    }

    Process.flag(:trap_exit, shutdown_gracefully?(opts))

    if Keyword.get(opts, :consume_on_init, true) do
      {:ok, state, {:continue, :try_open_channel}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:cancel, _from, state = %{drain_caller: caller}) when not is_nil(caller),
    do: {:reply, {:error, :already_draining}, state}

  def handle_call(:cancel, from, state), do: start_drain(state, from)

  @impl true
  def handle_cast(:consume, state) do
    {:noreply, state, {:continue, :try_open_channel}}
  end

  def handle_cast(:cancel, state), do: start_drain(state, nil)

  @impl true
  def handle_continue({:process_message, payload, meta}, state = %{task_supervisor: nil}) do
    process_message(state.adapter, state.chan, state.message_handler, payload, meta,
      requeue: state.requeue
    )

    {:noreply, state}
  end

  def handle_continue({:process_message, payload, meta}, state = %{task_supervisor: supervisor}) do
    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        process_message(state.adapter, state.chan, state.message_handler, payload, meta,
          requeue: state.requeue
        )
      end)

    Process.monitor(pid)

    {:noreply, %{state | in_flight: MapSet.put(state.in_flight, pid)}}
  end

  def handle_continue(:try_open_channel, state = %{shutting_down: true}), do: {:noreply, state}

  def handle_continue(:try_open_channel, state = %{chan: chan, consumer_tag: nil})
      when not is_nil(chan),
      do: {:noreply, state, {:continue, :try_consume}}

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
          Logger.warning("Cannot set channel options: #{inspect(reason)}")
        end

        Process.monitor(chan.pid)

        {:noreply, %{state | chan: chan, chan_retry_ref: nil}, {:continue, :try_consume}}

      {:error, reason} ->
        Logger.warning("Cannot open channel: #{inspect(reason)}")

        ref = Process.send_after(self(), :chan_retry_timeout, retry_interval)

        {:noreply, %{state | chan_retry_ref: ref}}
    end
  end

  def handle_continue(:try_consume, state = %{shutting_down: true}), do: {:noreply, state}

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
        Logger.warning("Cannot start consuming: #{inspect(reason)}")

        ref = Process.send_after(self(), :consume_retry_timeout, retry_interval)

        {:noreply, %{state | consume_retry_ref: ref}}
    end
  end

  def handle_continue(:try_consume, state), do: {:noreply, state}

  # Channel closed

  @impl true
  def handle_info({:DOWN, _ref, :process, chan, _reason}, state = %{chan: %{pid: chan}}) do
    state = %{state | chan: nil, chan_retry_ref: nil, consumer_tag: nil}

    {:noreply, state, {:continue, :try_open_channel}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if MapSet.member?(state.in_flight, pid) do
      maybe_finish_drain(%{state | in_flight: MapSet.delete(state.in_flight, pid)})
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, :shutdown}, state = %{shutting_down: true}),
    do: {:stop, :shutdown, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Retry Opening Channel

  def handle_info(:chan_retry_timeout, state = %{chan_retry_ref: nil}), do: {:noreply, state}

  def handle_info(:chan_retry_timeout, state = %{chan_retry_ref: ref}) when is_reference(ref),
    do: {:noreply, %{state | chan_retry_ref: nil}, {:continue, :try_open_channel}}

  # Retry Consume

  def handle_info(:consume_retry_timeout, state = %{consume_retry_ref: nil}),
    do: {:noreply, state}

  def handle_info(:shutdown_timeout, state = %{drain_caller: from}) when not is_nil(from) do
    Logger.warning(
      "Drain of \"#{state.queue_name}\" queue timed out after #{state.shutdown_timeout}ms " <>
        "(in_flight=#{MapSet.size(state.in_flight)}), unacknowledged messages will be requeued"
    )

    GenServer.reply(from, {:error, :timeout})

    {:noreply, %{state | drain_caller: nil, shutdown_timer: nil}}
  end

  def handle_info(:shutdown_timeout, state), do: {:noreply, state}

  def handle_info(:drain_fence, state), do: maybe_finish_drain(%{state | drain_fenced: true})

  def handle_info(:consume_retry_timeout, state = %{consume_retry_ref: ref})
      when is_reference(ref),
      do: {:noreply, %{state | consume_retry_ref: nil}, {:continue, :try_consume}}

  # Consuming

  @impl true
  def handle_info({:basic_deliver, _payload, meta}, state = %{drain_fenced: true}) do
    requeue_message(state, meta)
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    Logger.debug("New message received", payload: payload, meta: meta)

    {:noreply, state, {:continue, {:process_message, payload, meta}}}
  end

  def handle_info({:basic_consume_ok, _meta}, state = %{queue_name: queue}) do
    Logger.info("Consuming requests from \"#{queue}\" queue.")

    {:noreply, state}
  end

  def handle_info({:basic_cancel, _meta}, state = %{shutting_down: true}),
    do: {:noreply, %{state | consumer_tag: nil}}

  def handle_info({:basic_cancel, _meta}, state) do
    Logger.warning("Consumer has been unexpectedly cancelled")

    {:noreply, %{state | consumer_tag: nil}, {:continue, :try_consume}}
  end

  def handle_info({:basic_cancel_ok, _meta}, state = %{shutting_down: true}),
    do: {:noreply, %{state | consumer_tag: nil}}

  def handle_info({:basic_cancel_ok, _meta}, state) do
    Logger.warning("Consumer cancelled")

    {:noreply, %{state | consumer_tag: nil}, {:continue, :try_consume}}
  end

  @impl true
  def terminate(
        reason,
        %{adapter: adapter, chan: chan, consumer_tag: consumer_tag, shutdown_timer: timer}
      ) do
    if timer do
      Process.cancel_timer(timer)
    end

    unless is_nil(consumer_tag) do
      adapter.cancel_consume(chan, consumer_tag, [])
    end

    reason
  end

  #
  # Helpers
  #

  @spec start_drain(map(), GenServer.from() | nil) :: {:noreply, map()}
  defp start_drain(state = %{shutting_down: true}, caller),
    do: maybe_finish_drain(await_drain(state, caller))

  defp start_drain(state, caller) do
    %{adapter: adapter, chan: chan, consumer_tag: consumer_tag, queue_name: queue} = state

    state = await_drain(%{state | shutting_down: true}, caller)

    if is_nil(chan) or is_nil(consumer_tag) do
      maybe_finish_drain(%{state | drain_fenced: true})
    else
      case adapter.cancel_consume(chan, consumer_tag, []) do
        {:ok, _consumer_tag} ->
          send(self(), :drain_fence)

          {:noreply, %{state | consumer_tag: nil}}

        {:error, reason} ->
          Logger.warning(
            "Cannot cancel subscription for \"#{queue}\" queue: #{inspect(reason)}, " <>
              "unacknowledged messages will be requeued on channel close"
          )

          maybe_finish_drain(%{state | drain_fenced: true})
      end
    end
  end

  @spec await_drain(map(), GenServer.from() | nil) :: map()
  defp await_drain(state, nil), do: state

  defp await_drain(state, caller) do
    timer = Process.send_after(self(), :shutdown_timeout, state.shutdown_timeout)

    %{state | drain_caller: caller, shutdown_timer: timer}
  end

  @spec maybe_finish_drain(map()) :: {:noreply, map()}
  defp maybe_finish_drain(state = %{drain_caller: nil}), do: {:noreply, state}

  defp maybe_finish_drain(state = %{drain_fenced: false}), do: {:noreply, state}

  defp maybe_finish_drain(state = %{drain_caller: from, in_flight: in_flight}) do
    if MapSet.size(in_flight) == 0 do
      if state.shutdown_timer do
        Process.cancel_timer(state.shutdown_timer)
      end

      Logger.info("Drained consumer for \"#{state.queue_name}\" queue")

      GenServer.reply(from, :ok)

      {:noreply, %{state | drain_caller: nil, shutdown_timer: nil}}
    else
      {:noreply, state}
    end
  end

  @spec requeue_message(map(), map()) :: {:noreply, map()}
  defp requeue_message(state = %{adapter: adapter, chan: chan}, meta) do
    with {:error, reason} <- adapter.nack(chan, meta.delivery_tag, requeue: true) do
      Logger.error("Cannot requeue #{meta.delivery_tag} message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @spec do_consume(module(), AMQP.Channel.t(), String.t(), pid() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp do_consume(adapter, channel, queue, consumer_pid \\ nil, options) do
    adapter.consume(channel, queue, consumer_pid, options)
  catch
    :exit, {{:shutdown, {_kind, _code, reason}}, _genserver_info} when is_binary(reason) ->
      {:error, reason}

    :exit, {reason, _genserver_info} ->
      {:error, reason}

    _, _ ->
      {:error, :unknown}
  end

  @spec handle_message(message_handler(), binary(), map()) :: :ok | :error | {:error, term()}
  defp handle_message(fun, payload, meta) when is_function(fun) do
    fun.(payload, meta)
  end

  defp handle_message({module, fun, args}, payload, meta) do
    apply(module, fun, [payload | [meta | args]])
  end

  @spec process_message(module, AMQP.Channel.t(), message_handler(), binary(), map(), keyword()) ::
          :ok | {:error, term()}
  defp process_message(adapter, chan, message_handler, payload, meta, opts) do
    delivery_tag = meta.delivery_tag

    case handle_message(message_handler, payload, meta) do
      :ok ->
        with {:error, reason} <- adapter.ack(chan, delivery_tag, Keyword.take(opts, [:multiple])) do
          Logger.error("Cannot acknowledge #{delivery_tag} message: #{inspect(reason)}")
        end

      _error ->
        with {:error, reason} <-
               adapter.nack(chan, delivery_tag, Keyword.take(opts, [:multiple, :requeue])) do
          Logger.error("Cannot non-acknowledge #{delivery_tag} message: #{inspect(reason)}")
        end
    end
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
