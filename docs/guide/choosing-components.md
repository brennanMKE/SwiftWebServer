# Choosing components

There are two ways to choose what goes into a server:

1. **Configure the shipped executable.** Every component the executable knows is compiled in,
   but only the ones your `http-config.json` enables are registered in the request path. A
   disabled component costs nothing per request. HTTP/2 and HTTP/3 can also be compiled out
   with package traits.
2. **Build your own server** as a Swift package that depends on SwiftWebServer's library
   products and composes exactly the components it needs, plus your own handlers.

## Targets and products

Every library target is also a library product of the same name. The package has no external
dependencies, so depending on one product pulls in only the targets listed in its dependency
column (transitively).

| Product | Depends on | What it does | Include it when |
|---|---|---|---|
| `HTTPCore` | – | `ByteBuffer`, `HTTPFields`, `HTTPRequest`/`HTTPResponse`, `HTTPHandler`/`HTTPMiddleware`, `MiddlewareBuilder`, `RequestContext`, transport protocols, `BoundedAsyncQueue` | Always (everything uses it) |
| `HTTP1` | HTTPCore | HTTP/1.1 parser, serializer, chunked codec, connection runner (`HTTP1`, `HTTP1Configuration`, `HTTP1Timeouts`) | Always: every TCP server speaks HTTP/1.1 |
| `HTTPServer` | HTTPCore, HTTP1 | `Server`, `ServerConfiguration`, `ServerListener`, protocol registry, lifecycle and drain | Always |
| `NetworkTransport` | HTTPCore | `BSDSocketListener` (POSIX + kqueue), `TCPListener` (Network.framework, optional TLS), `QUICListener`, `TLSIdentity`, `TLSConfiguration` | Always (you need a listener) |
| `HeaderCompression` | – | Prefix integers and Huffman shared by HPACK and QPACK | Pulled in by HPACK/QPACK |
| `HPACK` | HeaderCompression, HTTPCore | HTTP/2 header compression | Pulled in by HTTP2 |
| `QPACK` | HeaderCompression, HTTPCore | HTTP/3 header compression | Pulled in by HTTP3 |
| `HTTP2` | HPACK, HTTPCore | HTTP/2 over TLS (ALPN `h2`) or h2c prior knowledge; flow control, priorities, abuse limits | You serve HTTPS and want HTTP/2 |
| `HTTP3` | QPACK, HTTPCore | HTTP/3 over a `QUICListener`, plus the `AltSvc` middleware | You serve HTTPS and want HTTP/3 |
| `WebSockets` | HTTPCore, Compression | `WebSocketUpgrade` middleware and `WebSocket` sessions; permessage-deflate; over h1, h2 and h3 | In-process WebSocket endpoints |
| `StaticFiles` | HTTPCore, Compression | `StaticFiles` (files, index, MIME, ETags, conditional requests, Range, `sendfile`, small-file cache) and `ErrorPages` | You serve files, or want HTML error pages |
| `Compression` | HTTPCore | `Compression` middleware: br, gzip, deflate negotiation; streamed for large bodies | Text responses over slow links |
| `VirtualHosts` | HTTPCore | `VirtualHosts`: a handler chain per `Host` name, wildcards, default site | Several sites on one server |
| `Auth` | HTTPCore | `Authenticator`: Basic (PBKDF2), HS256 JWT, static bearer tokens, failure limiter | Protected paths |
| `AccessLog` | HTTPCore | `AccessLog` (Common, Combined, JSON lines; buffered, never blocks a request) and `MetricsEndpoint` (Prometheus) | Request logs or metrics |
| `Router` | HTTPCore | `Router` with `GET`/`POST`/… route DSL, `:params`, wildcards, groups; allocation-free matching | In-process Swift endpoints |
| `Proxy` | HTTPCore, HTTP1, NetworkTransport | `ReverseProxy` middleware: mounts, pooled upstream client, timeouts, retries, health, WebSocket tunnelling | Forwarding paths to local apps |
| `ConfigFile` | HTTPCore, HTTP1, HTTPServer, StaticFiles, Compression, VirtualHosts, Auth, Proxy, AccessLog | `ConfigFile.load`, `ServerSettings`, `makeHandler()`: the `http-config.json` schema | You want the JSON config in your own binary |
| `HTTPTestSupport` | HTTPCore, HTTP1 | In-memory transports and a reference parser for tests | Your tests |

