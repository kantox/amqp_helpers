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
    test "call the message handler when the message arrives" do
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
