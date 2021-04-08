# AmqpHelpers

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `amqp_helpers` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:amqp_helpers, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/amqp_helpers](https://hexdocs.pm/amqp_helpers).

## Why and comparations with other libraries

## AMQP Good Practices

Enforce
Use AMQP application, two connectinos

## User Case Scnearios

Common scenario are high throughput or data safety. High availability can be
achieved in both.

### High Throughput

Hight throughput implies no message guarantees.

Avoid multiple nodes, disable high availability queues a connect directly to
the node which host the queues. A high availability configuration can be done
using a backup node and load balancer, which returns always the same
node unless the first one down.

Queues should be declared as non persistent and eager, avoid any lazy queue
also, to avoid moving data from data.

For publishing messages use `AMQP.publish/5` and be sure to use transient
messages, i.e., `persistent: false` as option.

For consuming, avoid acknowledging messages. When calling `AMQP.Basic.consume/4`
be sure to use `no_ack: true` is set.

Other optimizations: setting a `max-length` to the queue to discard messages
from the head. Splitting the workload into several queues, producer and
consumers.

In summary:

- Use one single node with direct connections.
- Use queues without persistence and lazy.
- Publish transient messages without confirming publishing (default
  behaviour).

## Testing

Adapter module, mox and testing.

## References

- [CloudAMQP - RabbitMQ Best Practices for High Availability](https://www.cloudamqp.com/blog/part3-rabbitmq-best-practice-for-high-availability.html)
- [CloudAMQP - RabbitMQ Best Practices for High Performance](https://www.cloudamqp.com/blog/part2-rabbitmq-best-practice-for-high-performance.html)
- [CloudAMQP - RabbitMQ Best Practices](https://www.cloudamqp.com/blog/part1-rabbitmq-best-practice.html)
- [RabbitMQ Docs - Reliability Guide](https://www.rabbitmq.com/reliability.html)
- [RabbitMQ in Depth](https://www.manning.com/books/rabbitmq-in-depth)
