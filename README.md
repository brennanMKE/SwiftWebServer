# SwiftWebServer

A modular HTTP/1.1, HTTP/2 and HTTP/3 web server for the Mac, written in Swift 6 with Swift
Concurrency and **no package dependencies**. Use it as a ready-made server configured by one
JSON file, or compose its components into your own Swift server.

- **macOS 15 or later only.** Built on Darwin (BSD sockets, kqueue, `sendfile`) and
  Network.framework (TLS, QUIC). Not built or tested on Linux.
- **Fast.** With kept-alive connections it serves static files faster than nginx, h2o, Apache
  and Caddy on the same machine, behind only lighttpd; HTTP/2 passes h2spec (146/146).
  See [performance notes](docs/guide/performance.md).
- **Small core, optional components.** A component that is not configured is not in the
  request path at all.

## Features

| Area | What you get |
|---|---|
| Protocols | HTTP/1.1 (keep-alive, pipelining, chunked bodies, `100-continue`); HTTP/2 over TLS via ALPN (optional h2c); HTTP/3 over QUIC with `Alt-Svc` discovery; WebSockets over all three |
| Static files | Index files, MIME types, strong ETags, conditional requests (`304`/`412`), single `Range` (`206`), `sendfile` for large files, an in-memory cache for small ones, traversal and dotfile protection |
| Compression | Brotli, gzip, deflate; static files compressed once or served from `.br`/`.gz` sidecars |
| Sites | Virtual hosts with wildcards; custom (per-site) or generated error pages |
| Security | TLS from a PKCS#12 file loaded in memory (no keychain); Basic (PBKDF2), HS256 JWT and bearer-token auth with failure limiting; HTTP/2 abuse limits |
| Dynamic content | Reverse proxy to local apps over TCP or Unix sockets (pooling, timeouts that `0` turns off for streaming, retries, health checks, WebSocket tunnelling); in-process `Router` and `WebSocketUpgrade` for Swift handlers |
| Operations | Access log (Common, Combined, JSON) and Prometheus metrics; connection limits and timeouts; graceful drain on SIGINT/SIGTERM |

## Quick start

```bash
swift build -c release -j 2 --product SwiftWebServer
.build/release/SwiftWebServer --config Root/http-config.json     # serves Root/Public
curl http://127.0.0.1:8080/
```

Serve any directory: `.build/release/SwiftWebServer --root ~/Sites/example --port 8080`. The
server binds `127.0.0.1` unless you set `"host": "0.0.0.0"`, and prints `listening HOST:PORT`
once ready. Ctrl-C (or SIGTERM) drains open connections and exits.

HTTPS, HTTP/2 and HTTP/3 locally:

```bash
scripts/make-test-identity.sh                                    # self-signed .test-identity/server.p12
.build/release/SwiftWebServer --config Root/http-config.tls.json
curl -k https://127.0.0.1:8443/                                  # HTTP/2
/opt/homebrew/opt/curl/bin/curl --http3-only -k https://127.0.0.1:8443/
```

A static site with an app behind it:

```json
{
  "root": "public",
  "compression": true,
  "accessLog": { "path": "logs/access.log", "format": "combined" },
  "proxy": [ { "path": "/api", "upstream": "http://127.0.0.1:9000" } ]
}
```

Your own server in Swift, with only the parts you need:

```swift
let server = Server(listeners: [try BSDSocketListener()], protocols: [HTTP1()]) {
    AccessLog(format: .combined, destination: .standardOutput)
    Compression()
    router              // a Router with your routes; misses fall through
    files               // StaticFiles, the terminal handler
}
try await server.run()
```

The complete version is [`Examples/custom-server`](Examples/custom-server/README.md).

## Documentation

| Guide | |
|---|---|
| [Overview and architecture](docs/guide/overview.md) | Core and optional components, protocols, transports, the handler chain |
| [Choosing components](docs/guide/choosing-components.md) | Every target and product; building a custom server package |
| [Running on a Mac](docs/guide/running-on-a-mac.md) | Command line, the full `http-config.json` reference, TLS certificates, public binding, LaunchAgents, logs, shutdown |
| [Static websites](docs/guide/static-sites.md) | Files, caching, Range, error pages, compression, virtual hosts, auth |
| [Dynamic websites](docs/guide/dynamic-sites.md) | Router and WebSockets in Swift; reverse proxy (Go app, Laya decision server); Apache `mod_proxy` mapping; production checklist |
| [Performance notes](docs/guide/performance.md) | Benchmark summary and links |

Design and project records: [ROADMAP](docs/ROADMAP.md) (architecture, authoritative),
[MIDDLEWARE](docs/MIDDLEWARE.md), [PROGRESS](docs/PROGRESS.md),
[SERVER-COMPARISON](docs/SERVER-COMPARISON.md), [benchmarks](docs/benchmarks/README.md),
[all docs and scripts](docs/README.md).

Examples: [`Examples/custom-server`](Examples/custom-server/README.md) (a Swift package
composing the components), [`Examples/go-api`](Examples/go-api/main.go) (an upstream app for
the reverse proxy).

## Development

```bash
swift build -j 2
scripts/guarded.sh -t 900 -- swift test -j 2                     # all tests
scripts/guarded.sh -t 600 -- swift test -j 2 --filter ConfigFileTests
```

Agents working in this repository must follow [AGENTS.md](AGENTS.md) (no system prompts,
loopback-only binds, guarded runs); the issue workflow is in [issues/Issues.md](issues/Issues.md).
