# SwiftWebServer Roadmap: a dependency-free, modular HTTP/1.1 + HTTP/2 + HTTP/3 server

Swift 6, macOS 15+, Network.framework, zero package dependencies. This document supersedes `docs/HTTP2.md` (its limits table and DoS list remain valid and are carried into the HTTP/2 track).

## 1. Principles

1. **Minimal core, optional components.** The core is a lean HTTP server. Every feature (static files, conditional requests, compression, WebSockets, HTTP/2, HTTP/3, TLS, virtual hosts, auth, access log) is an isolated, opt-in component registered by configuration. An unregistered component costs nothing on the hot path.
2. **Swift Concurrency with explicit state machines.** Demand-driven `AsyncSequence`s with backpressure; no unbounded buffers. Every protocol layer's state is a value-type state machine with a pure `mutating func handle(_ event:) -> Action`, testable without I/O.
3. **The request is the hot loop.** Following `../BillionRowChallenge/docs/PerformanceWalkthrough.md`: every request is the same operation repeated millions of times, so the request path has no allocations in our code, no actor hops, no `String` or Foundation work, and bytes are parsed directly.
4. **Rewrite the core rather than patch it.** The legacy server's bugs (issues 0002–0025) become acceptance tests for the new code.
5. **HTTP/3 on Network.framework QUIC.** We write HTTP/3 framing (RFC 9114) and QPACK (RFC 9204); the system supplies QUIC, TLS 1.3, loss recovery and congestion control.
6. **Measure everything.** `sws-bench` lands in Milestone 0; a regression over 10% blocks a milestone.

## 2. Decisions