Executables: `SwiftWebServer` (the shipped server: ConfigFile, HTTP1, HTTPServer,
NetworkTransport, plus HTTP2 and HTTP3 by trait) and `sws-bench` (benchmarks, `serve` test
server, `hash-password`).

`ErrorPages` is part of the `StaticFiles` target, and `AltSvc` part of `HTTP3`; neither has a
product of its own.

## Package traits for the executable

The `SwiftWebServer` executable links HTTP/2 and HTTP/3 through package traits, both on by
default. There is no `WebSockets` trait: the executable has no in-process WebSocket endpoints
(those need Swift code, `WebSocketUpgrade`, so they belong in a custom server), and WebSocket
*proxying* (`"websocket": true` on a mount) is part of `Proxy` and always available.

| Trait | Effect when off |
|---|---|
| `HTTP2` | HPACK and HTTP2 are not linked; HTTPS speaks HTTP/1.1 only. `"http2": {"cleartext": true}` then fails at startup |
| `HTTP3` | QPACK and HTTP3 are not linked; an `http3` key fails at startup with "this build has no HTTP/3" |

```bash
swift build -c release -j 2 --product SwiftWebServer --disable-default-traits   # HTTP/1.1 only
swift build -c release -j 2 --product SwiftWebServer --traits HTTP2              # h1 + h2, no h3
```

Everything else in the executable is chosen at run time by the config file.

## A custom server package

`Examples/custom-server` is a complete, buildable package (verified with `swift build` against
this checkout). Its manifest:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MySite",
    platforms: [.macOS(.v15)],
    dependencies: [
        // From GitHub:
        // .package(url: "https://github.com/brennanMKE/SwiftWebServer.git", branch: "main"),
        .package(name: "SwiftWebServer", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MySite",
            dependencies: [
                .product(name: "HTTPCore", package: "SwiftWebServer"),
                .product(name: "HTTP1", package: "SwiftWebServer"),
                .product(name: "HTTP2", package: "SwiftWebServer"),
                .product(name: "HTTPServer", package: "SwiftWebServer"),
                .product(name: "NetworkTransport", package: "SwiftWebServer"),
                .product(name: "StaticFiles", package: "SwiftWebServer"),
                .product(name: "Router", package: "SwiftWebServer"),
                .product(name: "WebSockets", package: "SwiftWebServer"),
                .product(name: "Compression", package: "SwiftWebServer"),
                .product(name: "AccessLog", package: "SwiftWebServer"),
            ]),
    ]
)
```

The package requires a Swift 6.4 toolchain (its manifest is `swift-tools-version: 6.4`) and
macOS 15.

The server (`Examples/custom-server/Sources/MySite/MySite.swift`):

```swift
import AccessLog
import Compression
import Darwin
import Dispatch
import HTTP1
import HTTP2
import HTTPCore
import HTTPServer
import NetworkTransport
import Router
import StaticFiles
import WebSockets

/// A JSON response from a string.
func json(_ text: String, status: HTTPStatus = .ok) -> HTTPResponse {
    var headers = HTTPFields()
    headers.append(.contentType, "application/json")
    return HTTPResponse(status: status, headers: headers, body: .bytes(ByteBuffer(bytes: Array(text.utf8))))
}

