# Dynamic websites

Two ways to serve dynamic content:

| | In-process Swift | Reverse proxy |
|---|---|---|
| What | Your handlers run inside the server: `Router` routes, `WebSocketUpgrade` endpoints, any `HTTPHandler` | The server forwards path prefixes to apps on localhost (Go, Node, Python, Rails, another Swift server…) over HTTP/1.1 or a Unix socket |
| Build | Your own Swift package composing SwiftWebServer's products | The shipped executable plus a `proxy` key; no Swift code |
| Cost per request | A function call | Two loopback round trips (about 18 µs added, see [performance](performance.md)) |
| Good for | APIs and real-time endpoints written in Swift | Existing apps in any language; isolating an app in its own process |

Both mix freely with static files: static at `/`, dynamic under `/api`.

## In-process with Router

```swift
let router = try Router {
    GET("/api/users/:id") { request, context in
        guard let id = context.params.decimal("id") else { return HTTPResponse(status: .badRequest) }
        return json(#"{"id": \#(id)}"#)
    }
    POST("/api/users") { request, _ in
        let body = try await request.body.collect(upTo: 64 * 1024)   // bounded; 413-style limit is yours
        …
    }
    Group("/api/admin") {
        GET("/stats") { _, _ in … }
        Route("/files/*path", methods: [.get, .put]) { _, context in
            let path = context.params["path"] ?? ""
            …
        }
    }
}
let server = Server(listeners: [listener], protocols: [HTTP1()]) {
    router              // misses fall through to the files
    terminal(files)
}
```

