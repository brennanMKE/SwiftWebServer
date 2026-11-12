# Running on a Mac

## Build

```bash
swift build -c release -j 2 --product SwiftWebServer     # or scripts/build.sh
.build/release/SwiftWebServer --help
```

Requirements: macOS 15 or later and a Swift 6.4 toolchain (Xcode or swift.org). The binary has
no dependencies outside the system, so you can copy `.build/release/SwiftWebServer` anywhere,
e.g. `/usr/local/bin` or `~/bin`.

## Command line

```
SwiftWebServer [--config FILE] [--root DIR] [--host HOST] [--port PORT]
```

| Flag | Meaning |
|---|---|
| `--config FILE` | The JSON config. Without it: `$ROOT_PATH/http-config.json` when `ROOT_PATH` is set, else `./http-config.json` if it exists, else built-in defaults |
| `--root DIR` | Directory to serve; overrides `root`. Relative to the working directory |
| `--host HOST` | Numeric address to bind; overrides `host` |
| `--port PORT` | Cleartext port; overrides `port`. `0` picks a free one |
| `--help`, `-h` | Usage |

`--flag=value` works too. Output:

- stderr: `SwiftWebServer: serving /abs/root` (or one line per virtual host), config warnings,
  `signal 15, shutting down`, `stopped`, and errors.
- stdout: `listening 127.0.0.1:8080` once bound, then `listening 127.0.0.1:8443 (https)` and
  `listening 127.0.0.1:8443 (h3)` for the other listeners. Scripts can wait for the first line.
  The access log also goes to stdout when configured that way.

Exit status: `0` after a graceful stop, `1` on a configuration or startup error (bad value,
missing root, unreadable identity, port in use) with a message naming the key, `2` on a usage
error.

## `http-config.json` reference

The file is one JSON object. **Every key is optional**: a missing key keeps its default, so
`{}` (or no file) is a valid config serving `./Public` on `127.0.0.1:8080`. Unknown keys print
a warning and are ignored. A wrong type or out-of-range value stops the server (exit 1) with a
message such as `"timeouts.idle" must be a number of seconds`. **Relative paths resolve
against the directory holding the config file** (except `--root`).

Durations are numbers of seconds (fractions allowed). For the HTTP/1.1 `timeouts`, `0` or
`null` turns a limit off.

[`Root/http-config.json`](../../Root/http-config.json) spells out the core defaults;
[`Root/http-config.tls.json`](../../Root/http-config.tls.json) adds HTTPS and HTTP/3;
[`Root/http-config.proxy.json`](../../Root/http-config.proxy.json) adds a reverse-proxy mount.

### Listening and limits

| Key | Type | Default | Meaning |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | Numeric address to bind. `"0.0.0.0"` (IPv4) or `"::"` serves the network |
| `port` | integer 0–65535 | `8080` | Cleartext TCP port; `0` picks one |
| `transport` | `"bsd"` \| `"nw"` | `"bsd"` | Cleartext transport: POSIX sockets + kqueue, or Network.framework |
| `maxConnections` | integer ≥ 1 | `1024` | Connections served at once across all listeners; more wait in the listen backlog |
| `maxBodySize` | integer bytes | `10485760` | Largest request body (`413` above). Legacy alias `maxRequestSize` |
| `timeouts` | object | see below | HTTP/1.1 time limits in seconds |
| `timeouts.header` | seconds | `10` | Request head must complete (`408`) |
| `timeouts.idle` | seconds | `5` | Idle keep-alive connection closed; also an idle HTTP/2 connection (`GOAWAY`). Legacy `keepAliveTimeout` |
| `timeouts.body` | seconds | `30` | Longest wait for request body bytes (`408`) |
| `timeouts.send` | seconds | `30` | Longest wait for the client to accept response bytes |
| `timeouts.linger` | seconds | `2` | Lingering close after an error response |
| `drainTimeout` | seconds or `null` | `10` | Graceful stop waits this long for open connections; `null` waits indefinitely (`0` cancels at once) |

### Files