/// Runs `action` on SIGINT and SIGTERM. A plain (nonisolated) function, so the handler does
/// not inherit `main()`'s main-actor isolation; it runs on a dispatch queue.
func onShutdownSignal(_ action: @escaping @Sendable () -> Void) -> [any DispatchSourceSignal] {
    let queue = DispatchQueue(label: "signals")
    return [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler(handler: action)
        source.resume()
        return source
    }
}

@main
struct MySite {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = arguments.count > 1 ? arguments[1] : "Public"
        let port = arguments.count > 2 ? UInt16(arguments[2]) ?? 8080 : 8080

        let router = try Router {
            GET("/api/hello/:name") { _, context in
                json(#"{"hello": "\#(context.params["name"] ?? "")"}"#)
            }
            POST("/api/echo") { request, _ in
                let body = try await request.body.collect(upTo: 1 << 20)
                var headers = HTTPFields()
                headers.append(.contentType, "application/octet-stream")
                return HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
            }
        }
        let echo = WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages {
                try await socket.send(message)
            }
        }
        let files = try StaticFiles(root: root)
        let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: port))

        // HTTP/2 only where TLS negotiates it by ALPN (add a TLS listener to use it); cleartext
        // connections go straight to HTTP/1.1 with no first-bytes sniffing.
        let protocols = [TLSNegotiated(HTTP2(), fallback: HTTP1())]
        let server = Server(listeners: [listener], protocols: protocols) {
            AccessLog(format: .combined, destination: .standardOutput)
            Compression()
            echo
            router
            files               // the last element is the terminal handler
        }

        // SIGINT and SIGTERM: stop accepting, let open connections finish, then return.
        let signals = onShutdownSignal { server.requestShutdown() }
        defer { signals.forEach { $0.cancel() } }

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.run() }   // returns after a graceful shutdown
            group.addTask {
                for address in try await server.waitUntilRunning() { print("listening \(address)") }
            }
        }
    }
}
```

Verified on 2026-11-12: `GET /api/hello/swift` returned `{"hello": "swift"}`, `POST
/api/echo` echoed its body, `GET /` served `Root/Public/index.html`, the access log printed
Combined lines, and SIGINT drained and exited 0.

Things to know when composing:

- **The last element is the terminal handler.** `StaticFiles`, `Router` and `VirtualHosts`
  conform to both `HTTPMiddleware` and `HTTPHandler`. Written last (`files` above) they are
  the handler that answers what nothing before them did; in the middle of a chain they are
  middlewares (a `Router` miss falls through to the next element).
- **Signal handlers must not be main-actor isolated.** A closure written inside an `@main`
  `main()` inherits the main actor; called from a dispatch source it traps
  (`dispatch_assert_queue`). Install the sources from a nonisolated function as above.
- **Order matters.** Put `AccessLog` first to record every final status, `Compression`
  before anything that produces text, `ErrorPages` outside the handlers whose `4xx`/`5xx` it
  should fill, `Authenticator` before what it protects.
- **Ports.** `BSDSocketListener` binds `127.0.0.1` by default; pass `"0.0.0.0"` or `"::"` to
  serve the network (see [the firewall prompt](running-on-a-mac.md#binding-to-all-interfaces-and-the-firewall-prompt)).
  Port 0 picks a free port; `waitUntilRunning()` returns the bound addresses.

### Reuse `http-config.json` and add your own routes

`ConfigFile` turns the JSON config into the same chain the executable uses. Put your own
middleware in front of it:

```swift
import ConfigFile
import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import Router

let file = try ConfigFile.load(path: "http-config.json")
for warning in file.warnings { print("warning:", warning) }
let settings = file.settings
try settings.validate()
let site = try settings.makeHandler(environment: ProcessInfo.processInfo.environment)

