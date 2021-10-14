defmodule AMQPHelpers.Adapters.Stub do
  @moduledoc """
  A `AMQPHelpers.Adapter` which just logs.

  This module implements a stub for `AMQPHelpers.Adapter` which mainly logs
  calls. You probably want to use this for non-integration testing or a
  development environment without a AMQP broker.
  """

  @behaviour AMQPHelpers.Adapter

  require Logger

  @impl true
  def ack(channel, delivery_tag, options) do
    log(:ack, [channel, delivery_tag, options])

    :ok
  end

  @impl true
  def cancel_consume(channel, consumer_tag, options) do
    log(:cancel_consume, [channel, consumer_tag, options])

    {:ok, consumer_tag}
  end

  @impl true
  def close_channel(channel) do
    log(:close_channel, [channel])

    :ok
  end

  @impl true
  def consume(channel, queue, consumer_pid, options) do
    log(:consume, [channel, queue, consumer_pid, options])

    {:ok, "stub"}
  end

  @impl true
  def fetch_application_channel(name) do
    log(:fetch_application_channel, [name])

    connection_name =
      :amqp
      |> Application.get_all_env()
      |> get_in([:channels, name, :connection])
      |> Kernel.||(:default)

    conn = fetch_application_connection(connection_name)

    {:ok, chan_pid} = Agent.start(fn -> %{confirm_handler: nil, delivery_tag: 1} end)
    chan = struct(AMQP.Channel, %{conn: conn, pid: chan_pid})

    {:ok, chan}
  end

  @impl true
  def enable_select_confirm(chan) do
    log(:enable_select_confirm, [chan])

    :ok
  end

  @impl true
  def fetch_application_connection(name) do
    log(:fetch_application_connection, [name])

    conn_pid = Process.spawn(fn -> Process.sleep(:infinity) end, [])
    conn = %AMQP.Connection{pid: conn_pid}

    {:ok, conn}
  end

  @impl true
  def get_next_delivery_tag(chan) do
    log(:get_next_delivery_tag, [chan])

    1
  end

  @impl true
  def nack(channel, delivery_tag, options) do
    log(:nack, [channel, delivery_tag, options])

    :ok
  end

  @impl true
  def publish(chan, exchange, routing_key, payload, options) do
    log(:publish, [chan, exchange, routing_key, payload, options])

    %{confirm_handler: confirm_handler, delivery_tag: delivery_tag} =
      Agent.get_and_update(chan.pid, fn state ->
        {state, %{state | delivery_tag: state.delivery_tag + 1}}
      end)

    unless is_nil(confirm_handler) do
      send(confirm_handler, {:basic_ack, delivery_tag, false})
    end

    :ok
  end

  @impl true
  def open_channel(conn) do
    log(:open_channel, [conn])

    :ok
  end

  @impl true
  def register_confirm_handler(chan, handler) do
    log(:register_confirm_handler, [chan, handler])

    try do
      Agent.update(chan.pid, fn state -> %{state | confirm_handler: handler} end)
    catch
      :exit, _ ->
        :ok
    end

    :ok
  end

  @impl true
  def register_return_handler(chan, handler) do
    log(:register_reeturn_handler, [chan, handler])

    :ok
  end

  @impl true
  def set_channel_options(chan, options) do
    log(:set_channel_options, [chan, options])

    :ok
  end

  defp log(fun, args) do
    args =
      args
      |> Enum.map(&inspect/1)
      |> Enum.join(", ")

    Logger.debug("#{__MODULE__}: #{fun}(#{inspect(args)})")
  end
end
