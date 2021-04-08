defmodule AMQPHelpers.Adapters.AMQP do
  @moduledoc """
  TODO
  """

  @behaviour AMQPHelpers.Adapter

  @impl true
  defdelegate consume(channel, queue, consumer_pid, options), to: AMQP.Basic

  @impl true
  defdelegate fetch_application_channel(name), to: AMQP.Application, as: :get_channel

  @impl true
  defdelegate fetch_application_connection(name), to: AMQP.Application, as: :get_connection

  @impl true
  defdelegate get_next_delivery_tag(channel), to: AMQP.Confirm, as: :next_publish_seqno

  @impl true
  defdelegate publish(channel, exchange, routing_key, payload, options), to: AMQP.Basic

  @impl true
  defdelegate register_confirm_handler(channel, handler), to: AMQP.Confirm, as: :register_handler

  @impl true
  defdelegate register_return_handler(channel, handler), to: AMQP.Basic, as: :return

  @impl true
  defdelegate select_confirm(channel), to: AMQP.Confirm, as: :select
end
