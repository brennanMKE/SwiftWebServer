# Middleware and components

Every feature beyond the core (static files, compression, access log, auth, virtual hosts,
WebSockets) is an optional component. A component that is not registered is not in the
compiled request path at all (docs/ROADMAP.md §1.1). This document describes the mechanism
(#0083). The code is in `Sources/HTTPCore/MiddlewareBuilder.swift`, `RequestContext.swift` and
`ServerComponent.swift`; `Server` (HTTPServer) consumes them.

## Handlers and middlewares

```swift
public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse
}
public protocol HTTPMiddleware: Sendable {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse
}
```

A middleware may inspect or change the request and context before calling `next`, change the
response after it, answer on its own without calling `next` (short-circuit), or catch an error
thrown further in. Taking over the connection is a response with a `.tunnel` body.

## The builder

```swift
let server = Server(configuration: config, listeners: [listener], protocols: [HTTP1()]) {
    AccessLog()
    if config.compression { Compression() }
    StaticFiles(root: publicURL)
}
```

`@MiddlewareBuilder` turns the block into one nested generic type:

| Written | Built |
|---|---|
| `A(); B(); H()` | `CompiledChain<MiddlewareChain<A, MiddlewareChain<B, H>>>` |
| `A(); B()` (no handler) | `CompiledChain<MiddlewareChain<ComposedMiddleware<A, B>, NotFoundHandler>>` (`404`) |
| `if c { M() }` | `OptionalMiddleware<M>`: absent is one predictable branch |
| `if c { A() } else { B() }` | `EitherMiddleware<A, B>` (`EitherHandler` for handlers) |
| `{}` | `PassthroughMiddleware` |
| `H()` alone | `H` itself |

- Order is onion order: the first middleware sees the request first and the response last.
- A handler anywhere but last, or a branch mixing a middleware and a handler, does not compile.
- Up to 10 elements per block; an `if true { … }` groups more. Middlewares in front of a handler
  nest to the right, built once, so a request walks stored values and nothing is copied per
  request. A block of middlewares with no handler after it (an `if` body) is a
  `ComposedMiddleware`, which builds its inner `next` per request (a copy of the rest of the
  chain), so prefer single components in `if`s on hot paths.
- No existentials and no arrays inside the chain, and every chain type is `@inlinable`.
- `CompiledChain` is the boundary: protocol runners are called through `any ConnectionProtocol`
  and run unspecialized, so the builder (inlined where the chain is written) stores a closure
  compiled with every type known. The runner makes one indirect async call into it, and inside
  it the chain's own types inline away. A lone handler skips the wrapper.
- `Server(…, handler: app)` is the same as a builder with one element.
- `MiddlewareBuilder.build { … }` runs the builder anywhere else (tests, sub-chains).

Costs, from `sws-bench h1conn` (docs/benchmarks/M4.1-components.md): three no-op middlewares
cost the same as none once inside a `CompiledChain`; a disabled `if` component costs about
2 ns; the `CompiledChain` call itself costs one async call (about 15 ns direct, 30 ns inside the
HTTP/1.1 loop), paid only by chains with at least one middleware.

## RequestContext

Passed by value with every request:

| Member | Contents |
|---|---|
| `connection` | `ConnectionInfo`: local and remote address, TLS, negotiated ALPN |
| `startTime` | `MonotonicInstant?` when the request reached the chain; `nil` unless a component in the chain conforms to `RequestStartTimeConsumer` (the clock read is then paid per request) |
| `context[Key.self]` | Typed values set by components for those after them (`RequestContextKey`) |

Typed values cost nothing until a component sets one; each set allocates one small immutable
node. A middleware copies the context, sets a value and passes the copy to `next`, so values
flow inward only and never leak between requests.

## Server components

```swift
public protocol ServerComponent: Sendable {
    func run(server: ServerHandle) async throws
}
```

For components with a lifetime of their own (flushing an access log, evicting a cache). The
server finds them in the `components:` argument and in the builder chain (a middleware that is
also a `ServerComponent`; one left out by an `if` is not found). They run as child tasks of the
server once the listeners are bound and are cancelled after the last connection closed, so they
can flush what the final requests produced. A component that throws (other than
`CancellationError`) shuts the server down, and `Server.run()` rethrows the error. `ServerHandle`
gives the bound addresses, the draining signal and `requestShutdown()`.

## Connection observers

```swift
public protocol ConnectionObserver: Sendable {
    func connectionWillStart(_ connection: inout ConnectionContext)
    func connectionDidEnd(_ connection: ConnectionContext)
}
```

For components with per-connection state (#0090): a log buffer, metric counters. The server
finds them like components (in the chain and in `components:`), calls `connectionWillStart`
before the protocol runs and `connectionDidEnd` after the connection closed. In
`connectionWillStart` the observer sets a typed value on `connection.requestContext`, the
context every request on the connection starts from, so each request finds its connection's
state in `context[Key.self]` without a lookup table or a lock. Requests on one HTTP/1.1
connection run one at a time; on HTTP/2 and HTTP/3 they overlap, so the state must tolerate
concurrent requests. With no observer registered a connection pays one empty-array check.
Code that drives a runner directly (benchmarks) calls them through `ConnectionObservers`.

## The pattern in one component: AccessLog

`AccessLog` (target `AccessLog`) is the reference optional component. One value in the chain
plays four roles, each found by the server at startup:

| Role | Protocol | Effect |
|---|---|---|
| Records each request | `HTTPMiddleware` | Called in chain order; formats a line after `next` returns |
| Needs the start time | `RequestStartTimeConsumer` | Runners stamp `startTime` (one clock read) |
| Per-connection buffer and counters | `ConnectionObserver` | Opened and merged with each connection |
| Writes the lines | `ServerComponent` | Runs beside the listeners; cancelled after the last connection, then flushes |

```swift
let metrics = AccessLogMetrics()
let server = Server(listeners: [listener], protocols: [HTTP1()]) {
    if config.metrics { MetricsEndpoint(metrics: metrics) }   // GET /metrics, Prometheus text
    AccessLog(format: .combined, destination: .file(path: logPath), metrics: metrics)
    StaticFiles(root: publicURL)
}
```

The request path does no I/O and allocates nothing per request: the line is escaped straight
into the connection's buffer, full batches go to the writer with `BoundedAsyncQueue.trySend`
(dropped and counted when the queue is full, never awaited), and metrics are relaxed atomic adds
on the connection's own counters, merged into `AccessLogMetrics` when the connection closes and
read live on a scrape. Costs: docs/benchmarks/M6-accesslog.md.
