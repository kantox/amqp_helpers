defmodule AMQPHelpers.HighThroughput do
  @moduledoc """
  Utilities for dealing with high-throughput scenarios.

  This module provides a couple of functions which enforce some options to
  achieve good results on high throughput scenarios. Review the
  [High Throughput section](readme.html#high-throughput) for more information.
  """

  require Logger

  alias AMQP.Basic, as: AMQPBasic
  alias AMQPHelpers.Adapters.AMQP, as: Adapter

  @doc """
  Registers a queue consumer process.

  Like `AMQP.Basic.consume/4` but enforces options which play nicely with a high
  throughput scenario.
  """
  @spec consume(module, AMQP.Channel.t(), String.t(), pid() | nil, keyword()) ::
          {:ok, String.t()} | AMQPBasic.error()
  def consume(adapter \\ Adapter, channel, queue, consumer \\ nil, options \\ []) do
    options = override_option(options, :no_ack, true)

    adapter.consume(channel, queue, consumer, options)
  end

  @doc """
  Publishes a message to an Exchange.

  Like `AMQP.Basic.publish/5` but enforces options which play nicely with a high
  throughput scenario.
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
