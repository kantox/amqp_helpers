defmodule AMQPHelpers.RPCTest do
  use ExUnit.Case, async: false

  alias AMQPHelpers.RPC

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "call/6" do
    setup context do
      Mox.stub(AMQPMock, :open_channel, fn _conn -> {:ok, nil} end)

      Mox.stub(AMQPMock, :close_channel, fn _chan -> :ok end)

      Mox.stub(AMQPMock, :publish, fn _chan, _exchange, _routing_key, _payload, _opts ->
        send(self(), {:basic_deliver, Map.get(context, :payload, "payload"), []})

        :ok
      end)

      Mox.stub(AMQPMock, :consume, fn _chan, _queu, _pid, _opts ->
        send(self(), {:basic_consume_ok, %{consumer_tag: "consumer_tag"}})

        {:ok, Map.get(context, :consumer_tag, "consumer_tag")}
      end)

      :ok
    end

    @tag payload: "foo"
    test "consume messages from the direct reply-to pseudo-queue in no_ack mode" do
      Mox.expect(AMQPMock, :consume, fn _chan, "amq.rabbitmq.reply-to", _pid, opts ->
        assert Keyword.get(opts, :no_ack, false)

        send(self(), {:basic_consume_ok, %{consumer_tag: "consumer_tag"}})

        {:ok, "consumer_tag"}
      end)

      assert {:ok, %{payload: "foo"}} = RPC.call(AMQPMock, :conn, "x", "y", "z")
    end

    test "send messages to the direct reply-to pseudo-queue" do
      Mox.expect(AMQPMock, :publish, fn _chan, "foo", "bar", "qux", _opts ->
        send(self(), {:basic_deliver, "foobar", []})

        :ok
      end)

      RPC.call(AMQPMock, :conn, "foo", "bar", "qux")
    end

    test "timeouts after some given time" do
      Mox.stub(AMQPMock, :open_channel, fn _conn ->
        Process.sleep(:infinity)
      end)

      Process.flag(:trap_exit, true)

      pid =
        spawn_link(fn ->
          RPC.call(AMQPMock, :conn, "x", "y", "z", timeout: 10)
        end)

      assert_receive {:EXIT, ^pid, {:timeout, _ref}}
    end

    test "closes the channel after finishing" do
      {parent, ref} = {self(), make_ref()}

      Mox.expect(AMQPMock, :close_channel, fn _chan ->
        send(parent, {ref, :close_channel})

        :ok
      end)

      RPC.call(AMQPMock, :conn, "foo", "bar", "qux")

      assert_receive {^ref, :close_channel}
      refute_receive {:EXIT, _pid, _reason}
    end
  end
end
