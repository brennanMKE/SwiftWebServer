# SwiftWebServer

A modular HTTP/1.1, HTTP/2 and HTTP/3 server written in Swift 6 with Swift Concurrency, with no
package dependencies. It runs on **macOS 15 or later only**. It uses Darwin and Network.framework
APIs and is not built or tested on Linux.

The shipped `SwiftWebServer` executable serves **HTTP/1.1** over cleartext TCP, **HTTP/1.1 and
HTTP/2** over **TLS** (chosen by ALPN), and **HTTP/3** over QUIC, all at once from one config.
The server core is small. Every other feature is an optional component that is compiled
into the middleware chain only when registered (see [docs/MIDDLEWARE.md](docs/MIDDLEWARE.md)).

On this machine's benchmarks it serves kept-alive connections faster than nginx, h2o, Apache and
Caddy, behind only lighttpd. It passes the h2spec HTTP/2 conformance suite (146/146). See
[docs/SERVER-COMPARISON.md](docs/SERVER-COMPARISON.md).

## Features

- **HTTP/1.1**: keep-alive, pipelining, `Content-Length` and chunked request bodies,
  `Expect: 100-continue`, correct `HEAD`/`204`/`304` framing, `Date` on every response.
- **Limits and timeouts**: request head size (`431`), body size (`413`), header, idle, body
  and send timeouts (`408` or close), lingering close, and a connection limit with
  backpressure.
- **Static files**: index files, MIME types from a built-in table plus overrides, a block
  list and dotfile refusal (`403`), percent-decoding done once, containment checked after
  `realpath` with a symlink policy (traversal answers `403`), and a `301` that adds the
  trailing `/` to directory paths. Large files go out with `sendfile(2)` from an open
  descriptor and are never read into memory. Small files are cached with pre-rendered
  headers.
- **Caching**: strong metadata ETags (size, mtime and inode; no hashing), `Last-Modified`,
  `Cache-Control: public, max-age=N`, and conditional requests evaluated in RFC 9110 order
  (`If-Match`, `If-Unmodified-Since`, `If-None-Match` with lists and `*`,
  `If-Modified-Since`, `If-Range`), answering `304`/`412`. Single `Range` requests get
  `206`/`416`.
- **Methods**: `GET` and `HEAD`. Anything else gets `405` with `Allow: GET, HEAD`.
- **Error pages**: `4xx`/`5xx` responses without a body get a generated HTML page or a file
  you configure. `304`, `HEAD` and responses with a body are never touched.
- **Lifecycle**: SIGINT and SIGTERM stop accepting connections, let open connections finish
  within a grace period, and exit 0. A bad config, a missing root or a port in use exits 1
  with a message on stderr.
- **Transports**: POSIX sockets with kqueue by default, or Network.framework.
- **HTTPS and HTTP/3**: a TLS listener (Network.framework, ALPN from the registered
  protocols) and a QUIC listener serving HTTP/3, by default on the TLS port number over UDP.
  The identity is a PKCS#12 file loaded in memory only. One connection limit and one graceful
  drain cover every listener; on SIGTERM HTTP/3 connections get `GOAWAY` and finish their
  requests. HTTPS responses carry `Alt-Svc: h3=":PORT"; ma=SECONDS` so clients discover
  HTTP/3; cleartext and HTTP/3 responses do not.
- **HTTP/2**: offered on HTTPS via ALPN (`http2` key), and as prior-knowledge h2c on cleartext
  when enabled. It provides HPACK, per-stream and connection flow control with fair
  scheduling, RFC 9218 priorities, graceful `GOAWAY`, and limits against known HTTP/2 attacks
  (rapid reset, CONTINUATION, PING/SETTINGS/empty-frame floods, slow reads). Passes h2spec.
- **HTTP/3**: QPACK (static table), control streams, `GOAWAY` drain, RFC 9218 priorities, and
  abuse limits. Network.framework does not send our application close code (see
  [docs/notes/nw-transport.md](docs/notes/nw-transport.md)).
- **Optional components** (each in its own target):
  - Wired into the config file: `StaticFiles`, `ErrorPages`, `Compression` (gzip, br, deflate),
    `VirtualHosts`, `Auth` (Basic with PBKDF2, HS256 JWT, static tokens) and `AltSvc`.
  - Library components, not configurable from `http-config.json` yet: `AccessLog` (CLF,
    Combined, JSON lines, plus lock-free metrics and a Prometheus `/metrics` endpoint),
    `Router` (a segment trie with `:params` and wildcards, allocation-free matching) and
    `WebSockets` (RFC 6455 with permessage-deflate, over HTTP/1.1, over HTTP/2 via RFC 8441 and
    over HTTP/3 via RFC 9220). Use them from Swift through the `Server` builder, or try them with
    `sws-bench serve --access-log`, `--metrics` or `--websocket-echo PATH`.

