defmodule AMQPHelpers.Adapter do
  @moduledoc """
  A [behaviour](https://elixir-lang.org/getting-started/typespecs-and-behaviours.html#behaviours)
  for the `AMQP` client implementation.

  This module declares a behaviour for the `AMQP` library, allowing us to use
  different implementations of the underlaying *AMQP* interface. Check out the
  `AMQPHelpers.Adapters.Stub` and `AMQPHelpers.Adapters.AMQP` for actual
  implementations of this behaviour.

  This behaviour also enables us to mock this interface in tests using libraries
  like [Mox](https://hexdocs.pm/mox/Mox.html). Check out the libraries tests for
  examples about this usage.
  """

  @doc """
  Acknowledges one or more messages.

  See `AMQP.Basic.ack/3`.
  """
  @callback ack(channel :: AMQP.Channel.t(), delivery_tag :: integer(), options :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Stops the given consumer from consuming.

  See `AMQP.Basic.cancel/3`.
  """
  @callback cancel_consume(
              channel :: AMQP.Channel.t(),
              consumer_tag :: String.t(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Closes an open Channel.

  See `AMQP.Channel.close/1`.
  """
  @callback close_channel(channel :: AMQP.Channel.t()) :: :ok | {:error, term()}

  @doc """
  Registers a queue consumer process.

  See `AMQP.Basic.consume/4`.
  """
  @callback consume(
              channel :: AMQP.Channel.t(),
              queue :: String.t(),
              consumer :: pid() | nil,
              options :: keyword()
            ) :: {:ok, String.t()} | AMQP.Basic.error()

  @doc """
  Activates publishing confirmations on the channel.

  See `AMQP.Confirm.select/1`.
  """
  @callback enable_select_confirm(channel :: AMQP.Channel.t()) :: :ok | {:error, any()}

  @doc """
  Provides an easy way to access an `t:AMQP.Channel.t/0`.

  See `AMQP.Application.get_channel/1`.
  """
  @callback fetch_application_channel(name :: binary() | atom()) ::
              {:ok, AMQP.Channel.t()} | {:error, any()}

  @doc """
  Provides an easy way to access an `t:AMQP.Connection.t/0`.

  See `AMQP.Application.get_connection/1`.
  """
  @callback fetch_application_connection(name :: binary() | atom()) ::
              {:ok, AMQP.Connection.t()} | {:error, any()}

  @doc """
  Returns the next message sequence number.

  See `AMQP.Confirm.next_publish_seqno/1`.
  """
  @callback get_next_delivery_tag(channel :: AMQP.Channel.t()) :: non_neg_integer()

  @doc """
  Negative acknowledges of one or more messages.

  See `AMQP.Basic.nack/3`.
  """
  @callback nack(channel :: AMQP.Channel.t(), delivery_tag :: integer(), options :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Publishes a message to an Exchange.

  See `AMQP.Basic.publish/5`.
  """
  @callback publish(
              channel :: AMQP.Channel.t(),
              exchange :: AMQP.Basic.exchange(),
              routing_key :: AMQP.Basic.routing_key(),
              payload :: AMQP.Basic.payload(),
              options :: Keyword.t()
            ) :: :ok | AMQP.Basic.error()

  @doc """
  Register a handler for confirms on channel.

  See `AMQP.Confirm.register_handler/2`.
  """
  @callback register_confirm_handler(channel :: AMQP.Channel.t(), handler :: pid()) :: :ok

  @doc """
  Registers a handler to deal with returned messages.

  See `AMQP.Basic.return/2`.
  """
  @callback register_return_handler(channel :: AMQP.Channel.t(), handler :: pid()) :: :ok

  @doc """
  Sets the message prefetch count or prefetch size.

  See `AMQP.Basic.qos/2`.
  """
  @callback set_channel_options(channel :: AMQP.Channel.t(), options :: keyword()) ::
              :ok | {:error, any()}
end