A complete, runnable version (with `json(_:)`, `terminal(_:)` and signal handling) is
[`Examples/custom-server`](../../Examples/custom-server/README.md), walked through in
[Choosing components](choosing-components.md#a-custom-server-package).

Router rules:

- Patterns: literal segments, `:name` captures one non-empty segment, a trailing `*` or
  `*name` captures the rest. Literals compare with the still-encoded path; captures are
  percent-decoded when read (`context.params["id"]`, `.decimal("id")`, `.wildcard`).
- At each segment a literal beats a parameter beats a wildcard, with backtracking.
- A `GET` route also answers `HEAD` unless a `HEAD` route exists.
- A path that matches with a method no route answers gets `405` with `Allow`. Anything else
  falls through to the next element (as a middleware) or gets `404` (as a handler).
- Two routes matching the same paths with the same method are rejected when the router is
  built (`RouterError`).
- Matching allocates nothing; reading a capture as `String` allocates.

Handler rules (the request-path contract):

- An `HTTPRequest` is valid only during the call. Copy what you keep (`request.snapshot()`,
  `request.string(of: request.path)`), never store the request.
- Read bodies with a limit: `try await request.body.collect(upTo:)`, or iterate
  `request.body` (an `AsyncSequence` of `ByteBuffer`) to stream. The server already enforces
  `maxBodySize`.
- Stream large or slow responses with `.stream(length:writer:)`: each `write` waits for the
  client (backpressure), so memory stays bounded. `.file(FileRegion)` sends a file with
  `sendfile`.
- Do not block the cooperative thread pool (no synchronous network calls, `sleep`, or long CPU
  loops in a handler); offload long CPU work to your own executor or process.
- Shared mutable state: a `Mutex` (Synchronization) with short, non-suspending critical
  sections. An actor works, but every request then hops to it.
- Protect routes with `Authenticator` in front of the router, or per route with
  `GET("/me", handler: auth.protect(MeHandler()))`; the principal is `context.principal`.

## WebSockets

```swift
let chat = WebSocketUpgrade(path: "/ws",
                            origin: { $0.origin == "https://example.com" },  // stop cross-site use
                            subprotocol: { $0.offeredSubprotocols.first }) { socket, request in
    for await message in socket.messages {
        switch message {
        case .text(let text): try await socket.send(text: "echo: \(text)")
        case .binary: try await socket.send(message)
        }
    }
}
let server = Server(listeners: listeners, protocols: [HTTP2(configuration: h2), HTTP1()]) {
    chat
    router
    terminal(files)
}
```

- One component serves RFC 6455 on HTTP/1.1, RFC 8441 extended CONNECT on HTTP/2 and RFC 9220
  on HTTP/3; HTTP/2 advertises extended CONNECT automatically when a `WebSocketUpgrade` is in
  the chain.
- `socket.messages` is an `AsyncSequence` of `.text(String)` (validated UTF-8) or
  `.binary(ByteBuffer)`; the inbound queue is bounded, so a slow consumer applies backpressure.
- permessage-deflate is negotiated when `WebSocketConfiguration.compression` is set.
- On server shutdown the session closes with 1001 (going away).
- The shipped executable has no in-process WebSockets; it can only *proxy* them
  (`"websocket": true` on a mount).

## Reverse proxy to localhost apps

The executable forwards mounted path prefixes to upstream HTTP/1.1 apps and serves everything
else from files. Example with the Go app in [`Examples/go-api`](../../Examples/go-api/main.go)
(stdlib only; `GET /api/health`, CRUD on `/api/items`, `GET /api/echo` shows the forwarded
headers):

```json
{
  "root": "Public",
  "proxy": [
    { "path": "/api", "upstream": "http://127.0.0.1:9000",
      "timeouts": { "connect": 2, "response": 30 } }
  ]
}
```

```bash
(cd Examples/go-api && go run . -addr 127.0.0.1:9000) &
.build/release/SwiftWebServer --config Root/http-config.proxy.json   # needs scripts/make-test-identity.sh (TLS)
curl http://127.0.0.1:8080/api/health        # {"status":"ok"}
curl http://127.0.0.1:8080/api/echo          # shows X-Forwarded-For/Proto/Host/Prefix
curl http://127.0.0.1:8080/                  # Root/Public/index.html
```

How requests flow:

- Mounts match by path prefix on segment boundaries, longest first (`/api` matches `/api` and
  `/api/x`, not `/apix`). Paths are normalized first, so `/%61pi` and `/x/../api` match `/api`.
  In a `hosts` site, its own mounts are tried first, then the top-level ones, then its files.
- The proxy sits after `auth` and before the files: protected prefixes are checked before
  anything is forwarded, and `errorPages` renders `502`/`504`.
- Requests from HTTP/1.1, HTTP/2 and HTTP/3 clients all go upstream as HTTP/1.1, over pooled
  keep-alive connections. Hop-by-hop fields are removed. Response bodies stream through.
- A refused or failed connection, or a malformed response, is `502 Bad Gateway`; no response
  head within `timeouts.response` is `504 Gateway Timeout`. A failure after the head aborts the
  response (close on HTTP/1.1, stream reset on HTTP/2 and HTTP/3).
- After a connect failure, `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS` and `TRACE` are retried on
  the next upstream (`retries`, default 1); `POST` and `PATCH` never are.
- A client that goes away cancels the upstream request.
- `Expect: 100-continue` is answered by the server itself; `1xx` from upstream are consumed.
- WebSocket and other `Upgrade` requests are tunnelled with `"websocket": true` (h1 Upgrade,
  h2/h3 extended CONNECT become an h1 Upgrade upstream).
- Upstreams are `http://HOST:PORT[/base]` or `unix:/path/to.sock`. **`https://` upstreams are
  not supported.**

### Proxy mount reference

`proxy` is an array of mounts (a single object is accepted). The same `path` twice for
overlapping hosts is an error.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `path` | string | `"/"` | Prefix starting with `/` |
| `host` / `hosts` | string / array | all hosts | Only for these `Host` names (one of the two) |
| `upstream` / `upstreams` | string / array (required) | – | `http://HOST:PORT[/base]` or `unix:/path`. Several upstreams are used round-robin, skipping unhealthy ones (one of the two) |
| `stripPrefix` | bool | `false` | Remove the mount path before forwarding (`/api/x` → `/x`) |
| `preserveHost` | bool | `false` | Send the client's `Host` instead of the upstream's |
| `forwardedHeaders` | string | `"x-forwarded"` | `x-forwarded` (`X-Forwarded-For/Proto/Host/Prefix`), `forwarded` (RFC 7239), `both`, `none` |
| `trustedProxies` | array | `[]` | IPs or CIDR ranges (`"10.0.0.0/8"`, `"::1"`) whose forwarded fields are kept and appended to; from anyone else they are replaced |
| `rewriteLocation` | bool | `true` | Rewrite upstream `Location` and `Content-Location` into the client's URL space |
| `rewriteCookiePath` | bool | `false` | With `stripPrefix` or a base path, rewrite `Set-Cookie` `Path` (`Path=/` → `Path=/api`) |
| `websocket` | bool | `false` | Tunnel WebSocket / `Upgrade` requests |
| `timeouts.connect` | seconds | `10` | Connecting to the upstream |
| `timeouts.response` | seconds | `60` | Request sent → response head |
| `timeouts.idle` | seconds | `60` | Between body reads; also closes an idle tunnel (tunnels default to 300 s without it) |
| `timeouts.total` | seconds | none | Whole exchange |
| `retries` | integer 0–10 | `1` | Extra attempts on the next upstream after a connect failure, idempotent methods only |
| `health.failures` | integer 0–1000 | `3` | Consecutive failures that mark an upstream down (`0`: passive tracking off) |
| `health.cooldown` | seconds | `10` | How long it stays down |
| `health.path` | string | none | Active check: `GET path` every `interval`; status < 500 is healthy |
| `health.interval` | seconds > 0 | `10` | Active check period |
| `pool.maxConnections` | integer | `0` (no limit) | Connections per upstream; more requests queue |
| `pool.queue` | integer | `256` | Requests that may wait for a connection; a full queue gets `503` |
| `pool.queueTimeout` | seconds > 0 | `10` | Longest wait in the queue (`503` after) |
| `pool.maxIdle` | integer | `16` | Kept-alive idle connections per upstream. **Raise it to your expected concurrency**: with more concurrent requests than `maxIdle`, extra connections are opened and closed per request |
| `pool.idleTimeout` | seconds | `60` | Idle connections closed after this (`0` keeps them) |

For `timeouts.connect`, `response` and `idle`, `0` or `null` keeps the default rather than
turning the limit off; `total` is off unless set.

### Apache `mod_proxy` → SwiftWebServer

| Apache | `proxy` mount |
|---|---|
| `ProxyPass /api http://127.0.0.1:9000/api` | `{"path": "/api", "upstream": "http://127.0.0.1:9000"}` |
| `ProxyPass /api/ http://127.0.0.1:9000/` | `{"path": "/api", "upstream": "http://127.0.0.1:9000", "stripPrefix": true}` |
| `ProxyPass /app http://127.0.0.1:9000/v2` | `{"path": "/app", "upstream": "http://127.0.0.1:9000/v2", "stripPrefix": true}` |
| `ProxyPassReverse` | `"rewriteLocation": true` (default) |
| `ProxyPassReverseCookiePath` | `"rewriteCookiePath": true` |
| `ProxyPreserveHost On` | `"preserveHost": true` |
| `RequestHeader set X-Forwarded-Proto …` | automatic with `"forwardedHeaders": "x-forwarded"` (default) |
| `RemoteIPTrustedProxy` | `"trustedProxies": ["10.0.0.0/8"]` |
| `<Proxy balancer://…>` + `BalancerMember` | `"upstreams": [ … ]` (round-robin, unhealthy members skipped) |
| `ProxyTimeout`, `connectiontimeout=`, `timeout=` | `"timeouts": {"connect": …, "response": …, "idle": …}` |
| `retry=` on a worker | `"health": {"cooldown": …}` |
| `max=` on a worker | `"pool": {"maxConnections": …}` |
| `ProxyPass /ws ws://…` (`mod_proxy_wstunnel`) | `"websocket": true` |
| `ProxyPass … unix:/path.sock\|http://localhost/` | `"upstream": "unix:/path.sock"` |
| `ProxyPass` inside a `<VirtualHost>` | `hosts[].proxy`, or `"host"`/`"hosts"` on a top-level mount |
| `<Location /admin>` + `AuthType Basic` | `"auth": [{"paths": ["/admin"], "basic": …}]` |
| `ProxyPass` to `https://` | not supported: run the app on HTTP on localhost or a Unix socket |

## System 1 decision server (Laya)

[laya-go](https://github.com/brennanMKE/laya-go)'s `laya-server` runs Laya, a System 1 decision
model, on the Mac's GPU with Metal and serves `POST /predict` (`{"state": …, "questions": {…}}`
→ `{"answers": {…}}`, or a `"batch"` of states), `GET /health` and `GET /stats`. It has no
authentication, so keep it on loopback (`--host 127.0.0.1 --port 8000`) and put it behind a
proxy mount, with the prefix stripped so `/laya/predict` reaches `/predict`:

```json
{
  "root": "public",
  "proxy": [
    { "path": "/laya", "upstream": "http://127.0.0.1:8000", "stripPrefix": true,
      "timeouts": { "connect": 2, "response": 60 },
      "pool": { "maxIdle": 8 } }
  ],
  "auth": [ { "paths": ["/laya"], "tokens": [{ "name": "game", "sha256": "…" }] } ]
}
```

laya-server loads the model before it starts listening, so a request during its startup gets a
fast `502`, not a hang. A deployment that serves a game from one Mac and asks a laya-server on
another over Tailscale is in
[`Examples/parallax-gordon/README.md`](../../Examples/parallax-gordon/README.md).

### In-process with LayaKit (when it can answer)

> **Not runnable yet.** [LayaKit](https://github.com/brennanMKE/laya-swift), the Swift + Metal
> port of laya-go, is bootstrapped: it compiles the Metal shaders and loads the fixtures, but its
> `LayaModel` is a placeholder that cannot answer questions. The sketch below uses the API
> planned in laya-swift's `docs/swift-port.md` (`LayaModel.load`, `predict`, `LayaState`,
> `NamedQuestion`), which may change. LayaKit is **not** a dependency of SwiftWebServer; it
> would be a dependency of your own server package.

Design:

- **One shared model**, loaded once at startup (weights and Metal pipelines take time and about
  1 GB), before the listeners bind, and captured by the route closure.
- **GPU calls are serialized by the model, not by the server.** `LayaModel` is an `actor` and
  its Metal engine runs one pass at a time on its own serial executor (the GPU is saturated by
  one pass anyway). A handler simply `await`s it. That is one actor hop per prediction, which is
  acceptable here because a forward pass costs milliseconds; the server's own request path
  stays actor-free.
- **Bounded admission.** Requests queue on the actor without limit, so the handler keeps an
  in-flight count in a `Mutex` (a non-suspending check-and-increment) and answers `503` when it
  is full, instead of letting latency grow.
- **Batching** comes from the request: a `batch` body maps to one `predictMany` call (one
  forward pass). An answer cache keyed by (state, question) can sit in front, as in laya-go.
- Decoding the JSON body with Foundation is fine here: it is application code, and the pass
  dwarfs it.

```swift
import Foundation
import HTTPCore
import LayaKit          // your package's dependency, not SwiftWebServer's
import Router
import Synchronization

/// Admission control: at most `limit` predictions in flight; the rest get 503.
final class Gate: Sendable {
    private let inFlight = Mutex(0)
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func enter() -> Bool { inFlight.withLock { n in guard n < limit else { return false }; n += 1; return true } }
    func leave() { inFlight.withLock { $0 -= 1 } }
}

let model = try await LayaModel.load(LayaOptions())      // once, before the server starts
let gate = Gate(limit: 32)

let laya = try Router {
    POST("/laya/predict") { request, _ in
        guard gate.enter() else { return HTTPResponse(status: .serviceUnavailable) }
        defer { gate.leave() }
        let body = try await request.body.collect(upTo: 1 << 20)
        let (state, questions) = try decodePredictRequest(body)   // your JSON → LayaState, [NamedQuestion]
        let result = try await model.predict(state, questions)    // hops to the actor; one GPU pass
        return json(encodeAnswers(result))                        // laya-go's wire format
    }
    GET("/laya/health") { _, _ in json(#"{"ok": true}"#) }
}
// Server(…) { laya; terminal(files) } as in Examples/custom-server.
```

Until LayaKit answers, use the reverse-proxy setup above: the HTTP contract is the same, so a
client does not change when the model moves in-process.

## Production checklist

- **Upstreams on loopback or Unix sockets only.** Bind apps to `127.0.0.1` (or a socket) so
  the only way in is through SwiftWebServer, its auth and its logs.
- **Pool sizing.** Set `pool.maxIdle` to the concurrency you expect per upstream (the M17
  benchmark ran out of loopback ports with the default 16 at 64 concurrent clients before
  `maxIdle` was raised), and `pool.maxConnections` to what the app can handle.
- **Timeouts.** `connect` short (1–2 s on loopback), `response` just above your slowest
  endpoint, `total` for endpoints that must never hang; `idle` for streaming responses.
- **Health.** Several upstreams with `health.path` for active checks; `retries` only helps
  idempotent requests.
- **Forwarded headers.** Leave `x-forwarded` on so apps see the client address and scheme;
  set `trustedProxies` only for a load balancer you run in front.
- **Cookies and redirects.** With `stripPrefix`, keep `rewriteLocation` on and turn on
  `rewriteCookiePath` if the app sets `Path=/`.
- **Body limits.** `maxBodySize` (and `http2.maxRequestBodySize`) bound uploads before the app
  sees them.
- **Auth at the edge.** `auth` areas on admin and private API prefixes; HTTPS for anything
  with credentials.
- **Logging.** `accessLog` records proxied statuses (`502`/`504` included); watch for them.
- **Process supervision.** Run each app and the server under launchd (see
  [LaunchAgents](running-on-a-mac.md#running-as-a-launchagent)); the server starts fine before
  its upstreams and answers `502` until they are up.
- **Restarts.** There is no config reload: changing mounts means a restart, which drains
  in-flight requests first.
