defmodule AMQPHelpers.Adapter do
  @moduledoc """
  TODO
  """

  @doc """
  TODO
  """
  @callback ack(AMQP.Channel.t(), integer(), keyword()) :: :ok | {:error, term()}

  @doc """
  TODO
  """
  @callback consume(AMQP.Channel.t(), String.t(), pid() | nil, keyword()) ::
              {:ok, String.t()} | AMQP.Basic.error()

  @doc """
  TODO
  """
  @callback fetch_application_channel(binary() | atom()) ::
              {:ok, AMQP.Channel.t()} | {:error, any()}

  @doc """
  TODO
  """
  @callback fetch_application_connection(binary() | atom()) ::
              {:ok, AMQP.Connection.t()} | {:error, any()}

  @doc """
  TODO
  """
  @callback get_next_delivery_tag(AMQP.Channel.t()) :: non_neg_integer()

  @doc """
  TODO
  """
  @callback nack(AMQP.Channel.t(), integer(), keyword()) :: :ok | {:error, term()}

  @doc """
  TODO
  """
  @callback publish(
              AMQP.Channel.t(),
              AMQP.Basic.exchange(),
              AMQP.Basic.routing_key(),
              AMQP.Basic.payload(),
              Keyword.t()
            ) :: :ok | AMQP.Basic.error()

  @doc """
  TODO
  """
  @callback register_confirm_handler(AMQP.Channel.t(), pid()) :: :ok

  @doc """
  TODO
  """
  @callback register_return_handler(AMQP.Channel.t(), pid()) :: :ok

  @doc """
  TODO
  """
  @callback select_confirm(AMQP.Channel.t()) :: :ok | {:error, any()}

  @doc """
  TODO
  """
  @callback set_channel_options(AMQP.Channel.t(), keyword()) :: :ok | {:error, any()}
end
