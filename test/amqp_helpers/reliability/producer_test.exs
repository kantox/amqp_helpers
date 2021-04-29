defmodule AMQPHelpers.Reliability.ProducerTest do
  use ExUnit.Case, async: true

  import Mox

  alias AMQPHelpers.Reliability.Producer

  setup :set_mox_from_context
  setup :verify_on_exit!
  setup :prepare_producer

  describe "channel" do
    test "must be fetched as default", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}

      expect(AMQPMock, :fetch_application_channel, fn channel ->
        assert channel == :default
        send(parent, {ref, :fetch_application_channel})
        Process.sleep(:infinity)
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(producer)
    end

    @tag producer_opts: [channel_name: :foo]
    test "must be fetched as named channel", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}

      expect(AMQPMock, :fetch_application_channel, fn channel ->
        assert channel == :foo
        send(parent, {ref, :fetch_application_channel})
        Process.sleep(:infinity)
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(producer)
    end

    @tag producer_opts: [retry_interval: 1]
    test "must be fetched several times on failure", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}

      expect(AMQPMock, :fetch_application_channel, 2, fn _chan_name -> {:error, :not_now} end)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})
        Process.sleep(:infinity)
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(producer)
    end

    test "must be fetched again when channel's process die", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})
        {:ok, chan}
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :fetch_application_channel}

      Process.exit(chan.pid, :kill)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})
        Process.sleep(:infinity)
      end)

      assert_receive {^ref, :fetch_application_channel}
      assert Process.alive?(producer)
    end

    test "must be configured with publisher confirms", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        {:ok, chan}
      end)

      expect(AMQPMock, :register_confirm_handler, fn inner_chan, inner_producer ->
        assert inner_chan == chan
        assert inner_producer == producer

        send(parent, {ref, :register_confirm_handler})

        :ok
      end)

      expect(AMQPMock, :select_confirm, fn inner_chan ->
        assert inner_chan == chan

        send(parent, {ref, :select_confirm})

        :ok
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :register_confirm_handler}
      assert_receive {^ref, :select_confirm}
      assert Process.alive?(producer)
    end

    test "must be listened for returned messages", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        {:ok, chan}
      end)

      expect(AMQPMock, :register_return_handler, fn inner_chan, inner_producer ->
        assert inner_chan == chan
        assert inner_producer == producer

        send(parent, {ref, :register_return_handler})

        :ok
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :register_return_handler}
      assert Process.alive?(producer)
    end
  end

  describe "publish/6" do
    test "must send a message", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}
      chan = %{pid: spawn(fn -> Process.sleep(:infinity) end)}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :fetch_application_channel, fn _chan_name ->
        send(parent, {ref, :fetch_application_channel})
        {:ok, chan}
      end)

      expect(AMQPMock, :get_next_delivery_tag, fn _chan ->
        send(parent, {ref, :get_next_delivery_tag})
        9001
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :fetch_application_channel}
      assert_receive {^ref, :get_next_delivery_tag}

      {:ok, acknowledger} =
        Task.start(fn ->
          assert_receive {^ref, :publish}
          send(producer, {:basic_ack, 9001, false})
        end)

      expect(AMQPMock, :publish, fn inner_chan, exchange, routing_key, payload, opts ->
        assert inner_chan == chan
        assert exchange == "foo"
        assert routing_key == "bar"
        assert payload == "qux"
        assert Keyword.get(opts, :message_id) == "id"
        assert Keyword.get(opts, :foo_bar)

        send(acknowledger, {ref, :publish})

        :ok
      end)

      result = Producer.publish(producer, "foo", "bar", "qux", message_id: "id", foo_bar: true)

      assert result == :ok
      assert Process.alive?(producer)
    end

    test "enforce reliable delivery options", %{producer: producer} do
      ref = make_ref()

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      Producer.setup_channel(producer)

      {:ok, acknowledger} =
        Task.start(fn ->
          assert_receive {^ref, :publish}
          send(producer, {:basic_ack, 1, false})
        end)

      expect(AMQPMock, :publish, fn _chan, _exchange, _routing_key, _payload, opts ->
        assert Keyword.get(opts, :mandatory)
        assert Keyword.get(opts, :persistent)

        send(acknowledger, {ref, :publish})

        :ok
      end)

      Producer.publish(producer, "foo", "bar", "qux", message_id: "id", foo_bar: true)

      assert Process.alive?(producer)
    end

    test "return an error if the channel is not open", %{producer: producer} do
      stub(AMQPMock, :fetch_application_channel, fn _conn -> {:error, :not_now} end)

      Producer.setup_channel(producer)

      result = Producer.publish(producer, "foo", "bar", "qux", message_id: "id")

      assert result == {:error, :no_channel}
    end

    test "returns an error when negative acknowledge is received", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :get_next_delivery_tag, fn _chan ->
        send(parent, {ref, :get_next_delivery_tag})
        14
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :get_next_delivery_tag}

      {:ok, acknowledger} =
        Task.start(fn ->
          assert_receive {^ref, :publish}
          send(producer, {:basic_nack, 14, false})
        end)

      expect(AMQPMock, :publish, fn _chan, _exchange, _routing_key, _payload, _opts ->
        send(acknowledger, {ref, :publish})

        :ok
      end)

      result = Producer.publish(producer, "foo", "bar", "qux", message_id: "id")

      assert result == {:error, :nack}
      assert Process.alive?(producer)
    end

    test "returns an error when the message is returned", %{producer: producer} do
      {parent, ref} = {self(), make_ref()}

      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      expect(AMQPMock, :get_next_delivery_tag, fn _chan ->
        send(parent, {ref, :get_next_delivery_tag})
        1
      end)

      Producer.setup_channel(producer)

      assert_receive {^ref, :get_next_delivery_tag}

      {:ok, acknowledger} =
        Task.start(fn ->
          assert_receive {^ref, :publish}
          send(producer, {:basic_return, nil, %{message_id: "id", reply_text: "foobar"}})
        end)

      expect(AMQPMock, :publish, fn _chan, _exchange, _routing_key, _payload, _opts ->
        send(acknowledger, {ref, :publish})

        :ok
      end)

      result = Producer.publish(producer, "foo", "bar", "qux", message_id: "id", foo_bar: true)

      assert result == {:error, "foobar"}
      assert Process.alive?(producer)
    end

    test "returns the error given from the adapter", %{producer: producer} do
      stub_with(AMQPMock, AMQPHelpers.Adapters.Stub)

      Producer.setup_channel(producer)

      expect(AMQPMock, :publish, fn _chan, _exchange, _routing_key, _payload, _opts ->
        {:error, :foo}
      end)

      result = Producer.publish(producer, "foo", "bar", "qux", message_id: "id", foo_bar: true)

      assert result == {:error, :foo}
      assert Process.alive?(producer)
    end
  end

  #
  # Helpers
  #

  defp prepare_producer(context) do
    producer_opts =
      Keyword.merge(
        [adapter: AMQPMock, setup_channel_on_init: false],
        Map.get(context, :producer_opts, [])
      )

    producer = start_supervised!({Producer, producer_opts}, restart: :temporary)

    allow(AMQPMock, self(), producer)

    {:ok, producer: producer, producer_opts: producer_opts}
  end
end
