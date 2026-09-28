defmodule AMQPHelpers.Reliability.ConsumerTest do
  use ExUnit.Case, async: true

  import Mox

  alias AMQPHelpers.Reliability.Consumer

  setup :set_mox_from_context
  setup :verify_on_exit!
  setup :prepare_consumer

  describe "channel" do
    test "must be fetched as default", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      expect(AMQPMock, :fetch_application_channel, fn channel ->
        assert channel == :default
        send(parent, {ref, :fetch_application_channel})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(consumer)
    end

    @tag consumer_opts: [channel_name: :foo]
    test "must be fetched as named channel", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      expect(AMQPMock, :fetch_application_channel, fn channel ->
        assert channel == :foo
        send(parent, {ref, :fetch_application_channel})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(consumer)
    end

    @tag consumer_opts: [retry_interval: 1]
    test "must be fetched several times on failure", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      expect(AMQPMock, :fetch_application_channel, 2, fn _chan_name -> {:error, :not_now} end)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(consumer)
    end

    test "must be fetched again when channel's process die", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})

        {:ok, chan}
      end)

      Consumer.consume(consumer)

      assert_receive {^ref, :fetch_application_channel}

      Process.exit(chan.pid, :kill)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})

        Process.sleep(:infinity)
      end)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(consumer)
    end

    @tag consumer_opts: [prefetch_size: 43, prefetch_count: 11]
    test "channel must be configured with the given options", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)

      expect(AMQPMock, :set_channel_options, fn inner_chan, opts ->
        assert Keyword.fetch(opts, :prefetch_size) == {:ok, 43}
        assert Keyword.fetch(opts, :prefetch_count) == {:ok, 11}
        assert chan == inner_chan

        send(parent, {ref, :set_channel_options})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      assert_receive {^ref, :set_channel_options}
    end
  end

  describe "consume" do
    test "is performed after open channel", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)

      Consumer.consume(consumer)

      expect(AMQPMock, :consume, fn inner_chan, inner_queue, _consumer_pid, _opts ->
        assert chan == inner_chan
        assert "foo" == inner_queue

        send(parent, {ref, :consume})
      end)

      assert_receive {^ref, :consume}
    end

    @tag consumer_opts: [retry_interval: 1]
    test "must be retried several times on failure", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      expect(AMQPMock, :consume, 4, fn _chan, _queue, _pid, _opts -> {:error, :not_now} end)

      expect(AMQPMock, :consume, fn _chan, _queue, _pid, _opts ->
        send(parent, {ref, :consume})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      assert_receive {^ref, :consume}
      assert Process.alive?(consumer)
    end

    @tag skip_prepare_consumer: true
    test "calls the message handler when the message arrives" do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      message_handler = fn payload, _meta ->
        assert payload == "bar"
        send(parent, {ref, :message_handler})

        Process.sleep(:infinity)
      end

      opts = [
        adapter: AMQPMock,
        consume_on_init: false,
        queue_name: "foo",
        message_handler: message_handler
      ]

      consumer = start_supervised!({Consumer, opts}, restart: :temporary, id: :test_consumer)

      allow(AMQPMock, self(), consumer)

      send(consumer, {:basic_consume_ok, %{consumer_tag: "foo"}})
      send(consumer, {:basic_deliver, "bar", %{delivery_tag: "qux"}})

      assert_receive {^ref, :message_handler}
    end

    @tag skip_prepare_consumer: true
    test "calls the module handler when the message arrives" do
      defmodule MessageHandlerStub do
        def handle_message(payload, meta, parent, ref) do
          send(parent, {ref, :handle_message, payload, meta})
        end
      end

      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      opts = [
        adapter: AMQPMock,
        consume_on_init: false,
        queue_name: "foo",
        message_handler: {MessageHandlerStub, :handle_message, [parent, ref]}
      ]

      consumer = start_supervised!({Consumer, opts}, restart: :temporary, id: :test_consumer)

      allow(AMQPMock, self(), consumer)

      send(consumer, {:basic_consume_ok, %{consumer_tag: "foo"}})
      send(consumer, {:basic_deliver, "bar", %{delivery_tag: "qux"}})

      assert_receive {^ref, :handle_message, "bar", %{delivery_tag: "qux"}}
    end

    @tag consumer_opts: [retry_interval: 1]
    test "is retried when remotely cancelled", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)

      expect(AMQPMock, :consume, fn _chan, _queue, _consumer_pid, _opts -> {:ok, chan} end)

      expect(AMQPMock, :consume, fn _chan, _queue, _consumer_pid, _opts ->
        send(parent, {ref, :consume})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      send(consumer, {:basic_consume_ok, %{consumer_tag: "foo"}})
      send(consumer, {:basic_cancel, nil})

      assert_receive {^ref, :consume}
    end

    test "acknowledges messages after successful message handling", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :ack, fn _chan, delivery_tag, _opts ->
        assert 1 == delivery_tag
        send(parent, {ref, :ack})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      send(consumer, {:basic_consume_ok, %{consumer_tag: "foo"}})
      send(consumer, {:basic_deliver, "bar", %{delivery_tag: 1}})

      assert_receive {^ref, :ack}
    end

    @tag consumer_opts: [message_handler_result: :error]
    test "non-acknowledges messages after unsuccessfully message handling", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :nack, fn _chan, delivery_tag, _opts ->
        assert 1 == delivery_tag
        send(parent, {ref, :nack})

        Process.sleep(:infinity)
      end)

      Consumer.consume(consumer)

      send(consumer, {:basic_consume_ok, %{consumer_tag: "foo"}})
      send(consumer, {:basic_deliver, "bar", %{delivery_tag: 1}})

      assert_receive {^ref, :nack}
    end

    @tag consumer_opts: [shutdown_gracefully: true]
    test "is canceled when shutdown_gracefully is enabled", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      Consumer.consume(consumer)

      expect(AMQPMock, :cancel_consume, fn _chan, _consumer_tag, _opts ->
        send(parent, {ref, :cancel_consume})
      end)

      stop_supervised!(Consumer)

      assert_receive {^ref, :cancel_consume}
    end

    @tag consumer_opts: [consume_options: [exclusive: true]]
    test "is canceled when exclusive is enabled", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      Consumer.consume(consumer)

      expect(AMQPMock, :cancel_consume, fn _chan, _consumer_tag, _opts ->
        send(parent, {ref, :cancel_consume})
      end)

      stop_supervised!(Consumer)

      assert_receive {^ref, :cancel_consume}
    end
  end

  describe "cancel" do
    test "returns ok when there is no active subscription", %{consumer: consumer} do
      assert :ok = Consumer.cancel(consumer, timeout: 1_000)
    end

    test "returns an error when the consumer is not reachable" do
      assert {:error, {:noproc, _}} = Consumer.cancel(:no_such_consumer, timeout: 100)
    end

    test "cancels the subscription and settles delivered messages", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)
      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts -> {:ok, "tag"} end)

      expect(AMQPMock, :cancel_consume, fn _chan, consumer_tag, _opts ->
        assert consumer_tag == "tag"
        send(parent, {ref, :cancel_consume})

        {:ok, consumer_tag}
      end)

      expect(AMQPMock, :ack, fn _chan, delivery_tag, _opts ->
        assert delivery_tag == 1
        send(parent, {ref, :ack})

        :ok
      end)

      Consumer.consume(consumer)
      Process.sleep(50)

      send(consumer, {:basic_deliver, "bar", %{delivery_tag: 1}})

      assert :ok = Consumer.cancel(consumer, timeout: 1_000)
      assert_receive {^ref, :cancel_consume}
      assert_receive {^ref, :ack}
    end

    test "requeues messages delivered after the subscription is cancelled", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)
      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts -> {:ok, "tag"} end)

      expect(AMQPMock, :nack, fn _chan, delivery_tag, opts ->
        assert delivery_tag == 2
        assert Keyword.fetch!(opts, :requeue)
        send(parent, {ref, :nack})

        :ok
      end)

      Consumer.consume(consumer)
      Process.sleep(50)

      assert :ok = Consumer.cancel(consumer, timeout: 1_000)

      send(consumer, {:basic_deliver, "bar", %{delivery_tag: 2}})

      assert_receive {^ref, :nack}
    end

    test "does not resume consumption once drained", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)

      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts ->
        send(parent, {ref, :consume})

        {:ok, "tag"}
      end)

      Consumer.consume(consumer)
      assert_receive {^ref, :consume}

      assert :ok = Consumer.cancel(consumer, timeout: 1_000)

      send(consumer, {:basic_cancel_ok, %{consumer_tag: "tag"}})
      send(consumer, {:basic_cancel, %{consumer_tag: "tag"}})
      send(consumer, {:DOWN, make_ref(), :process, chan.pid, :shutdown})
      send(consumer, :chan_retry_timeout)
      send(consumer, :consume_retry_timeout)
      Consumer.consume(consumer)

      refute_receive {^ref, :consume}
      assert Process.alive?(consumer)
    end

    test "is idempotent", %{consumer: consumer} do
      assert :ok = Consumer.cancel(consumer, timeout: 1_000)
      assert :ok = Consumer.cancel(consumer, timeout: 1_000)
    end

    @tag consumer_opts: [shutdown_timeout: 50]
    test "times out when in-flight handlers do not complete", %{consumer: consumer} do
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)
      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts -> {:ok, "tag"} end)

      opts = [
        adapter: AMQPMock,
        consume_on_init: false,
        message_handler: fn _payload, _meta -> Process.sleep(:infinity) end,
        queue_name: "foo",
        shutdown_timeout: 50,
        task_supervisor: task_supervisor
      ]

      stuck = start_supervised!({Consumer, opts}, restart: :temporary, id: :stuck_consumer)
      allow(AMQPMock, self(), stuck)

      Consumer.consume(stuck)
      Process.sleep(50)

      send(stuck, {:basic_deliver, "bar", %{delivery_tag: 3}})
      Process.sleep(50)

      assert {:error, :timeout} = Consumer.cancel(stuck, timeout: 1_000)
      assert Process.alive?(consumer)
    end

    test "refuses a drain while another one is pending" do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)
      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts -> {:ok, "tag"} end)

      message_handler = fn _payload, _meta ->
        send(parent, {ref, :handler_started, self()})

        receive do
          {^ref, :release} -> :ok
        end
      end

      opts = [
        adapter: AMQPMock,
        consume_on_init: false,
        message_handler: message_handler,
        queue_name: "foo",
        shutdown_timeout: 1_000,
        task_supervisor: task_supervisor
      ]

      busy = start_supervised!({Consumer, opts}, restart: :temporary, id: :busy_consumer)
      allow(AMQPMock, self(), busy)

      Consumer.consume(busy)
      Process.sleep(50)

      send(busy, {:basic_deliver, "bar", %{delivery_tag: 4}})
      assert_receive {^ref, :handler_started, handler}

      first = Task.async(fn -> Consumer.cancel(busy, timeout: 500) end)
      Process.sleep(50)

      assert {:error, :already_draining} = Consumer.cancel(busy, timeout: 500)

      send(handler, {ref, :release})

      assert :ok = Task.await(first)
      assert Process.alive?(busy)
    end

    test "ignores a drain timeout that fires after the drain settled", %{consumer: consumer} do
      assert :ok = Consumer.cancel(consumer, timeout: 1_000)

      send(consumer, :shutdown_timeout)

      assert :ok = Consumer.cancel(consumer, timeout: 1_000)
      assert Process.alive?(consumer)
    end

    test "cancels the subscription without waiting", %{consumer: consumer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)
      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts -> {:ok, "tag"} end)

      expect(AMQPMock, :cancel_consume, fn _chan, consumer_tag, _opts ->
        send(parent, {ref, :cancel_consume})

        {:ok, consumer_tag}
      end)

      expect(AMQPMock, :nack, fn _chan, delivery_tag, opts ->
        assert delivery_tag == 5
        assert Keyword.fetch!(opts, :requeue)
        send(parent, {ref, :nack})

        :ok
      end)

      Consumer.consume(consumer)
      Process.sleep(50)

      assert :ok = Consumer.cancel(consumer, wait: false)
      assert_receive {^ref, :cancel_consume}

      send(consumer, {:basic_deliver, "bar", %{delivery_tag: 5}})

      assert_receive {^ref, :nack}
    end

    test "waits for a pending non-blocking drain to settle" do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)
      stub(AMQPMock, :fetch_application_channel, fn _chan_name -> {:ok, chan} end)
      stub(AMQPMock, :consume, fn _chan, _queue, _pid, _opts -> {:ok, "tag"} end)

      message_handler = fn _payload, _meta ->
        send(parent, {ref, :handler_started, self()})

        receive do
          {^ref, :release} -> :ok
        end
      end

      opts = [
        adapter: AMQPMock,
        consume_on_init: false,
        message_handler: message_handler,
        queue_name: "foo",
        shutdown_timeout: 1_000,
        task_supervisor: task_supervisor
      ]

      busy = start_supervised!({Consumer, opts}, restart: :temporary, id: :busy_consumer)
      allow(AMQPMock, self(), busy)

      Consumer.consume(busy)
      Process.sleep(50)

      send(busy, {:basic_deliver, "bar", %{delivery_tag: 6}})
      assert_receive {^ref, :handler_started, handler}

      assert :ok = Consumer.cancel(busy, wait: false)

      waiting = Task.async(fn -> Consumer.cancel(busy, timeout: 500) end)

      refute Task.yield(waiting, 100)

      send(handler, {ref, :release})

      assert :ok = Task.await(waiting)
    end
  end

  # TODO: Check logging

  #
  # Helpers
  #

  defp prepare_consumer(context) do
    if Map.get(context, :skip_prepare_consumer, false) do
      :ok
    else
      given_consumer_opts = Map.get(context, :consumer_opts, [])

      consumer_opts =
        Keyword.merge(
          [
            adapter: AMQPMock,
            consume_on_init: false,
            message_handler: fn _payload, _meta ->
              Keyword.get(given_consumer_opts, :message_handler_result, :ok)
            end,
            queue_name: "foo"
          ],
          given_consumer_opts
        )

      consumer = start_supervised!({Consumer, consumer_opts}, restart: :temporary)

      allow(AMQPMock, self(), consumer)

      {:ok, consumer: consumer, consumer_opts: consumer_opts}
    end
  end
end