| Decision | Choice | Status |
|---|---|---|
| Track order | HTTP/3 (Track A) before HTTP/2 (Track B); both are implemented | Taken by default; independent after M5 |
| Server push (0066) | Dropped: browsers no longer accept it | wontfix (owner, 2026-11-11) |
| h2c `Upgrade` (0068) | Dropped: removed by RFC 9113 | wontfix (owner, 2026-11-11) |
| `DispatchQueue` | Allowed only where `NWListener`/`NWConnection.start(queue:)` require it (NetworkTransport target) and for signal sources in the executable | Accepted |
| Cleartext TCP transport | BSD sockets + kqueue (`BSDSocketTransport`) by default; Network.framework `TCPListener` stays selectable. TLS and QUIC stay on Network.framework | Decided 2026-11-11 (#0113): NW accept cost is about 665 µs and 409 allocations per connection, serialized on one queue; BSD gets about 22k new connections/s, on par with nginx |
| Actors | None on the request path. Shared HTTP/2 connection state uses `Mutex` (Synchronization) with non-suspending critical sections | Accepted |

## 3. Critical review of the legacy code

Keep: `Root/` fixtures; the `http-config.json` schema idea; status and error-page concepts; the state-enum instinct in `HTTPRuntime`; `os.Logger` behind the AccessLog component; the `docs/HTTP2.md` limits/DoS tables.

Delete or rewrite:

| File | Problem | Fate |
|---|---|---|
| `HTTPServer.swift` | Singleton; unbounded `AsyncStream`; unstructured `Task` per connection; parse/respond/file I/O interleaved; ~14 log calls per request; one response then close | Replaced by `Server`, HTTP/1.1 runner, StaticFiles |
| `ConnectionStream` | Eager pump into unbounded stream; new stream and `Task` per `values` access | Replaced by demand-driven transport |
| `HTTPRequest.parse` | `String(data:)`, `components(separatedBy:)`, `URLComponents`, `[String: String]`; no "need more" result | Byte state-machine parser |
| `HTTPResponse` | String then Data; random header order; overrides body on every non-200 | Serializer into reusable buffer |
| `HTTPRuntime` (actor) | `try await runtime.config` is an actor hop per request | Immutable `Sendable` config captured at start |
| `ExitHandler` | Double resume; lost early termination | Lifecycle state machine |
| `main.swift` | `do/catch` around `Task {}`; `dispatchMain()` | `@main` async |
| `SwiftWebSocketsTestSuite`, `File.swift` | Stubs | Delete |

Untracked problems found: per-request actor hop; "weak" ETag that is a SHA-256 of content rendered with `String(format:)` per byte; linear case-insensitive header scan via Foundation; signal handlers call `exit()`.

## 4. Why the previous effort stalled

- WebSockets were started (stub test-suite target) before a parser, keep-alive, upgrade hook, or any test existed. `MIDDLEWARE.md` ends at "the interface needs to be defined".
- 68 issues were filed in one day with no code; 25 of them fixed code the plan later replaced.
- Exit criteria depended on uninstalled tools (`h2spec`, `h2load`, Docker/Autobahn).
- HTTP/3's biggest unknown (QUIC on Network.framework) was never tested.

This plan: rewrite first with old bugs as tests; spike QUIC first with a go/no-go gate; every exit criterion uses tools present on the machine or an explicit prerequisite; protocol logic is pure state machines over in-memory transports; WebSockets and HTTP/2 are side tracks behind defined hooks; the legacy server stays buildable until parity (end of M4).

## 5. Target architecture

### 5.1 Targets

```
Sources/
  HTTPCore/          no Network import. ByteBuffer, HTTPFields, request/response types, HTTPHandler,
                     HTTPMiddleware, transport protocols, limits, BoundedAsyncQueue, date cache,
                     pseudo-header validation (shared by h2/h3)
  HTTP1/             parser, serializer, chunked codec, connection state machine, runner
  HTTPServer/        Server, ServerConfiguration, lifecycle state machine, protocol registry
  NetworkTransport/  NWListener/NWConnection adapters: TCP, TLS (+ALPN), QUIC
  HeaderCompression/ prefix integers, Huffman (shared by HPACK and QPACK)
  HPACK/ HTTP2/      optional
  QPACK/ HTTP3/      optional
  WebSockets/        optional (RFC 6455; RFC 8441/9220 via tunnel hook)
  StaticFiles/       optional (conditional requests, Range)
  Compression/ VirtualHosts/ Auth/ AccessLog/ Router/   optional
  ConfigFile/        JSON config -> components (Foundation; CLI only)
  SwiftWebServer/    executable
  sws-bench/         benchmark harness
  HTTPTestSupport/   InMemoryTransport, InMemoryMultiplexedTransport, reference parser
Tests/               one test target per source target, plus IntegrationTests
```

TLS is configuration inside NetworkTransport. Package traits (Swift 6.1+) let the CLI compile out HTTP2/HTTP3/WebSockets. Protocol selection happens once per connection; the middleware chain is a nested generic built by a result builder, so an absent component is absent from the compiled chain.

### 5.2 Extension points (the only five)

```swift
public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse
}
public protocol HTTPMiddleware: Sendable {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse
}
public protocol ByteStreamTransport: Sendable {
    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int   // 0 = EOF
    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws
    func sendFile(_ region: FileRegion) async throws
    func close(_ reason: CloseReason) async
    var info: ConnectionInfo { get }
}
public protocol MultiplexedTransport: Sendable {
    associatedtype Stream: ByteStreamTransport & StreamIdentified
    associatedtype Inbound: AsyncSequence<Stream, any Error>
    var inboundStreams: Inbound { get }
    func openUnidirectionalStream() async throws -> Stream
    func close(applicationError: UInt64) async
}
public protocol ConnectionProtocol: Sendable {
    static var alpnTokens: [String] { get }
    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult
    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async
}
public protocol ServerComponent: Sendable {
    func run(server: ServerHandle) async throws
}
```

```swift
public struct HTTPRequest: Sendable {     // valid for duration of handle(); snapshot() to keep
    public var method: HTTPMethod         // enum + .other(bytes)
    public var scheme, authority, path, query: ByteView
    public var headers: HTTPFieldsView    // ordered, duplicates kept, well-known names as small IDs
    public var body: HTTPRequestBody      // AsyncSequence of ByteBuffer; .empty costs nothing
}
public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPFields
    public var body: HTTPResponseBody     // .empty | .bytes | .file(FileRegion)
                                          // | .stream(length:, (any HTTPBodyWriter) async throws -> Void)
                                          // | .tunnel((any ByteStreamTransport) async -> Void)
}
```

`.tunnel` is the single protocol-switch hook: HTTP/1.1 emits `101`; HTTP/2 and HTTP/3 answer extended CONNECT with `200`. `HTTPRequest` borrows reusable per-connection storage (debug generation counter traps use-after-return).

```swift
let server = Server(configuration: config, protocols: [HTTP1.self]) {
    AccessLog()
    if config.compression { Compression() }
    StaticFiles(root: publicURL)
}
try await server.run()
```

### 5.3 Hot path (HTTP/1.1)

```
connection task (no actor; owns buffer, parser, state machine as locals)
loop:
  n = try await transport.receive(into: &inBuf)          // suspension 1
  while parser.parseHead(&inBuf) == .complete:           // sync, no allocation
      response = try await handler.handle(request, ctx)  // static dispatch
      serializer.write(response, into: &outBuf)          // sync
  try await transport.send(outBuf)                       // suspension 2 (per pipelined batch)
```

### 5.4 State machines

All value types; `mutating func handle(_ event: Event) -> Action` returning one `Action` (never `[Action]`); no I/O, no `await`.

| Layer | State machines |
|---|---|
| Server | `ServerLifecycle`: idle, starting, running, draining(deadline), stopped, failed |
| HTTP/1.1 | `HTTP1Parser`, `ChunkedDecoder`, `HTTP1Connection` (idle, readingHead, handling, readingBody, writing, closing, tunnelled) |
| HTTP/2 | `FrameParser`, `HeaderBlockAssembler`, `HTTP2Connection`, `HTTP2Stream` (RFC 9113 §5.1), `FlowControlWindow`, HPACK tables |
| HTTP/3 | `VarintParser`, `H3FrameParser`, `UniStreamClassifier`, `H3RequestStream`, `H3Connection`, QPACK |
| QUIC edge | `QUICConnectionState`, `QUICStreamState` (mirror NW states into events) |
| WebSockets | `WSFrameParser`, `WSConnection`, message assembler, streaming UTF-8 validator |
| Utilities | `BoundedAsyncQueue`, `Deadline` |

Concurrency rules: `AsyncStream` only for low-rate signals; byte/frame flows use custom `AsyncSequence`s whose `next()` performs the read, or `BoundedAsyncQueue` (suspends producers). Lifetimes are a task-group tree (server → listener → connection → stream); no unstructured `Task {}`. HTTP/2 shared state in a `Mutex`; HPACK encode + frame enqueue in one critical section; continuations resumed outside the lock. HTTP/3 with static-table QPACK shares no mutable state on the request path.

## 6. HTTP/3 approach

**Option A (chosen):** `NWProtocolQUIC` + `NWListener.newConnectionGroupHandler` (one `NWConnectionGroup` per QUIC connection), `group.newConnectionHandler` for inbound streams, `NWConnection(from: group, using:)` with `direction = .unidirectional` for our control stream. All macOS 12+. The macOS 26 async API (`NetworkListener<QUIC>`) may be added later behind `#available` if benchmarks justify it.

**Option B (rejected):** implementing QUIC requires a TLS 1.3 server (no public API exposes handshake secrets), packet protection, RFC 9002 recovery, migration and anti-amplification. Revisit only if the spike fails.

**QPACK:** static table + literals, `SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0`; still accept peer encoder/decoder streams. Dynamic table optional later.

**Alt-Svc:** HTTP3 component contributes middleware adding `Alt-Svc: h3=":<port>"; ma=<seconds>` on TLS listeners.

**0-RTT:** no public server-side control; determine behaviour in the spike and document.

**Spike (M0, one day), questions 1–11:** (1) QUIC listener accepts `curl --http3-only -k` and an NW QUIC client; (2) inbound stream direction/ID readable; (3) server opens three uni streams; (4) FIN mapping both ways; (5) reset/STOP_SENDING codes; (6) connection close with app error code; (7) backpressure via not receiving, send completion as signal; (8) 0-RTT; (9) per-stream cost; (10) TCP+UDP on same port; (11) client tooling (Homebrew curl HTTP/3, `URLSession` `assumesHTTP3Capable` with trust override). **Gate:** 1–7 must work, else Track A pauses, Track B is promoted, and Option B goes to the owner.

**Spike result (2026-11-11, `docs/spikes/quic-spike.md`): conditional GO.** 1–5, 7, 10 and 11 work. Q6 is partial: close works, but the app error code on CONNECTION_CLOSE is unobserved; it is verified under #0104. Q8: no 0-RTT or resumption. Per-stream NW cost is about 590 allocations and 0.4–0.8 ms.

## 7. Performance discipline

| Lesson | Where it applies |
|---|---|
| Find per-item cost, multiply | `sws-bench` reports ns + allocations per request; provisional targets: head parse < 150 ns, serialize < 100 ns for 10 headers, zero allocations in our code |
| No allocations in hot loop | One reusable receive buffer with read/write indices; header index storage reused with `removeAll(keepingCapacity:)`; no `Data` slicing |
| Cheapest form; convert at edges | Method enum by word compare; header names as small IDs; values/path/query as byte ranges; `String` only on demand; percent-decode only if `%` seen |
| Scan and hash in one pass | Header-name scan finds `:` and computes FNV-1a of lowercased bytes, resolving well-known ID from a power-of-two table |
| Use what you know | Hand-written parser; digit-loop Content-Length; IMF-fixdate by fixed offsets; static status lines; `Date` rendered once per second; integer-to-ASCII without `String` |
| Keep a validating path | Fully bounds-checked parser with 256-entry token table; slow reference parser in test support; differential test |
| Shard, don't share | Immutable config; per-connection metrics merged on close/scrape |
| Pick the concurrency tool | `await` only at I/O: one per read, one per write; no per-request `Task` for HTTP/1.1 |
| Data layout | Parallel arrays for headers; HPACK ring over one byte arena; table-driven Huffman; open-addressed h2 stream table; fixed capacities from limits |
| Memory-map the file | Small files cached with pre-rendered headers; large files via bounded `pread` or mmap region; ETag from size+mtime+inode |
| Keep unsafe small | Unsafe pointers only in `ByteBuffer` and Huffman tables; `Span`/`RawSpan` where available |
| Optimize in order | Structure, then allocations, then micro-tuning (SWAR CR/LF) with measurement |

Known floor: `NWConnection` allocates `Data` and dispatch blocks per receive/send; measure in M2 and try a task-executor preference backed by the connection queue.

## 8. Milestones

Each numbered item is one issue. The legacy server remains the shipped binary until M4 passes parity.

### Mainline

- **M0 Ground** — 0.1 package restructure (legacy → `Legacy` target, all targets stubbed, test targets, tools-version bump, `Span` check); 0.2 `sws-bench` skeleton + legacy baseline; 0.3 QUIC spike report; 0.4 owner prerequisites (`brew install h2spec nghttp2 curl oha`, test identity script, local CA). Exit: `swift test` runs real tests; baseline recorded; spike go/no-go.
- **M1 Bytes and HTTP/1.1 codec** — 1.1 `ByteBuffer`, ASCII/integer utilities; 1.2 `HTTPFields`, method, status; 1.3 `HTTP1Parser` with limits + reference parser + differential test; 1.4 serializer + date cache. Exit: parses identically when split at every byte offset; oversized head → 431; zero allocations; ns/request recorded.
- **M2 Transport and lifecycle** — 2.1 transport protocols + `InMemoryTransport`; 2.2 `NWConnection` TCP adapter (demand-driven, handlers before `start`); 2.3 `Server` with lifecycle state machine, task-group accept, connection limit, CLI signals. Exit: two servers on port 0 in one process; child process exits 0 on SIGTERM and 1 on bad config; per-read overhead measured.
- **M3 HTTP/1.1 connections** — 3.1 connection state machine + runner (keep-alive, pipelining, handler error → 500 + close); 3.2 request bodies (Content-Length, chunked, `Expect: 100-continue`), streamed responses, HEAD/204/304 body rules; 3.3 header/idle/body timeouts with 408, graceful drain. Exit: in-memory + curl tests; slow-header client closed; keep-alive throughput vs baseline.
- **M4 Components, StaticFiles, cut-over** — 4.1 middleware builder, `RequestContext`, registration; 4.2 StaticFiles (decode once, containment + symlink policy, block list, MIME, index, metadata ETag, 405 + Allow, Range/206); 4.3 conditional requests in RFC 9110 order, error pages; 4.4 config file with defaults, CLI on new stack, delete `Legacy`, fix docs/scripts. Exit: repro steps of 0003–0025 pass as tests; throughput beats baseline; flat memory on large file.
- **M5 TLS and protocol registry** — 5.1 identity loading + TLS listener; 5.2 ALPN + `ConnectionProtocol` registry; 5.3 cleartext + TLS listeners together. Exit: `curl -k https://localhost:8443/` and `URLSession` test.
- **M6 Small components** (any time after M4) — AccessLog + metrics, Compression, VirtualHosts, Auth, Router. Exit each: unit tests + benchmark shows no change when unregistered.

### Track A: HTTP/3 (after M5 and passing spike)

- **M7 Pure codecs** — 7.1 prefix integers + Huffman (`HeaderCompression`); 7.2 QUIC varints + HTTP/3 frame codec; 7.3 QPACK static-table encoder/decoder. Exit: RFC 7541 App. C Huffman vectors and RFC 9204 examples.
- **M8 QUIC transport** — 8.1 `MultiplexedTransport` over `NWConnectionGroup`; 8.2 `InMemoryMultiplexedTransport`. Exit: echo test vs NW QUIC client incl. FIN and reset.
- **M9 HTTP/3 MVP** — 9.1 control streams + SETTINGS; 9.2 request-stream state machine → `HTTPHandler`; 9.3 GOAWAY, error mapping, limits; 9.4 `Alt-Svc` middleware. Exit: `curl --http3-only -k` fetches static files, concurrent and large; in-memory malformed-frame suite.
- **M10 HTTP/3 hardening** — cancellation bridging, graceful shutdown, abuse limits, browser interop, load numbers, optional QPACK dynamic table, optional RFC 9218 priorities.

### Track B: HTTP/2 (after M5; shares only 7.1)

- **M11** frame codec, error types, HPACK tables/decoder/encoder. Exit: RFC 7541 App. C vectors.
- **M12** preface detection, SETTINGS, connection + stream state machines, header-block assembly, request mapping, per-stream tasks, PING, RST_STREAM, GOAWAY. Exit: `curl --http2-prior-knowledge` and `curl --http2 -k`, concurrent streams.
- **M13** inbound/outbound flow control, concurrency and header-size limits, DoS mitigations. Exit: `h2spec` passes; `h2load` numbers.

### Track C: WebSockets (after M3)

- **M14** RFC 6455 over `.tunnel`: handshake, frame parser, connection state machine, fragmentation, UTF-8 validation, ping/pong, close. Exit: `URLSessionWebSocketTask` echo tests; Autobahn when Docker available.
- **M15** permessage-deflate (optional); RFC 8441 over h2 (after M12); RFC 9220 over h3 (after M9). Exit: extended CONNECT echo on each.

## 9. Legacy issue mapping (0001–0068)

| Issue | Disposition | New home |
|---|---|---|
| 0001 | keep | 0.1 |
| 0002, 0003, 0005 | merge | 2.3 |
| 0004 | merge | 2.3, 4.4 |
| 0006 | merge | 1.3 |
| 0007, 0008, 0009 | merge | 3.1 |
| 0010 | merge | 2.2 |
| 0011 | merge | 1.3 (431), 3.2 (413) |
| 0012 | keep | 3.3 |
| 0013, 0014, 0015, 0022, 0025 | merge | 4.2 |
| 0016 | merge | 3.2 |
| 0017, 0019 | merge | 4.3 |
| 0018 | merge | 3.2, 4.3 |
| 0020 | merge | 1.4, 3.1 |
| 0021 | merge | 1.2 |
| 0023, 0026 | keep | 4.4 |
| 0024 | merge | 2.3, M6, 4.1 |
| 0027 | keep (new signature) | 2.1 |
| 0028 | keep | 2.2 |
| 0029 | keep | 2.3 |
| 0030 | keep, split | 1.2, 3.2 |
| 0031 | keep, split | 4.1, 4.2 |
| 0032 | merge | 4.2 |
| 0033 | keep (state machine) | 1.3, 3.1 |
| 0034–0036 | keep | M11 |
| 0037–0038 | keep, moved earlier | 7.1 |
| 0039–0041 | keep | M11 |
| 0042–0052 | keep (0044 → `Mutex`) | M12 |
| 0053–0056 | keep | M13 |
| 0057 | keep | 5.1 |
| 0058 | keep, split | 5.2, M12 |
| 0059 | keep | 5.3 |
| 0060 | merge | exit criteria of M3, M4, M5, M9, M12 |
| 0061 | keep | M13 |
| 0062 | keep, widened to h3 | M10, M13 |
| 0063 | keep, moved first | 0.2 then every milestone |
| 0064 | keep | M6 |
| 0065 | keep, optional | M10, M13 |
| 0066 | wontfix | — |
| 0067 | keep | M15 |
| 0068 | wontfix | — |
