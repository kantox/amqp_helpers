defmodule AMQPHelpers.HighThroughput do
  @moduledoc """
  TODO
  """

  require Logger

  alias AMQP.Basic, as: AMQPBasic
  alias AMQPHelpers.Adapters.AMQP, as: Adapter

  @doc """
  TODO
  """
  @spec consume(module, AMQP.Channel.t(), String.t(), pid() | nil, keyword()) ::
          {:ok, String.t()} | AMQPBasic.error()
  def consume(adapter \\ Adapter, channel, queue, consumer \\ nil, options \\ []) do
    options = override_option(options, :no_ack, true)

    adapter.consume(channel, queue, consumer, options)
  end

  @doc """
  TODO
  """
  @spec publish(
          module,
          AMQP.Channel.t(),
          AMQPBasic.exchange(),
          AMQPBasic.routing_key(),
          AMQPBasic.payload(),
          keyword()
        ) :: :ok | AMQPBasic.error()
  def publish(adapter \\ Adapter, channel, exchange, routing_key, payload, options \\ []) do
    options = override_option(options, :persistent, false)

    adapter.publish(channel, exchange, routing_key, payload, options)
  end

  defp override_option(options, key, value) do
    case Keyword.fetch(options, key) do
      {:ok, ^value} ->
        options

      {:ok, _value} ->
        Logger.warn("Option #{key} is being overridden to a safe high-throughput use case")
        Keyword.put(options, key, value)

      :error ->
        Keyword.put(options, key, value)
    end
  end
end
