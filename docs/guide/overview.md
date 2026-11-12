# Overview and architecture

SwiftWebServer is an HTTP/1.1, HTTP/2 and HTTP/3 server for **macOS 15 or later**, written in
Swift 6 with strict concurrency and **no package dependencies**. It uses Darwin (POSIX sockets,
kqueue, `sendfile(2)`, zlib, libcompression) and Network.framework (TLS, QUIC). It is not built
or tested on Linux.

It comes in two forms:

- **The `SwiftWebServer` executable**: one binary configured by a JSON file
  (`http-config.json`). It serves static files and reverse-proxies paths to local apps, over
  cleartext HTTP/1.1, HTTPS (HTTP/1.1 and HTTP/2) and HTTP/3 at once. See
  [Running on a Mac](running-on-a-mac.md).
- **A set of library products** you compose in your own Swift package, adding in-process
  handlers (a `Router`, WebSockets) to whichever components you want. See
  [Choosing components](choosing-components.md).

## Core and optional components

The design rule (ROADMAP §1.1) is a minimal core plus optional components, each in its own
target. A component that is not registered is not in the compiled request path at all.

| Layer | Targets | Role |
|---|---|---|
| Core | `HTTPCore` | Bytes (`ByteBuffer`), header fields, `HTTPRequest`/`HTTPResponse`, the `HTTPHandler` and `HTTPMiddleware` protocols, the middleware builder, transport protocols, `RequestContext` |
| Core | `HTTP1` | HTTP/1.1 parser, serializer, chunked codec, connection state machine and runner |
| Core | `HTTPServer` | `Server`: listeners, protocol registry, connection limit, lifecycle and graceful drain |
| Core | `NetworkTransport` | Listeners and connections: BSD sockets + kqueue, Network.framework TCP, TLS and QUIC |
| Protocols | `HPACK` + `HTTP2`, `QPACK` + `HTTP3` (both on `HeaderCompression`), `WebSockets` | Optional protocols |
| Components | `StaticFiles` (includes `ErrorPages`), `Compression`, `VirtualHosts`, `Auth`, `AccessLog`, `Router`, `Proxy` | Optional request-path features |
| Glue | `ConfigFile` | `http-config.json` → settings → listeners, protocols and middleware chain (uses Foundation, startup only) |
| Tools | `SwiftWebServer`, `sws-bench`, `HTTPTestSupport` | The shipped server, the benchmark harness, in-memory test transports |

The [component table](choosing-components.md#targets-and-products) lists dependencies and when
to include each one.

## Protocols

| Protocol | Listener | How a connection gets it |
|---|---|---|
| HTTP/1.1 | cleartext TCP and TLS | Always available. Keep-alive, pipelining, chunked and `Content-Length` bodies, `Expect: 100-continue` |
| HTTP/2 | TLS (ALPN `h2`) | The TLS listener offers `h2` and `http/1.1` through ALPN; the client picks. Optional cleartext h2c with prior knowledge (`"http2": {"cleartext": true}`), which makes every cleartext connection sniff its first bytes. h2c `Upgrade` and server push are not supported (removed from RFC 9113 / dropped by browsers) |
| HTTP/3 | QUIC (UDP) | A separate QUIC listener, by default on the TLS port number over UDP. HTTPS responses carry `Alt-Svc: h3=":PORT"; ma=SECONDS` so browsers discover it; cleartext and HTTP/3 responses do not |
| WebSockets | any | RFC 6455 Upgrade on HTTP/1.1, extended CONNECT on HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220) |

Protocol choice happens once per connection, by ALPN on TLS and QUIC or by the first bytes on
cleartext. The handler chain is the same for every protocol, so a component written once
serves h1, h2 and h3.

HTTP/2 passes the h2spec conformance suite (146/146) and has limits against the known HTTP/2
attacks (rapid reset, CONTINUATION, control-frame floods, slow reads). HTTP/3 has QPACK (static
table by default, dynamic table opt-in), control streams, RFC 9218 priorities and a `GOAWAY`
drain. One known Network.framework limitation: an HTTP/3 application close code never reaches
the wire (see [notes/nw-transport.md](../notes/nw-transport.md)). There is no 0-RTT.

## Transports

