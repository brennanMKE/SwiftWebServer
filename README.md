# SwiftWebServer

A static-file web server written in Swift 6 with Swift Concurrency, with no package
dependencies. It runs on **macOS 15 or later only**. It uses Darwin and Network.framework
APIs and is not built or tested on Linux.

The shipped `SwiftWebServer` executable serves **HTTP/1.1** over cleartext TCP and, when
configured, over **TLS**, plus **HTTP/3** over QUIC, all at once from one config. The package
also holds the HTTP/2 and WebSocket work in progress (see [ROADMAP](docs/ROADMAP.md)), which is
not part of the executable yet.

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
| `accessLog` | | Reserved for a component still in progress (#0090). It is accepted with a warning and ignored |
| `compression` | off | Response compression (#0091): `true`, or `{"encodings": ["br", "gzip", "deflate"], "minimumSize": 1024, "level": 4, "precompressionLevel": 9, "mimeTypes": ["text/*", "application/json", …], "precompress": true, "sidecars": true}`. Negotiates `Accept-Encoding` (q-values; `br` > `gzip` > `deflate` at equal weight) and adds `Vary: Accept-Encoding`. Small static files are compressed once into the file cache (`precompress`), `file.br`/`file.gz` next to a file are served as its variants (`sidecars`), and everything else of a listed type is compressed per response, streamed for large files. Encoded variants get a suffixed `ETag` (`"…-gz"`). Never applied to `206`, `304`, `HEAD`, already-encoded responses or bodies under `minimumSize`. The legacy `enableCompression: true` is the same as `true` |
| `enableETags` | | Legacy key with no effect: ETags are always sent. Accepted with a warning |

A config containing only `{"port": 0}` starts a server with every other default. The shipped
[`Root/http-config.json`](Root/http-config.json) spells out every default and adds custom
`404`/`405` pages.

Disabled features are left out of the request path entirely. The config is turned into a
middleware chain once at startup (`ServerSettings.makeHandler()` in `Sources/ConfigFile`), and
a component that is turned off is never registered.

## Architecture

The design, the target layout and the milestone plan are in
[docs/ROADMAP.md](docs/ROADMAP.md). In brief, `Server` (HTTPServer) runs listeners from
`NetworkTransport` and connection protocols such as `HTTP1`. Requests pass through a
middleware chain built with a result builder from components such as `StaticFiles` and
`ErrorPages` (see [docs/MIDDLEWARE.md](docs/MIDDLEWARE.md)). `ConfigFile` maps
`http-config.json` onto all of these.

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
