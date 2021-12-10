defmodule AMQPHelpers.RPC do
  @moduledoc """
  A remote procedure call implementation.

  This module provide a helper function which implements the RPC pattern using
  the [Direct Reply-to](https://www.rabbitmq.com/direct-reply-to.html). This
  allows a client to send a request and receive a response synchronously,
  without having to manage any response queue.
  """

  alias AMQP.Basic, as: AMQPBasic
  alias AMQPHelpers.Adapters.AMQP, as: Adapter

  @default_timeout :timer.seconds(5)
  @publish_opts_keys ~w(mandatory immediate content_type content_encoding headers persistent correlation_id priority expiration message_id timestamp type user_id app_id)a

  @doc """
  Executes a remote procedure call.

  This function sends the given messages and waits for a response using
  [Direct Reply-to](https://www.rabbitmq.com/direct-reply-to.html).

  This function uses a `Task` internally to wait for responses. This means
  all the caveats and OTP compatibility `Task` issues apply here too. Check
  `call_nolink/7` for more information.
  """
  @spec call(
          module(),
          AMQP.Connection.t(),
          AMQPBasic.exchange(),
          AMQPBasic.routing_key(),
          AMQPBasic.payload(),
          keyword()
        ) :: {:ok, term()} | {:error, term()} | no_return()
  def call(adapter \\ Adapter, connection, exchange, routing_key, payload, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    __MODULE__
    |> Task.async(:do_call, [adapter, connection, exchange, routing_key, payload, options])
    |> Task.await(timeout)
  end

  @doc """
  Executes a remote procedure call without linking to the calling process.

  Like `call/6` but it does not link the waiting process to the calling process.
  Check `Task.Supervisor` for more information.
  """
  @spec call_nolink(
          module(),
          Supervisor.supervisor(),
          AMQP.Connection.t(),
          AMQPBasic.exchange(),
          AMQPBasic.routing_key(),
          AMQPBasic.payload(),
          keyword()
        ) :: {:ok, term()} | {:error, term()} | no_return()
  def call_nolink(
        adapter \\ Adapter,
        supervisor,
        connection,
        exchange,
        routing_key,
        payload,
        options \\ []
      ) do
    params = [adapter, connection, exchange, routing_key, payload, options]

    supervisor
    |> Task.Supervisor.async_nolink(__MODULE__, :do_call, params)
    |> Task.await()
  end

  @doc false
  @spec do_call(
          module(),
          AMQP.Connection.t(),
          AMQPBasic.exchange(),
          AMQPBasic.routing_key(),
          AMQPBasic.payload(),
          keyword()
        ) :: {:ok, term()} | {:error, term()} | no_return()
  def do_call(adapter, conn, exchange, routing_key, payload, opts) do
    publish_opts =
      opts
      |> Keyword.take(@publish_opts_keys)
      |> Keyword.put(:reply_to, "amq.rabbitmq.reply-to")

    with_channel(adapter, conn, fn chan ->
      with {:ok, consumer_tag} <-
             adapter.consume(chan, "amq.rabbitmq.reply-to", nil, no_ack: true),
           {:basic_consume_ok, %{consumer_tag: ^consumer_tag}} <-
             do_receive(&match?({:basic_consume_ok, _}, &1)),
           :ok <- adapter.publish(chan, exchange, routing_key, payload, publish_opts),
           {:basic_deliver, payload, meta} <- do_receive(&match?({:basic_deliver, _, _}, &1)) do
        {:ok, %{payload: payload, meta: meta}}
      else
        :error -> {:error, "unknown error"}
        error = {:error, _reason} -> error
        unexpected -> {:error, "got unexpected result: #{inspect(unexpected)}"}
      end
    end)
  end

  @spec do_receive(function()) :: term() | no_return()
  defp do_receive(predicate) do
    receive do
      msg ->
        if predicate.(msg) do
          msg
        else
          do_receive(predicate)
        end
    end
  end

  @spec with_channel(module(), AMQP.Connection.t(), function()) :: term() | {:error, binary()}
  defp with_channel(adapter, conn, handler) do
    case adapter.open_channel(conn) do
      {:ok, chan} ->
        result = handler.(chan)
        adapter.close_channel(chan)
        result

      {:error, reason} ->
        {:error, "cannot open channel: #{inspect(reason)}"}
    end
  end
end
