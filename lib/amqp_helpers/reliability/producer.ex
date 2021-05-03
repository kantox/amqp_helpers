defmodule AMQPHelpers.Reliability.Producer do
  @moduledoc """
  TODO
  """

  # TODO: add setup_channel_on_publish (default to true)

  use GenServer

  alias AMQPHelpers.WaitGroup

  @typedoc "TODO"
  @type option ::
          GenServer.option()
          | {:adapter, module()}
          | {:setup_channel_on_init, boolean}
          | {:channel_name, binary() | atom()}
          | {:retry_interval, non_neg_integer()}

  @typedoc "TODO"
  @type options :: [option()]

  @default_adapter AMQPHelpers.Adapters.AMQP
  @default_publish_timeout 5_000
  @default_retry_interval 1_000
  @producer_options ~w(adapter setup_channel_on_init channel_name retry_interval)a

  #
  # Client Interface
  #

  @doc """
  """
  @spec publish(
          GenServer.server(),
          AMQP.Basic.exchange(),
          AMQP.Basic.routing_key(),
          AMQP.Basic.payload(),
          keyword(),
          timeout()
        ) :: :ok | {:error, term()}
  def publish(
        server,
        exchange,
        routing_key,
        payload,
        opts,
        timeout \\ @default_publish_timeout
      ),
      do: GenServer.call(server, {:publish, {exchange, routing_key, payload, opts}}, timeout)

  @doc """
  TODO
  """
  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    {producer_opts, genserver_opts} = Keyword.split(opts, @producer_options)

    GenServer.start_link(__MODULE__, producer_opts, genserver_opts)
  end

  @doc """
  TODO
  """
  @spec setup_channel(GenServer.server()) :: :ok
  def setup_channel(producer), do: GenServer.cast(producer, :setup_channel)

  #
  # Server Implementation
  #

  @impl true
  def init(opts) do
    state = %{
      adapter: Keyword.get(opts, :adapter, @default_adapter),
      chan: nil,
      chan_monitor: nil,
      chan_name: Keyword.get(opts, :channel_name, :default),
      delivery_tag: 1,
      retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval),
      wait_group: WaitGroup.new()
    }

    if Keyword.get(opts, :setup_channel_on_init, true) do
      {:ok, state, {:continue, :setup_channel}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:publish, _params}, _from, state = %{chan: nil}) do
    {:reply, {:error, :no_channel}, state}
  end

  def handle_call({:publish, params}, from, state) do
    {exchange, routing_key, payload, opts} = params
    %{adapter: adapter, chan: chan, delivery_tag: delivery_tag, wait_group: wait_group} = state

    publish_opts =
      opts
      |> Keyword.put_new(:mandatory, true)
      |> Keyword.put_new(:persistent, true)

    case adapter.publish(chan, exchange, routing_key, payload, publish_opts) do
      :ok ->
        message_id = Keyword.fetch!(opts, :message_id)

        state = %{
          state
          | delivery_tag: delivery_tag + 1,
            wait_group: WaitGroup.put(wait_group, delivery_tag, message_id, from)
        }

        {:noreply, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:setup_channel, state) do
    {:noreply, state, {:continue, :setup_channel}}
  end

  @impl true
  def handle_continue(:setup_channel, state = %{chan: nil}) do
    %{adapter: adapter, chan_name: chan_name, retry_interval: retry_interval} = state

    with {:ok, chan} <- adapter.fetch_application_channel(chan_name),
         {:ok, delivery_tag} <- enable_publisher_confirms(adapter, chan) do
      monitor = Process.monitor(chan.pid)

      {:noreply, %{state | chan: chan, chan_monitor: monitor, delivery_tag: delivery_tag}}
    else
      {:error, _reason} ->
        Process.send_after(self(), :setup_channel, retry_interval)

        {:noreply, state}

      :error ->
        {:stop, "cannot enable publisher confirms", state}
    end
  end

  def handle_continue({:reply, delivery_tag_or_message_id, response}, state) do
    %{wait_group: wait_group} = state

    case WaitGroup.fetch(wait_group, delivery_tag_or_message_id) do
      {:ok, waiting_list} ->
        Enum.each(waiting_list, fn {_delivery_tag_or_message_id, from} ->
          GenServer.reply(from, response)
        end)

        {:noreply,
         %{state | wait_group: WaitGroup.delete(wait_group, delivery_tag_or_message_id)}}

      _other ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:setup_channel, state) do
    {:noreply, state, {:continue, :setup_channel}}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        state = %{chan: %{pid: pid}, chan_monitor: monitor}
      ) do
    Process.demonitor(monitor)
    {:noreply, %{state | chan: nil, chan_monitor: nil}, {:continue, :setup_channel}}
  end

  def handle_info({:basic_return, _message, %{message_id: message_id, reply_text: reason}}, state) do
    {:noreply, state, {:continue, {:reply, message_id, {:error, reason}}}}
  end

  def handle_info({:basic_ack, delivery_tag, _multiple}, state) do
    {:noreply, state, {:continue, {:reply, delivery_tag, :ok}}}
  end

  def handle_info({:basic_nack, delivery_tag, _multiple}, state) do
    {:noreply, state, {:continue, {:reply, delivery_tag, {:error, :nack}}}}
  end

  @impl true
  def terminate(_reason, %{chan_monitor: monitor}) when is_reference(monitor) do
    Process.demonitor(monitor)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @spec enable_publisher_confirms(module, AMQP.Channel.t()) ::
          {:ok, non_neg_integer()} | :error
  defp enable_publisher_confirms(adapter, chan) do
    with :ok <- adapter.register_confirm_handler(chan, self()),
         :ok <- adapter.register_return_handler(chan, self()),
         :ok <- adapter.enable_select_confirm(chan) do
      {:ok, adapter.get_next_delivery_tag(chan)}
    end
  end
end