| Key | Type | Default | Meaning |
|---|---|---|---|
| `root` | string | `"Public"` | Directory to serve. Legacy alias `path` |
| `index` | string or array | `["index.html"]` | Index files tried in order for a directory. Legacy alias `defaultIndex` |
| `mimeTypes` | object | `{}` | Extra or overriding types: `{"md": "text/markdown; charset=utf-8"}`. The legacy array form `[{"contentType": …, "pathExtensions": […]}]` is accepted |
| `defaultMimeType` | string | `"application/octet-stream"` | For unknown extensions |
| `blockList` | array of strings | `["http-config.json", ".git", ".DS_Store"]` | Path components answered `403` anywhere in the path, case-insensitively |
| `blockDotfiles` | bool | `true` | `403` for any component starting with `.`, except `.well-known` |
| `caching` | bool or object | `{"enabled": true, "maxAge": 3600}` | `Cache-Control: public, max-age=N` on files and `304`s; `false` or `"enabled": false` sends none |
| `errorPages` | bool or object | `true` | `true`: generated HTML pages for bodiless `4xx`/`5xx`; `false`: none; `{"404": "errors/404.html"}`: files relative to `root` (other statuses keep the generated page) |
| `compression` | bool or object | off | See [Compression](#compression) |
| `enableETags` | – | – | Legacy, no effect (ETags are always sent); accepted with a warning |
| `enableCompression` | bool | – | Legacy; `true` is `"compression": true` (ignored when `compression` is set) |

### Compression

`"compression": true` uses every default, or an object:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | `false` turns it off |
| `encodings` | array | `["br", "gzip", "deflate"]` | Codings offered, from `br`, `gzip`, `deflate` |
| `minimumSize` | integer bytes | `1024` | Smaller bodies are sent as they are |
| `level` | integer 1–9 | `4` | zlib level for per-response gzip/deflate |
| `precompressionLevel` | integer 1–9 | `9` | Level for static-file variants compressed once into the cache |
| `mimeTypes` | array | `text/*`, JSON, JavaScript, XML (incl. SVG), wasm, YAML, TOML, some fonts and icons | Types that are compressed; `*` wildcards allowed |
| `precompress` | bool | `true` | Compress small static files once into the file cache |
| `sidecars` | bool | `true` | Serve `file.br` / `file.gz` next to a file as its variants |

### TLS, HTTP/2 and HTTP/3

| Key | Type | Default | Meaning |
|---|---|---|---|
| `tls` | object, `false` or `null` | off | HTTPS listener |
| `tls.identity` | string (required) | – | PKCS#12 file (certificate chain + key), relative to the config file. Loaded in memory only |
| `tls.password` | string | – | Its password; or |
| `tls.passwordEnv` | string | – | Name of an environment variable holding the password (exactly one of the two) |
| `tls.port` | integer | `8443` | TCP port; must differ from `port`; `0` picks one |
| `tls.enabled` | bool | `true` | `false` turns it off |
| `http2` | bool or object | on | HTTP/2. On by default (offered on HTTPS via ALPN); `false` or `"enabled": false` serves HTTP/1.1 only |
| `http2.cleartext` | bool | `false` | Also accept h2c with prior knowledge on the cleartext port (every cleartext connection is then sniffed) |
| `http2.maxConcurrentStreams` | integer 0–65536 | `100` | `SETTINGS_MAX_CONCURRENT_STREAMS` |
| `http2.initialWindowSize` | integer 0–2147483647 | `65535` | Per-stream receive window |
| `http2.maxRequestBodySize` | integer or `null` | `maxBodySize` | Largest request body on HTTP/2 |
| `http2.abuseLimits` | object | defaults | DoS limits (counts per `window`; `null` turns one off): `window` (s, 10), `maxResetStreamsPerWindow` (100), `maxControlFramesPerWindow` (1000), `maxEmptyFramesPerWindow` (100), `maxWindowUpdatesPerWindow` (10000), `maxSmallDataFramesPerWindow` (1000), `smallDataFrameSize` (256), `windowStallTimeout` (s, 30), `maxStreamsPerConnection` (100000). Background: [HTTP2.md](../HTTP2.md) |
| `http3` | bool or object | off | HTTP/3 over QUIC; **needs `tls`**. `true` = defaults |
| `http3.port` | integer or `null` | TLS port number | UDP port (the same number as HTTPS is normal: TCP and UDP do not clash) |
| `http3.altSvcMaxAge` | integer seconds | `86400` | `ma` of the `Alt-Svc` header on HTTPS responses |
| `http3.qpackMaxTableCapacity` | integer 0–1048576 | `0` | QPACK dynamic table offered to clients; `0` = static table only |
| `http3.qpackBlockedStreams` | integer 0–1000 | `0` | Streams that may wait on QPACK inserts |
| `http3.enabled` | bool | `true` | `false` turns it off |

### Virtual hosts, auth, proxy and logs

These have their own sections:

| Key | Default | Reference |
|---|---|---|
| `hosts` | `[]` | [Virtual hosts](static-sites.md#virtual-hosts) |
| `auth` | `[]` | [Authentication](static-sites.md#authentication) |
| `proxy` | `[]` | [Reverse proxy reference](dynamic-sites.md#proxy-mount-reference) |
| `accessLog` | off | [Logs](#logs) below |

## HTTPS with a PKCS#12 identity

The server loads a PKCS#12 (`.p12`) file holding the certificate chain and private key, in
memory only (`SecPKCS12Import` with `kSecImportToMemoryOnly`). It never touches the keychain,
so nothing prompts and nothing is installed.

```json
{
  "host": "0.0.0.0",
  "port": 80,
  "root": "/Users/me/Sites/example",
  "tls": { "identity": "certs/example.p12", "passwordEnv": "SWS_P12_PASSWORD", "port": 443 },
  "http3": true
}
```

### Local testing

```bash
scripts/make-test-identity.sh            # .test-identity/server.p12, self-signed for localhost
.build/release/SwiftWebServer --config Root/http-config.tls.json
curl -k https://127.0.0.1:8443/                      # HTTP/2 via ALPN
curl -k --http1.1 https://127.0.0.1:8443/
/opt/homebrew/opt/curl/bin/curl --http3-only -k https://127.0.0.1:8443/   # Homebrew curl has HTTP/3
```

Browsers reject a self-signed certificate unless you trust it, which changes the keychain's
trust settings; do that by hand only if you want to, or test with curl.

### A real certificate (Let's Encrypt)

Any ACME client that writes PEM files works, for example [lego](https://go-acme.github.io/lego/),
[acme.sh](https://github.com/acmesh-official/acme.sh) or certbot (all installable with
Homebrew). The HTTP-01 challenge needs the domain to reach this Mac on port 80, and
StaticFiles serves `/.well-known/` even with `blockDotfiles` on, so you can use webroot mode
with your site's `root`:

```bash
# Example with lego, webroot mode, while SwiftWebServer serves the site on port 80
lego --email you@example.com --domains example.com --domains www.example.com \
     --http --http.webroot /Users/me/Sites/example run
# certificates land in ./.lego/certificates/example.com.crt (full chain) and .key
```

Convert to PKCS#12. Use the legacy-compatible algorithms: `SecPKCS12Import` does not reliably
accept OpenSSL 3's default AES/PBKDF2 encryption (this is what `scripts/make-test-identity.sh`
does too):

```bash
export SWS_P12_PASSWORD='a long random password'
openssl pkcs12 -export \
  -inkey example.com.key -in example.com.crt \
  -out certs/example.p12 -passout env:SWS_P12_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
chmod 600 certs/example.p12
```

`-in` must be the full chain (leaf first, then intermediates). Use Homebrew's
`/opt/homebrew/bin/openssl` if `/usr/bin/openssl` (LibreSSL) rejects an option.

The identity is read once at startup. After a renewal, regenerate the `.p12` and **restart**
the server (see [reload](#shutdown-restart-and-reload)); ACME clients have a renew hook for
that, e.g. `launchctl kickstart -k gui/$(id -u)/com.example.swiftwebserver`.

## Binding to all interfaces and the firewall prompt

The default `host` is `127.0.0.1`: only this Mac can connect. To serve your network or the
internet, set `"host": "0.0.0.0"` (all IPv4 interfaces) or `"::"`.

With the macOS application firewall on (System Settings → Network → Firewall), the first time
an **unsigned or newly built** binary listens on a non-loopback address macOS asks "Do you want
the application "SwiftWebServer" to accept incoming network connections?". Each rebuild changes
the binary, so the prompt can come back. Options:

- Click Allow once per build (fine on a desktop; it blocks an unattended start under launchd
  until someone clicks).
- Install one stable copy (e.g. `/usr/local/bin/SwiftWebServer`), and allow it once; sign it
  with your own Developer ID (`codesign -s "Developer ID Application: …"`) so the approval
  survives updates.
- Allow it ahead of time from an admin shell:
  `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/local/bin/SwiftWebServer`
  and `--unblockapp` the same path.

Loopback (`127.0.0.1`, `::1`) never prompts, which is why every example and test here binds
loopback. A server reached only through a local reverse proxy or a tunnel (Tailscale, Cloudflare
Tunnel) can stay on loopback or bind only the tunnel's address.

HTTP/3 needs the UDP port open as well as TCP, in any firewall or router in front of the Mac.

## Ports 80 and 443 without root

Since macOS 10.14 (Mojave), a non-root process may bind ports below 1024 on the **wildcard**
address, so `"host": "0.0.0.0"` (or `"::"`) with `"port": 80` and `"tls": {"port": 443}` works
as a normal user. Binding a *specific* address below 1024 can still fail with `EACCES`
("Permission denied"); bind the wildcard instead. Do not run the server as root.

## Running as a LaunchAgent

A user LaunchAgent starts the server at login and restarts it if it exits. Save as
`~/Library/LaunchAgents/com.example.swiftwebserver.plist` (adjust paths):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.swiftwebserver</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/SwiftWebServer</string>
    <string>--config</string>
    <string>/Users/me/Sites/example/http-config.json</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/Users/me/Sites/example</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SWS_P12_PASSWORD</key>
    <string>…</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ExitTimeOut</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>/Users/me/Library/Logs/SwiftWebServer/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/me/Library/Logs/SwiftWebServer/stderr.log</string>
</dict>
</plist>
```

```bash
mkdir -p ~/Library/Logs/SwiftWebServer
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.swiftwebserver.plist
launchctl kickstart -k gui/$(id -u)/com.example.swiftwebserver    # restart
launchctl bootout gui/$(id -u)/com.example.swiftwebserver         # stop and unload
```

- `KeepAlive` with `SuccessfulExit = false` restarts the server after a crash or a startup
  error, but not after a clean stop (exit 0).
- launchd stops a job with SIGTERM and kills it after `ExitTimeOut` seconds (default 20).
  Keep `drainTimeout` (default 10) below it so the drain finishes.
- A LaunchAgent runs only while you are logged in. For a server that runs without a login, a
  LaunchDaemon in `/Library/LaunchDaemons` (needs admin) with `UserName` set to an unprivileged
  account does the same job.
- Keep the site and config **outside** `~/Desktop`, `~/Documents` and `~/Downloads`: those are
  privacy-protected, and a launchd job reading them is denied or triggers a permission prompt.
- The `EnvironmentVariables` password is readable by anyone who can read the plist; keep it
  `chmod 600`, or point `passwordEnv` at a variable you set another way.

## Logs

- **Startup and errors** go to stderr; **`listening` lines** to stdout.
- **Access log**: the `accessLog` key.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `accessLog` | bool, string or object | off | `true`: Common lines to stdout. A string: the `path`. `false`/`null`: off |
| `accessLog.path` | string or `null` | `"stdout"` | A file (relative to the config file; appended to, created `0644`; its directory must exist), `"stdout"` or `"stderr"`. `null` writes no lines (metrics only) |
| `accessLog.format` | `"common"` \| `"combined"` \| `"json"` | `"common"` | Combined adds `Referer` and `User-Agent`; JSON lines include the duration |
| `accessLog.metrics` | bool or path | off | Serve Prometheus metrics at this path (`true` = `/metrics`) |
| `accessLog.flushInterval` | seconds > 0 | `1` | Longest a line waits in its buffer |
| `accessLog.enabled` | bool | `true` | `false` turns it off |

The access log is outermost in the chain, so it records the final status of every response
(error pages, auth rejections, proxied responses). Lines are buffered per connection and
written by a background task; if the writer falls behind, lines are dropped (counted), never
delayed. A graceful stop writes everything buffered. The server does not rotate files; use
`newsyslog` (`/etc/newsyslog.d/`, admin) or restart after moving the file. `metrics` is served
to anyone who can reach the server; protect it with `auth` if that matters.

## Shutdown, restart and reload

- **SIGINT and SIGTERM** start a graceful shutdown: listeners stop accepting, HTTP/2 and HTTP/3
  connections get `GOAWAY`, WebSocket tunnels get Close 1001, in-flight requests finish for up
  to `drainTimeout` seconds, then the rest are cancelled; the access log flushes and the
  process exits 0. A second signal during the drain is harmless. `scripts/sigterm.sh` sends
  SIGTERM to whatever listens on `PORT` (default 8080).
- **There is no live reload.** The config file, TLS identity and auth credential files are
  read once at startup. To apply changes, restart (`launchctl kickstart -k …`). SIGHUP is not
  handled, so it terminates the process immediately (its default action) without a drain; use
  SIGTERM.
- Static file *contents* need no restart: cached entries are re-checked with `stat` at most
  once per second.

## A public server checklist

- Release build, installed at a stable path; firewall decision made for that path.
- `"host": "0.0.0.0"`, `port` 80, `tls.port` 443, `http3` on (UDP 443 open).
- `passwordEnv` rather than an inline `password`; `.p12` mode `0600`.
- `accessLog` to a file, rotated; `metrics` behind `auth` or off.
- `maxConnections`, `maxBodySize` and `timeouts` sized for your traffic; the defaults are
  conservative.
- LaunchAgent (or LaunchDaemon) with `ExitTimeOut` above `drainTimeout`; renewal hook restarts.
- More for proxied apps: [production checklist](dynamic-sites.md#production-checklist).
