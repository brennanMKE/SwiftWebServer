# HTTP/2 Implementation Plan

This plan takes SwiftWebServer from a one-request-per-connection HTTP/1.1 static file server to a complete HTTP/2 server ([RFC 9113](https://www.rfc-editor.org/rfc/rfc9113) with HPACK, [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541)). HTTP/1.1 stays available as a fallback. Every phase is tracked as issues in `issues/`; see `issues/Issues.md` for the phase-to-issue map.

## Design principles

1. **AsyncSequence all the way down.** Connections, bytes, frames, requests, and request/response bodies are `AsyncSequence`s. Protocol layers are sequence transformers (`bytes.http2Frames()`, `bytes.http1Requests()`), so each one is testable by feeding it an in-memory sequence.
2. **Structured concurrency owns lifetimes.** Listener → connection → stream is a tree of task groups. Shutting down cancels the root and everything below it unwinds. No unstructured `Task {}` for connection or stream work.
3. **No Combine.** No `Publisher`, `Subject`, or `@Published` anywhere. Callback APIs (Network.framework) are bridged to async at the transport edge only.
4. **Demand-driven I/O.** Bytes are read from the socket when an iterator asks for them, not pumped into an unbounded buffer. For HTTP/2 request bodies, flow-control windows are the buffer bound, and `WINDOW_UPDATE` is sent as the handler consumes data.
5. **Pure, synchronous protocol cores.** HPACK and the HTTP/2 connection state machine are plain value types with `mutating` methods and typed throws. They do no I/O and never `await`, so they can be tested exhaustively and never suffer actor reentrancy mid-transition.
6. **Swift 6 strict concurrency, zero external dependencies.** Everything is `Sendable`-checked. HPACK, framing, and channels are implemented in this repo.

## Non-goals

- HTTP/3 / QUIC.
- Server push and HTTP/1.1 `Upgrade: h2c` are optional, off by default (Phase 12). Major browsers no longer accept push, and RFC 9113 deprecates the h2c upgrade.

## Baseline (September 2026)

- `HTTPServer` accepts `NWConnection`s and handles each in an unstructured `Task`.
- `ConnectionStream` eagerly pumps `receive` callbacks into an unbounded `AsyncStream` (no backpressure).
- `HTTPRequest.parse` is a single-shot string parser. `HTTPResponse` hard-codes `HTTP/1.1` and a `[String: String]` header dictionary.
- The connection closes after one response. There is no TLS.
- Bugs in this code are filed as issues #0001–#0026 (Phases 1–5). Phase 6 replaces much of the connection and parsing code, but the tests written while fixing those bugs carry forward as regression tests.

## Architecture

```
NWListener (or NetworkListener)
   │  connections: AsyncSequence<any Transport>
   ▼
Server.run()  ── withThrowingDiscardingTaskGroup ── one child per connection (bounded by maxConnections)
   │
   ▼
Transport
   inbound: AsyncSequence<ArraySlice<UInt8>>      (demand-driven receive)
   write(_:) async throws                         (suspends until the send completes)
   │
   ▼
ProtocolSelector ── ALPN "h2" ─────────────┐
   │ cleartext: peek 24 octets for preface │
   ▼                                       ▼
HTTP1Connection                        HTTP2Connection
 bytes.http1Requests()                  bytes.http2Frames(maxFrameSize:)
 sequential keep-alive                    │
   │                                      ├─► HTTP2ConnectionStateMachine (pure struct)
   │                                      ├─► stream child tasks (task group, ≤ MAX_CONCURRENT_STREAMS)
   │                                      └─► FrameWriter (single task; owns HPACK encoder)
   ▼                                      ▼
            HTTPHandler.handle(_ request: HTTPRequest) async throws -> HTTPResponse
                    middleware chain → StaticFileHandler
```

### Core type sketches

```swift
// Transport edge: the only place callbacks are bridged.
public protocol Transport: Sendable {
    associatedtype Inbound: AsyncSequence<ArraySlice<UInt8>, any Error> & Sendable
    var inbound: Inbound { get }
    var negotiatedProtocol: String? { get }          // ALPN result, nil on cleartext
    func write(_ bytes: [UInt8]) async throws
    func close() async
}

// Protocol layers are AsyncSequence transformers.
extension AsyncSequence where Element == ArraySlice<UInt8> {
    func http2Frames(maxFrameSize: UInt32) -> HTTP2FrameSequence<Self>
    func http1Requests(limits: HTTP1Limits) -> HTTP1RequestSequence<Self>
}

// Protocol-agnostic messages shared by HTTP/1.1 and HTTP/2.
public struct HTTPFields: Sendable, Sequence { /* ordered, case-insensitive lookup, duplicates kept */ }

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var scheme: String?
    public var authority: String?
    public var path: String
    public var headerFields: HTTPFields
    public var body: HTTPBody                        // AsyncSequence<ArraySlice<UInt8>, any Error>
}

public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headerFields: HTTPFields
    public var body: HTTPBody
    public var trailerFields: HTTPFields?
}

public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest) async throws -> HTTPResponse
}
```

### HTTP/2 connection loop

```swift
func run() async throws {
    try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await writer.run() }                 // drains outbound frames
        try await writer.enqueue(.settings(localSettings))       // server preface
        for try await frame in transport.inbound.dropPreface().http2Frames(maxFrameSize: limits.maxFrameSize) {
            for action in try await connection.receive(frame) {  // actor wraps the pure state machine
                switch action {
                case .startStream(let stream): group.addTask { await serve(stream) }
                case .send(let frame):         try await writer.enqueue(frame)
                case .cancelStream(let id):    await connection.cancel(id)
                case .goAway(let error):       try await shutdown(error, group: group)
                }
            }
        }
    }
}
```

### Concurrency rules

| Concern | Rule |
|---|---|
| Lifetimes | Listener group → connection → streams. Parent cancellation cancels children. |
| Reads | Iterator `next()` triggers `receive`. Nothing is read ahead of demand except one read (≤ 16 KiB). |
| Writes | One `FrameWriter` task per connection. It is the only code that touches the socket and the only owner of the HPACK encoder, so dynamic-table state always matches wire order and HEADERS + CONTINUATION stay contiguous. |
| State | `HTTP2ConnectionStateMachine` is a `struct` wrapped by an `actor`. No `await` happens inside a state transition. |
| Flow control | Response writers `await` window credit. Waiters are continuations held by the actor, resumed on `WINDOW_UPDATE`/`SETTINGS`, and removed by `withTaskCancellationHandler`. |
| Request bodies | The body iterator pulls buffered DATA from the actor. Pulling returns credit, which schedules `WINDOW_UPDATE`. The receive window bounds buffered bytes. |
| Cancellation | Inbound `RST_STREAM` → cancel that stream's child task. Handler throws or is cancelled → outbound `RST_STREAM`. Connection error → `GOAWAY`, then cancel the group. |
| Shutdown | `ExitHandler` triggers graceful `GOAWAY(2³¹−1)` → PING round-trip → final `GOAWAY(lastStreamID)` → drain in-flight streams with a deadline. |

## Protocol selection

- **TLS:** configure ALPN with `sec_protocol_options_add_tls_application_protocol` for `h2` and `http/1.1`, and read the result via `sec_protocol_metadata_get_negotiated_protocol`. Require TLS 1.2 or later and follow the RFC 9113 §9.2 cipher restrictions.
- **Cleartext (h2c prior knowledge):** peek the first 24 octets. If they equal `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, run HTTP/2. Otherwise replay the peeked bytes into the HTTP/1.1 codec. This is what `curl --http2-prior-knowledge` and `h2spec` use, so it is the first milestone because it needs no certificates.

## HPACK

Pure Swift target `HPACK` with no Foundation:

- Integer encoding with N-bit prefixes, and string literals with and without Huffman coding (Appendix B code table, EOS padding validation).
- 61-entry static table. Dynamic table with RFC 7541 §4.1 entry size (name + value + 32), eviction, and size updates bounded by `SETTINGS_HEADER_TABLE_SIZE`.
- Decoder: all four representations, dynamic table size update only at the start of a block, and `COMPRESSION_ERROR` on any violation. Header list size is enforced during decoding, not after, to defeat HPACK bombs.
- Encoder: incremental indexing for common fields, never-indexed for `authorization`, `cookie`, and `set-cookie`, and Huffman coding when shorter.
- Tests use the RFC 7541 Appendix C vectors (C.1–C.6) verbatim.

## Default limits

| Setting | Default | Notes |
|---|---|---|
| `SETTINGS_MAX_CONCURRENT_STREAMS` | 100 | Excess streams get `RST_STREAM(REFUSED_STREAM)` |
| `SETTINGS_INITIAL_WINDOW_SIZE` | 65,535 | Connection window raised to 1 MiB via `WINDOW_UPDATE` after preface |
| `SETTINGS_MAX_FRAME_SIZE` | 16,384 | |
| `SETTINGS_MAX_HEADER_LIST_SIZE` | 16,384 | Also caps total HEADERS + CONTINUATION bytes |
| `SETTINGS_HEADER_TABLE_SIZE` | 4,096 | |
| `SETTINGS_ENABLE_PUSH` | omitted (0) | A server must never send 1 |
| SETTINGS ACK timeout | 10 s | `GOAWAY(SETTINGS_TIMEOUT)` |
| Stream resets | 100 per 10 s | `GOAWAY(ENHANCE_YOUR_CALM)` (rapid reset, CVE-2023-44487) |
| Queued outbound control frames | 1,000 | Defends PING/SETTINGS floods |
| Idle connection | `keepAliveTimeout` | Graceful `GOAWAY(NO_ERROR)` |

## Configuration additions

```json
"http2": {
  "enabled": true,
  "cleartext": true,
  "maxConcurrentStreams": 100,
  "initialWindowSize": 65535,
  "maxFrameSize": 16384,
  "maxHeaderListSize": 16384,
  "headerTableSize": 4096
},
"tls": {
  "enabled": false,
  "port": 8443,
  "identity": "certs/server.p12",
  "passphraseEnvironmentVariable": "TLS_PASSPHRASE"
}
```

All new keys must be optional with defaults (see #0023).

## Package layout

```
Sources/
  HPACK/                   pure Swift, no Foundation
  HTTP2/                   frames, frame sequence, errors, settings, state machine (depends on HPACK)
  SwiftWebServerCore/      transport, HTTP/1.1 codec, connection runners, handlers, config
  SwiftWebServer/          executable
Tests/
  HPACKTests/
  HTTP2Tests/
  SwiftWebServerCoreTests/ in-memory transport tests + curl integration tests
```

## Phases

Bugs come first so the HTTP/2 work lands on a tested, stoppable server.

| Phase | Name | Issues | Exit criteria |
|---|---|---|---|
| 1 | Test foundations | #0001–#0002 | `swift test` runs; a server can be created on an ephemeral port in a test |
| 2 | Lifecycle and connection handling | #0003–#0010 | Server stops on SIGINT/SIGTERM, fails fast on bad config, parses fragmented requests |
| 3 | Security | #0011–#0015 | Bounded buffers, timeouts, working block list and containment |
| 4 | HTTP/1.1 semantics | #0016–#0022 | HEAD, 304, conditional requests, and required headers are correct |
| 5 | Config, performance, docs | #0023–#0026 | Config defaults work, files are not rehashed per request, docs match reality |
| 6 | AsyncSequence architecture | #0027–#0033 | Transport, message types, handler, and HTTP/1.1 keep-alive codec run on the new pipeline |
| 7 | HTTP/2 wire layer | #0034–#0041 | Frame codec and HPACK pass unit tests including the RFC 7541 Appendix C vectors |
| 8 | HTTP/2 connections and streams | #0042–#0052 | `curl --http2-prior-knowledge` fetches files, including concurrent requests |
| 9 | Flow control and limits | #0053–#0056 | Large files stream under flow control; abuse patterns trigger GOAWAY |
| 10 | TLS and ALPN | #0057–#0059 | `curl --http2 -k https://localhost:8443/` and browsers negotiate h2 |
| 11 | Conformance and performance | #0060–#0064 | h2spec passes; h2load benchmarks recorded |
| 12 | Optional extensions | #0065–#0068 | Priorities, push, extended CONNECT, h2c upgrade |

## Testing strategy

- **Unit (Swift Testing):** HPACK vectors, frame round-trips, and table-driven state machine tests (frames in → actions out, no concurrency).
- **Connection tests:** an in-memory `Transport` pair drives `HTTP2Connection` byte-for-byte without sockets. This covers stream interleaving, cancellation, flow-control stalls, and GOAWAY.
- **Integration:** start the server on an ephemeral port inside a test and run `curl --http2-prior-knowledge`, `curl --http2 -k`, and `curl --http1.1`. The system curl (8.7.1 with nghttp2) supports all three.
- **Conformance:** [h2spec](https://github.com/summerwind/h2spec) (`brew install h2spec`) via a `run-h2spec.sh` script.
- **Load:** `h2load` from nghttp2 (`brew install nghttp2`).
- **Browsers:** a manual Safari, Chrome, and Firefox check over TLS with a locally trusted certificate.

## Decisions

1. **Network API.** Recommended: keep `NWConnection`/`NWListener` behind the `Transport` protocol, which preserves the macOS 15 deployment target and uses the proven ALPN metadata APIs. The installed macOS 26 SDK also ships `NetworkListener`/`NetworkConnection` with async `run`/`receive` and `TLS().applicationProtocols(_:)`. Because codecs only see `Transport`, switching adapters later is a contained change.
2. **Dependencies.** Recommended: none. `swift-http-types` and `swift-async-algorithms` would replace #0030 and the outbound channel, but they conflict with building the protocol here.
3. **Server push and h2c Upgrade.** Implement last, behind config flags, off by default.

## References

- RFC 9113 — HTTP/2
- RFC 7541 — HPACK
- RFC 9110 — HTTP Semantics
- RFC 9218 — Extensible Prioritization Scheme for HTTP
- RFC 8441 — Bootstrapping WebSockets with HTTP/2
- RFC 7540 §3.2 — h2c Upgrade (obsoleted)
- CVE-2023-44487 — HTTP/2 Rapid Reset
- VU#421644 — HTTP/2 CONTINUATION frame flood (2024)
