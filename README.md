# AMQP Helpers

[![Build and Test](https://github.com/kantox/amqp_helpers/actions/workflows/build-test.yml/badge.svg)](https://github.com/kantox/amqp_helpers/actions/workflows/build-test.yml)
[![Coverage Status](https://coveralls.io/repos/github/kantox/amqp_helpers/badge.svg?branch=main&t=VbtrhR)](https://coveralls.io/github/kantox/amqp_helpers?branch=main)

Non opinionated [AMQP](https://github.com/pma/amqp) helpers for common
scenarios.

## Installation

To use _AMQPHelpers_ you need [AMQP](https://github.com/pma/amqp). You can
install both by adding `amqp` and `amqp_helpers` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:amqp, "~> 3.0"},
    {:amqp_helpers, "~> 1.1"}
  ]
end
```

## Motivation

This library provides several wrappers and utilities around some common use
cases of _AMQP_. It provides a simple interface, following common _OTP_ patterns
and [Elixir library guidelines](https://hexdocs.pm/elixir/master/library-guidelines.html)
to avoid any opinionated interface. Other generalist abstractions can be built
on top of _AMQPHelpers_ to provide ergonomics or any other feature not strictly
tied to _AMQP_.

Right now, the utilities built in this library are suited for uses that try to
optimize _AMQP_ for high throughput and for scenarios that require data safety
at any cost.

### Comparisons With Other Libraries

This is how this library relates to other available libraries in order to
highlight the motivation behind this library:

- [**AMQP**](https://hexdocs.pm/amqp/readme.html): this library is not a
  replacement in any way to this library, but a companion.
- [**AMQPx**](https://hexdocs.pm/amqpx): in some way, similar to this library,
  but not tied to any particular use case and some of its functionality has been
  superseded by `AMQP` v2.x.
- [**Broadway**](https://hexdocs.pm/broadway/Broadway.html): this is an
  abstraction for message processing, which cannot be compared directly to this
  library. [`broadway_rabbitmq`](https://github.com/dashbitco/broadway_rabbitmq)
  is a connector for `AMQP` and can be adapted to use this library if needed.
  Nevertheless, unless you want to support multiple transports, most of the
  features provided by `Broadway` can be implemented directly by using some
  _RabbitMQ_/_AMQP_ features (there are exceptions like graceful shutdown).
- [**GenAmqp**](https://hexdocs.pm/gen_amqp): provides some utilities in the
  same way that this library, but not tied to any specific use case. Also, some
  of its functionality has been superseded by `AMQP` v2.x.
- [**PlugAmqp**](https://hexdocs.pm/rambla/getting-started.html): It will use
  this library, but have different purposes (it implements _RPC_ pattern over
  _AMQP_).
- [**Rambla**](https://hexdocs.pm/rambla/getting-started.html): similar to
  `Broadway`, but from the publishing point of view.

In summary, this library provides helpers tied to specific use cases of _AMQP_,
without any kind of abstraction over it. If you are looking to support
different kinds of transports in your library, check out libraries like
`Broadway` or `Rambla`.

## AMQP Good Practices

This library enforces some good practices that have no downside for any
application using _AMQP_ and ease the development of _AMQP_ related features.

The first one is the use of an _AMQP_ implementation behind a behaviour, called
`AMQPHelpers.Adapter`. This allow us to provide stub, mocks or even different
transport layers that mimic the _AMQP_ interface.

The second one is the use of [application connection/channels](`AMQP.Application`).
This an _AMQP_ v2.x feature which replaces (or aid) previous connections
supervisors or channel pools. As general thumb rule, your application should
have at most two connection (in/out) and one channel per multiplexing process.

## User Case Scenarios

These are the _AMQP_ use cases are covered in _AMQP Helpers_ right now:

- A performance-intensive scenario in which a high throughput message delivery
  rate is desired. Trade-offs in reliability are acceptable.

- A reliable scenario in which data safety is a must, even if performance is
  compromised.

- Remote procedure calls using [Direct Reply-to](https://www.rabbitmq.com/direct-reply-to.html).

There are some other features, like _High Availability_, _Observability_,
_Exclusivity_, etc. that can be achieved in both scenarios but are not
explicitly covered here.

### High Throughput

To achieve the best performance in terms of message delivery some trade-off must
be done, which usually impacts the reliability and/or coherence of the system.

Durability should be disabled. In other words, messages will not be persisted,
so messages could be lost in a broker outage scenario. This can be configured by
declaring queues as non-durable and publishing messages with `persistent` set to
`false`.

Acknowledges, from any communication direction, should be disabled. This means
that the publisher should not confirm deliveries, and consumers should not
acknowledge messages. Messages could be lost on the flight because of network or
edge issues. Publisher confirms are not enabled by default, so nothing has to be
done in terms of publishing. Consuming requires disabling acknowledging, which
can be done by setting the `no_ack` flag on.

The `AMQPHelpers.HighThroughput` module provides functions that enforce these
requirements for publishing and consuming. These are simple wrappers around
_AMQP_ library functions. They add very little aside from being explicit about
a feature of some scenario (performance intensive).

Some other considerations should have taken into account when declaring queues
for this purpose, which are:

- `x-max-length` or `x-max-length-bytes` with `x-expires` and `x-messages-ttl`
  should be used to avoid large queues. Large queues slowdown message delivery.
  This option limits the size of the queue to a known threshold.

- `x-queue-mode` should **not** be `"lazy"` to avoid moving messages to disk.

- Queues should not be replicated, nor enabling [high availability](https://www.rabbitmq.com/ha.html)
  nor using [quorum queues](https://www.rabbitmq.com/quorum-queues.html). Both
  method have implications in the performance of the queue.

- `durable` should be set to `false`.

### Reliability

For reliability, [Acknowledgements and Confirms](https://www.rabbitmq.com/confirms.html)
are used, which have an impact in performance. Reliability is not only achieved
at client level, broker configuration and monitoring are also important topics
here. You can read [RabbitMQ's Reliability Guide](https://www.rabbitmq.com/reliability.html)
for more information.

The `AMQPHelpers.Reliability.Consumer` and `AMQPHelpers.Reliability.Producer`
provide processes to consume and publish messages in a reliable fashion. The
`Consumer` uses standard AMQP acknowledges mechanism to notify that messages are
consumed successfully. The `Producer` uses the _Publisher Confirms_ extension to
get notified about successfully message deliveries.

A system which uses the provided `Reliability.Consumer` and
`Reliability.Producer` will guarantee that no message is lost, and at least one
message is delivered. For high availability you can pair this processes with
mirrored queues. For consistency, you can use
[deduplication plugin](https://github.com/noxdafox/rabbitmq-message-deduplication)
or [quorum queues](https://www.rabbitmq.com/quorum-queues.html) (Which also
guarantees message order).

## Testing

This library provides an _AMQP_ interface at `AMQPHelpers.Adapter` which can
be used with libraries like [Mox](https://github.com/dashbitco/mox) to mock any
part of the _AMQP_ interface. Check out the tests of this library to see some
examples.

Two adapter implementations are provided with this library:

- `AMQPHelpers.Adapters.Stub` - A stub implementation that only logs calls.
- `AMQPHelpers.Adapters.AMQP` - An implementation that uses `AMQP` library.

All the functionally exposed by the library support in one or another way a
configurable adapter (defaults to `AMQP` implementation).

## References

- [CloudAMQP - RabbitMQ Best Practices for High Availability](https://www.cloudamqp.com/blog/part3-rabbitmq-best-practice-for-high-availability.html)
- [CloudAMQP - RabbitMQ Best Practices for High Performance](https://www.cloudamqp.com/blog/part2-rabbitmq-best-practice-for-high-performance.html)
- [CloudAMQP - RabbitMQ Best Practices](https://www.cloudamqp.com/blog/part1-rabbitmq-best-practice.html)
- [RabbitMQ Docs - Reliability Guide](https://www.rabbitmq.com/reliability.html)
- [RabbitMQ in Depth](https://www.manning.com/books/rabbitmq-in-depth)
