defmodule AMQPHelpers.Adapters.AMQP do
  @moduledoc """
  A `AMQPHelpers.Adapter` which relies in `AMQP` lib.

  This module uses `AMQP` to implement the `AMQPHelpers.Adapter`. This is
  probably the adapter that you want to use for production or integration tests
  because it uses the actual `AMQP` interface.
  """

  @behaviour AMQPHelpers.Adapter

  @impl true
  defdelegate ack(channel, delivery_tag, options), to: AMQP.Basic

  @impl true
  defdelegate consume(channel, queue, consumer_pid, options), to: AMQP.Basic

  @impl true
  defdelegate enable_select_confirm(channel), to: AMQP.Confirm, as: :select

  @impl true
  defdelegate fetch_application_channel(name), to: AMQP.Application, as: :get_channel

  @impl true
  defdelegate fetch_application_connection(name), to: AMQP.Application, as: :get_connection

  @impl true
  defdelegate get_next_delivery_tag(channel), to: AMQP.Confirm, as: :next_publish_seqno

  @impl true
  defdelegate nack(channel, delivery_tag, options), to: AMQP.Basic

  @impl true
  defdelegate publish(channel, exchange, routing_key, payload, options), to: AMQP.Basic

  @impl true
  defdelegate register_confirm_handler(channel, handler), to: AMQP.Confirm, as: :register_handler

  @impl true
  defdelegate register_return_handler(channel, handler), to: AMQP.Basic, as: :return

  @impl true
  defdelegate set_channel_options(channel, options), to: AMQP.Basic, as: :qos
end