## Running

```bash
swift build -j 2
swift run SwiftWebServer --config Root/http-config.json      # Root/Public on http://127.0.0.1:8080/
scripts/run.sh                                                # the same, debug build
scripts/run.sh --port 9000                                    # flags are passed on
scripts/sigterm.sh                                            # graceful stop (PORT=9000 for another port)
```

```
SwiftWebServer [--config FILE] [--root DIR] [--host HOST] [--port PORT]
```

- `--config FILE`: the JSON config, described below. Without it, the server reads
  `$ROOT_PATH/http-config.json` when `ROOT_PATH` is set (the legacy launch), otherwise
  `./http-config.json` if that file exists, otherwise it uses the defaults.
- `--root DIR`, `--host HOST`, `--port PORT`: override the config. `--root` is relative to the
  working directory, and `--port 0` picks a free port.
- Once bound, the server prints `listening HOST:PORT` on stdout, then
  `listening HOST:PORT (https)` and `listening HOST:PORT (h3)` when those are configured.
- Exit status: 0 after a graceful stop, 1 on a configuration or startup error, 2 on a usage
  error.

For local HTTPS and HTTP/3, create the test identity and use the example config:

```bash
scripts/make-test-identity.sh            # .test-identity/server.p12 (gitignored), self-signed
swift run SwiftWebServer --config Root/http-config.tls.json
curl http://127.0.0.1:8080/
curl -k https://127.0.0.1:8443/                      # HTTP/2 via ALPN
curl -k --http1.1 https://127.0.0.1:8443/
/opt/homebrew/opt/curl/bin/curl --http3-only -k https://127.0.0.1:8443/
```

The default host is `127.0.0.1`, so the server is only reachable from this Mac. Set
`"host": "0.0.0.0"` (or `::`) to serve the network. macOS may then ask whether to accept
incoming connections.

## Configuration

`http-config.json` is a JSON object. **Every key is optional**: a missing key keeps its
default, so `{}` (or no file at all) is a valid configuration. Unknown keys print a warning
and are ignored. A value of the wrong type or out of range stops the server with exit status
1 and a message naming the key, such as `"timeouts.idle" must be a number of seconds`.
Relative paths resolve against the directory that holds the config file.

