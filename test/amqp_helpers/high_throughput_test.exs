defmodule AMQPHelpers.HighThroughputTest do
  use ExUnit.Case, async: true

  alias AMQPHelpers.HighThroughput, as: AMQP

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "consume/5" do
    test "enforces no_ack option when consuming" do
      {parent, ref} = {self(), make_ref()}

      Mox.expect(AMQPMock, :consume, fn chan, queue, consumer_pid, opts ->
        assert chan == nil
        assert queue == "foo"
        assert consumer_pid == nil
        assert Keyword.fetch!(opts, :no_ack)

        send(parent, {ref, :consume})
      end)

      AMQP.consume(AMQPMock, nil, "foo", nil, no_ack: false)
      assert_receive {^ref, :consume}
    end
  end

  describe "publish/6" do
    test "enforces transient messages" do
      {parent, ref} = {self(), make_ref()}

      Mox.expect(AMQPMock, :publish, fn chan, exchange, routing_key, payload, opts ->
        assert chan == nil
        assert exchange == "foo"
        assert routing_key == "bar"
        assert payload == %{qux: 9001}
        refute Keyword.fetch!(opts, :persistent)

        send(parent, {ref, :publish})
      end)

      AMQP.publish(AMQPMock, nil, "foo", "bar", %{qux: 9001}, persistent: true)

      assert_receive {^ref, :publish}
    end
  end
end