let api = try Router {
    GET("/api/time") { _, _ in
        HTTPResponse(status: .ok, body: .bytes(ByteBuffer(bytes: Array("\(Date())".utf8))))
    }
}
let listener = try BSDSocketListener(configuration: .init(host: settings.host, port: settings.port))
let server = Server(configuration: settings.serverConfiguration, listeners: [listener],
                    protocols: [HTTP1(configuration: settings.http1Configuration)]) {
    api      // your routes first; misses fall through
    site     // everything http-config.json configures (static files, proxy, auth, logs…)
}
try await server.run()
```

`makeHandler()` returns an opaque `some HTTPHandler`, which is a handler only. Its
access log sits inside `api` here, so requests answered by `api` are not logged; put `AccessLog`
in front yourself if you need them. This sketch has only the cleartext listener; the
executable's `makeListeners` in `Sources/SwiftWebServer/ServerMain.swift` shows how it adds the
TLS and QUIC listeners from `settings.tls` and `settings.http3`.

### HTTPS, HTTP/2 and HTTP/3 in Swift

```swift
import HTTP1
import HTTP2
import HTTP3
import HTTPCore
import HTTPServer
import NetworkTransport
import StaticFiles

let identity = try TLSIdentity(pkcs12Path: "server.p12", password: password)   // memory only
let files = try StaticFiles(root: "Public")
let altSvc = AltSvc(maxAge: 86_400)
let listeners: [ServerListener] = [
    .byteStream(try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 8080)), name: "http"),
    .byteStream(name: "https") { bind in
        try TCPListener(configuration: .init(host: "127.0.0.1", port: 8443),
                        tls: TLSConfiguration(identity: identity, alpn: bind.alpnTokens))
    },
    .multiplexed(name: "h3", protocol: HTTP3()) { bind in
        try QUICListener(configuration: .init(host: "127.0.0.1", port: 8443,
                                              quic: QUICConfiguration(alpn: bind.alpnTokens)),
                         identity: identity)
    },
]
let server = Server(listeners: listeners, protocols: [TLSNegotiated(HTTP2(), fallback: HTTP1())]) {
    altSvc
    files
}
altSvc.advertise(port: 8443)
try await server.run()
```

- `bind.alpnTokens` comes from the registered protocols (`h2`, `http/1.1`; `h3` for QUIC), so
  ALPN always matches what the server can speak.
- Listeners bind in order. A QUIC listener can use `bind.boundAddresses` to take the TLS
  listener's port number when that was 0, as the executable does.
- `TLSNegotiated(HTTP2(), fallback: HTTP1())` (HTTPServer) is one protocol that offers `h2`
  and `http/1.1` by ALPN and runs HTTP/2 only when TLS negotiated `h2`. Cleartext connections
  go straight to HTTP/1.1: with a single protocol registered nothing is read ahead. The
  executable registers exactly this unless `"http2": {"cleartext": true}`.
- `[HTTP2(), HTTP1()]` instead also serves h2c (HTTP/2 prior knowledge) on cleartext, at the
  cost of sniffing the first bytes of every cleartext connection. Register HTTP/2 first:
  HTTP/1.1's sniff also matches the `PRI * HTTP/2.0` preface.
- `HTTP2` advertises extended CONNECT automatically when a `WebSocketUpgrade` is in the chain,
  so the same WebSocket endpoint works over h2 and h3.

These snippets were compiled against this checkout in a scratch package (2026-11-12).

### Virtual hosts and authentication in Swift

```swift
import Auth
import VirtualHosts

let users = try CredentialStore(lines: try String(contentsOfFile: "users.htpasswd", encoding: .utf8))
let auth = try Authenticator(paths: ["/admin"], realm: "Admin", basic: users)
let blog = try StaticFiles(root: "sites/blog")
let main = try StaticFiles(root: "sites/main")
let hosts = try VirtualHosts {
    VirtualHost("blog.example.com", "*.blog.example.com", handler: blog)
    VirtualHost.default(handler: main)
}
let server = Server(listeners: [listener], protocols: [HTTP1()]) {
    auth
    hosts
}
```

Each `VirtualHost` takes any handler, including a whole `MiddlewareBuilder` chain
(`VirtualHost("a.test") { Compression(); filesA }`).