| Key | Default | Meaning |
|---|---|---|
| `host` | `"127.0.0.1"` | Numeric address to bind |
| `port` | `8080` | TCP port; `0` picks a free one |
| `root` | `"Public"` | Directory to serve (legacy alias: `path`) |
| `index` | `["index.html"]` | Index files tried, in order, for a directory; a single string is accepted (legacy alias: `defaultIndex`) |
| `mimeTypes` | `{}` | Extra or overriding types by extension, e.g. `{"md": "text/markdown; charset=utf-8"}`. The legacy array form `[{"contentType": …, "pathExtensions": […]}]` is accepted |
| `defaultMimeType` | `"application/octet-stream"` | `Content-Type` for unknown extensions |
| `blockList` | `["http-config.json", ".git", ".DS_Store"]` | Path components answered with `403` anywhere in the path, case-insensitively |
| `blockDotfiles` | `true` | Refuse every component that starts with `.` (except `.well-known`) |
| `caching` | `{"enabled": true, "maxAge": 3600}` | `Cache-Control: public, max-age=N` on files and `304`s; `false` or `"enabled": false` sends none |
| `maxConnections` | `1024` | Connections served at once; more wait in the listen backlog |
| `maxBodySize` | `10485760` | Largest request body in bytes; larger gets `413` (legacy alias: `maxRequestSize`) |
| `timeouts` | `{"header": 10, "idle": 5, "body": 30, "send": 30, "linger": 2}` | Seconds per HTTP/1.1 phase; `0` or `null` turns a limit off (legacy `keepAliveTimeout` sets `idle`) |
| `drainTimeout` | `10` | Seconds a graceful stop waits for open connections; `null` waits indefinitely |
| `transport` | `"bsd"` | `"bsd"` (POSIX sockets + kqueue) or `"nw"` (Network.framework) |
| `errorPages` | `true` | `true`: generated HTML pages; `false`: none; or files by status, e.g. `{"404": "Custom/404.html"}` (relative to `root`) |
| `tls` | off | HTTPS listener: `{"identity": "server.p12", "password": "…", "port": 8443}`. `identity` is a PKCS#12 file (relative to the config file), loaded in memory only. Use `"passwordEnv": "VAR"` instead of `password` to read it from an environment variable. `port` defaults to `8443`; `0` picks a free one |
| `http2` | on | HTTP/2 (#0119): `{"enabled": true, "cleartext": false, "maxConcurrentStreams": 100, "initialWindowSize": 65535, "maxRequestBodySize": 10485760, "abuseLimits": {…}}`; `true` is every default, `false` serves HTTP/1.1 only. With `tls`, the HTTPS listener offers `h2` and `http/1.1` via ALPN. `cleartext: true` also serves prior-knowledge h2c (`curl --http2-prior-knowledge http://…`) on the cleartext port; off by default, so cleartext connections go straight to HTTP/1.1 without protocol sniffing. `maxConcurrentStreams` is `0`–`65536`, `initialWindowSize` `0`–`2147483647` bytes per stream, `maxRequestBodySize` defaults to `maxBodySize`. An HTTP/2 connection with no stream for `timeouts.idle` is closed with GOAWAY. `abuseLimits` overrides the DoS limits of `docs/HTTP2.md`: `window` (seconds, 10), `maxResetStreamsPerWindow` (100), `maxControlFramesPerWindow` (1000), `maxEmptyFramesPerWindow` (100), `maxWindowUpdatesPerWindow` (10000), `maxSmallDataFramesPerWindow` (1000), `smallDataFrameSize` (256), `windowStallTimeout` (seconds, 30), `maxStreamsPerConnection` (100000); `null` turns one off |
| `http3` | off | HTTP/3 over QUIC; needs `tls`. `true`, or `{"enabled": true, "port": 8443, "altSvcMaxAge": 86400}`. `port` (UDP) defaults to the TLS port number, even when that was `0`. `altSvcMaxAge` is the `ma` of the `Alt-Svc` header on HTTPS responses |
| `hosts` | `[]` | Virtual hosts: `[{"names": ["a.test", "*.a.test"], "root": "sites/a"}, {"default": true, "root": "Public"}]`. Each site serves its own `root` (the other file keys are shared); `root` at the top level is then unused. Names match `Host`/`:authority` without the port, case-insensitively; `*.a.test` matches any subdomain. An unknown host gets the `default` site, or `421` without one |
| `auth` | `[]` | Authentication for path prefixes: `[{"paths": ["/admin"], "realm": "Admin", "basic": {"file": "users.htpasswd"}}]`. `basic` takes a credential file of `user:$pbkdf2-sha256$…` lines (make one with `scripts/hash-password.sh USER`), inline `"users"` lines, or `"usersEnv": "VAR"`; plaintext passwords are refused. `jwt` verifies HS256 bearer tokens: `{"keys": [{"id": "k1", "secretEnv": "JWT_KEY"}], "issuer": "…", "audience": "api", "leeway": 60}` (keys ≥ 32 bytes, `secret` inline or `secretEnv`; `exp` required unless `"requireExp": false`). `tokens` are static bearer tokens by SHA-256: `[{"name": "ci", "sha256": "…"}]`. Missing or wrong credentials get `401` with `WWW-Authenticate`; repeated failures from one address get `429` |
| `proxy` | `[]` | Reverse-proxy mounts (see [Reverse proxy](#reverse-proxy); WIP): `[{"path": "/api", "upstream": "http://127.0.0.1:9000"}]`. Each mount takes `path` (prefix starting with `/`, default `/`), optional `host`/`hosts`, `upstream` or `upstreams` (`http://HOST:PORT[/base]` or `unix:/path/to.sock`; https upstreams are not supported yet), `stripPrefix`, `preserveHost`, `forwardedHeaders` (`x-forwarded`, `forwarded`, `both`, `none`), `rewriteLocation`, `websocket`, `timeouts` `{"connect": 10, "response": 60, "idle": 60, "total": null}` in seconds (connect, request sent to response head, between body reads, whole exchange), `retries` (`1`: extra attempts on the next upstream after a connect failure, idempotent methods only), and `health` `{"failures": 3, "cooldown": 10, "path": null, "interval": 10}` (passive: down for `cooldown` seconds after `failures` consecutive failures; active: `GET path` every `interval` seconds, status < 500 is healthy). Several `upstreams` are used round-robin, skipping those that are down. The same `path` twice for the same hosts is an error |
| `accessLog` | | Reserved. The `AccessLog` component exists (#0090), but the config file does not wire it yet. The key is accepted with a warning and ignored; use the `Server` builder or `sws-bench serve --access-log` |
| `compression` | off | Response compression (#0091): `true`, or `{"encodings": ["br", "gzip", "deflate"], "minimumSize": 1024, "level": 4, "precompressionLevel": 9, "mimeTypes": ["text/*", "application/json", …], "precompress": true, "sidecars": true}`. Negotiates `Accept-Encoding` (q-values; `br` > `gzip` > `deflate` at equal weight) and adds `Vary: Accept-Encoding`. Small static files are compressed once into the file cache (`precompress`), `file.br`/`file.gz` next to a file are served as its variants (`sidecars`), and everything else of a listed type is compressed per response, streamed for large files. Encoded variants get a suffixed `ETag` (`"…-gz"`). Never applied to `206`, `304`, `HEAD`, already-encoded responses or bodies under `minimumSize`. The legacy `enableCompression: true` is the same as `true` |
| `enableETags` | | Legacy key with no effect: ETags are always sent. Accepted with a warning |

A config containing only `{"port": 0}` starts a server with every other default. The shipped
[`Root/http-config.json`](Root/http-config.json) spells out every default and adds custom
`404`/`405` pages.

Disabled features are left out of the request path entirely. The config is turned into a
middleware chain once at startup (`ServerSettings.makeHandler()` in `Sources/ConfigFile`), and
a component that is turned off is never registered.

### Reverse proxy

Requests under a `proxy` mount are forwarded to an upstream HTTP/1.1 app; everything else
falls through to the static files. The proxy sits after `auth`, so protected paths are
checked before anything is forwarded. [`Root/http-config.proxy.json`](Root/http-config.proxy.json)
serves `Root/Public` at `/` and proxies `/api` to the Go example app (it also enables TLS,
so it needs the test identity in `.test-identity/`). A minimal cleartext equivalent:

```json
{
  "port": 8080,
  "root": "Public",
  "proxy": [
    { "path": "/api", "upstream": "http://127.0.0.1:9000", "forwardedHeaders": "x-forwarded" }
  ]
}
```

```bash
(cd Examples/go-api && go run . -addr 127.0.0.1:9000) &
swift run SwiftWebServer --config Root/http-config.proxy.json
curl http://127.0.0.1:8080/api/health    # {"status":"ok"}
```

Upstream connections are pooled and `unix:` sockets work. A refused or failed connection or
a malformed response is a `502 Bad Gateway`, a timeout before the response head a `504
Gateway Timeout` (both rendered by `errorPages`); a failure after the head aborts the
response (close on HTTP/1.1, stream reset on HTTP/2 and HTTP/3). GET, HEAD, PUT, DELETE,
OPTIONS and TRACE are retried on the next upstream after a connect failure; POST and PATCH
never are. A client that goes away cancels the upstream request, and that connection is
closed rather than pooled. WebSocket and Upgrade requests are tunnelled (#0123); an explicit
`timeouts.idle` also closes an idle tunnel (default 300 seconds).

## Architecture

The design, the target layout and the milestone plan are in
[docs/ROADMAP.md](docs/ROADMAP.md). In brief:

- `Server` (HTTPServer) runs listeners from `NetworkTransport`: BSD sockets + kqueue for
  cleartext TCP, and Network.framework for TLS and QUIC.
- Each connection is handled by a protocol: `HTTP1`, `HTTP2` or `HTTP3`, chosen once per
  connection by ALPN or by reading the first bytes.
- Each protocol is a set of value-type state machines driven by one task per connection, with
  no actors on the request path.
- Requests pass through a middleware chain built with a result builder from optional components
  (see [docs/MIDDLEWARE.md](docs/MIDDLEWARE.md)).
- `ConfigFile` maps `http-config.json` onto all of these.

- Issues and their workflow: [issues/Issues.md](issues/Issues.md)
- Milestone status: [docs/PROGRESS.md](docs/PROGRESS.md)
- Benchmarks: [docs/benchmarks/](docs/benchmarks/README.md), including
  [M4-cutover.md](docs/benchmarks/M4-cutover.md) (this server against the original
  baseline)
- More docs and scripts: [docs/README.md](docs/README.md)

## Development

```bash
swift build -j 2
scripts/guarded.sh -t 900 -- swift test -j 2               # all tests
scripts/guarded.sh -t 600 -- swift test -j 2 --filter ParityTests
```

`ParityTests` (in `Tests/IntegrationTests`) launch the built `SwiftWebServer` on
`127.0.0.1:0` and check the behaviour of the original server and the repro steps of its
bugs (#0003–#0025). Agents working in this repository must follow [AGENTS.md](AGENTS.md).