| Transport | Used for | Type |
|---|---|---|
| BSD sockets + kqueue | cleartext TCP (default, `"transport": "bsd"`) | `BSDSocketListener` |
| Network.framework `NWListener` | cleartext TCP when `"transport": "nw"` | `TCPListener` |
| Network.framework TLS | HTTPS (TLS 1.2+, ALPN) | `TCPListener(configuration:tls:)` |
| Network.framework QUIC | HTTP/3 | `QUICListener` |

Cleartext defaults to BSD sockets because Network.framework connection setup costs about
665 µs and 409 allocations per connection, serialized on one queue; the BSD listener accepts
about 22k new connections per second, on par with nginx (decision #0113,
[M3-accept](../benchmarks/M3-accept.md)). TLS and QUIC stay on Network.framework, which
supplies TLS 1.3, QUIC, loss recovery and congestion control. Large static files go out with
`sendfile(2)` on the BSD transport.

TLS identities are PKCS#12 files loaded **in memory only** (`SecPKCS12Import` with
`kSecImportToMemoryOnly`); the server never reads or writes a keychain.

## Concurrency model

- One task per connection, no actors on the request path. Lifetimes are a task-group tree:
  server → listener → connection → stream. There are no unstructured `Task {}`s.
- Every protocol layer is a value-type state machine (`mutating func handle(_ event:) ->
  Action`, no I/O), tested over in-memory transports.
- Reads are demand-driven: nothing reads ahead of the handler, so a slow consumer applies TCP
  (or QUIC stream) backpressure. No unbounded buffers.
- The hot path parses bytes directly, with no `String` or Foundation work and no allocations in
  the server's own code (`sws-bench` counts them).
- Shared HTTP/2 connection state is a `Mutex` with non-suspending critical sections.

## Requests, handlers and the chain

```swift
public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse
}
public protocol HTTPMiddleware: Sendable {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse
}
```

A response body is `.empty`, `.bytes(ByteBuffer)`, `.stream(length:writer:)` (written under
backpressure), `.file(FileRegion)` (sent with `sendfile`) or `.tunnel` (take over the byte
stream: WebSockets and proxied upgrades). An `HTTPRequest` is valid only while `handle` runs;
`snapshot()` copies it.

`Server` takes a `@MiddlewareBuilder` block. The builder turns the list into one nested
generic type at compile time, so the chain is statically dispatched and an `if` that leaves a
component out costs one predictable branch. Order is onion order: the first element sees the
request first and the response last; the last element is the handler. Details:
[MIDDLEWARE.md](../MIDDLEWARE.md).

### The chain the executable builds

`ServerSettings.makeHandler()` (target `ConfigFile`) registers only the enabled components, in
this order:

| # | Component | Config key | Why here |
|---|---|---|---|
| 1 | `AltSvc` | `http3` | Adds `Alt-Svc` to HTTPS responses |
| 2 | `AccessLog` | `accessLog` | Outermost, so it records final statuses: error pages, auth rejections, proxied responses |
| 3 | `MetricsEndpoint` | `accessLog.metrics` | Answers `GET /metrics` before anything else runs |
| 4 | `Compression` | `compression` | Outside error pages, so generated pages are compressed too |
| 5 | `ErrorPages` | `errorPages` | Fills bodiless `4xx`/`5xx` from everything inside it (auth `401`, proxy `502`/`504`, files `404`) |
| 6 | `Authenticator` | `auth` | Before the proxy, so protected paths are checked before anything is forwarded |
| 7 | `ReverseProxy` | `proxy` | Matches mounts; everything else falls through |
| 8 | `StaticFiles` or `VirtualHosts` | `root` / `hosts` | The terminal handler. With `hosts`, each site has its own `StaticFiles` and its own `hosts[].proxy` mounts |

A request for `/api/items` with `proxy` and `auth` configured walks: access log → compression →
error pages → auth check → proxy (match: forwarded upstream). A request for `/style.css` walks
the same way and falls through the proxy to the static files.

## Lifecycle

`Server.run()` binds every listener in order (cleartext, then TLS, then QUIC), runs until
`requestShutdown()` and returns after a graceful drain: listeners stop accepting, every
connection's shutdown signal fires (HTTP/2 and HTTP/3 send `GOAWAY`, WebSockets close with
1001), and open connections get up to `drainTimeout` to finish before they are cancelled. The
executable maps SIGINT and SIGTERM to that drain. See
[Running on a Mac](running-on-a-mac.md#shutdown-restart-and-reload).
