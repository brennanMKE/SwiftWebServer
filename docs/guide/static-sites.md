# Static websites

A static site needs only the executable and a directory:

```bash
.build/release/SwiftWebServer --root ~/Sites/example --port 8080
```

or a config file next to the site:

```json
{
  "root": "public",
  "compression": true,
  "caching": { "maxAge": 600 },
  "errorPages": { "404": "errors/404.html" },
  "accessLog": { "path": "logs/access.log", "format": "combined" }
}
```

Every key is in the [config reference](running-on-a-mac.md#http-configjson-reference). This
page explains what the static components do.

## StaticFiles

- **Paths.** The request path is percent-decoded once (only when it contains `%`). NUL, `\`,
  an encoded `/` or a bad escape answers `400`; a `..` component answers `403`. The decoded
  path is canonicalized with `realpath`; a symlink whose target leaves the root answers `403`
  (`SymlinkPolicy.followWithinRoot`, the default; `.deny` and `.followAnywhere` are available
  from Swift).
- **Blocked names.** Components in `blockList` and, with `blockDotfiles`, any component
  starting with `.` answer `403`, case-insensitively, in the requested and the resolved path.
  `.well-known` is always allowed (ACME challenges, `security.txt`).
- **Directories.** A directory without a trailing `/` gets `301` to add it; with one, the
  first existing `index` file is served. There are no directory listings.
- **Methods.** `GET` and `HEAD`. Anything else gets `405` with `Allow: GET, HEAD` (when
  StaticFiles is the terminal handler; in the middle of a chain it passes other methods on).
- **Types.** A built-in extension table, then `mimeTypes` overrides, else `defaultMimeType`.
- **Serving.** Files up to 64 KiB are read once into an in-memory cache with their headers
  pre-rendered (up to 1024 entries); larger files are sent from an open descriptor with
  `sendfile(2)` and never read into memory (a 1 GiB download keeps the server at about 8 MiB).
  Cached entries are re-checked with `realpath` + `stat` at most once a second, so edits show
  up within a second without a restart.

## Caching and conditional requests

- Every file response carries a strong `ETag` built from size, modification time and inode
  (no content hashing), `Last-Modified`, `Accept-Ranges: bytes`, and, with `caching`,
  `Cache-Control: public, max-age=N` (default 3600 from the config file).
- Conditional requests are evaluated in RFC 9110 order: `If-Match`, `If-Unmodified-Since`,
  `If-None-Match` (lists and `*`), `If-Modified-Since`, then `If-Range`. A match answers `304`
  (with `ETag`, `Last-Modified`, `Cache-Control`, no body); a failed `If-Match` or
  `If-Unmodified-Since` answers `412`. Dates compare in whole seconds.
- Deploying with a tool that preserves modification times (`rsync -a`) keeps ETags stable;
  one that rewrites every file changes them all (clients then re-download once).

```bash
curl -sI http://127.0.0.1:8080/ | grep -i etag                     # ETag: "a9c-…"
curl -sI -H 'If-None-Match: "a9c-…"' http://127.0.0.1:8080/         # HTTP/1.1 304
```

## Range requests

A single `Range: bytes=…` answers `206 Partial Content` with `Content-Range`; an
unsatisfiable range answers `416`. Several ranges in one request are ignored (full `200`).
`If-Range` with a validator that no longer matches serves the whole file. This is what video
seeking and resumed downloads need.

```bash
curl -s -r 0-99 -o part http://127.0.0.1:8080/video.mp4 -w '%{http_code}\n'    # 206
```

## Error pages

`errorPages` gives bodiless `4xx`/`5xx` responses an HTML body: a small generated page by
default (`<h1>404 Not Found</h1>`), or your own files:

```json
{ "errorPages": { "404": "errors/404.html", "500": "errors/500.html" } }
```

- Paths are relative to `root` and must stay inside it; they are read once at startup (a
  missing file stops startup with a message naming `errorPages.404`).
- Statuses without a file keep the generated page; `"errorPages": false` sends empty bodies.
- `HEAD` responses, `304`, and responses that already have a body (an upstream app's own
  error JSON, for example) are never touched. The status and fields (such as `Allow` on `405`)
  are kept.
- Error pages sit outside auth and the proxy, so a `401`, `502` or `504` gets a page too.
- With `hosts`, each site looks for the file in its own root first, then in the top-level
  `root`, so every site can have its own `errors/404.html` and share the rest. A file in
  neither stops startup. The top-level `root` need not exist when the sites have the files;
  a response no site answers (`421` for an unknown host) uses the top-level file if there is
  one, else the generated page.

## Compression

`"compression": true` turns on Brotli, gzip and deflate, negotiated from `Accept-Encoding`
(q-values; `br` > `gzip` > `deflate` at equal weight), with `Vary: Accept-Encoding`.

- **Static files are compressed once.** Small files of a compressible type and at least
  `minimumSize` bytes get `br` and `gzip` variants built when they enter the file cache, at
  `precompressionLevel` (9). A request then costs no compression.
- **Sidecars.** `style.css.br` and `style.css.gz` next to `style.css` (and at least as new)
  are served as its variants, at any size. Generate them at deploy time with
  `brotli -k` / `gzip -k -9`.
- **Everything else** of a listed type (large files without sidecars, error pages, proxied
  responses) is compressed per response at `level` (4), streamed in chunks for large bodies.
- Never compressed: bodies under `minimumSize` (1024 bytes), `206`, `304`, `HEAD`, responses
  that already have `Content-Encoding`, and types outside `mimeTypes` (images, video, archives
  and `woff2` are already compressed).
- Each variant has its own strong `ETag` (`"…-br"`, `"…-gz"`), so caches and conditional
  requests stay correct.

## Virtual hosts

Several sites on one listener, chosen by `Host` (HTTP/1.1) or `:authority` (HTTP/2, HTTP/3):

```json
{
  "hosts": [
    { "names": ["example.com", "www.example.com"], "root": "sites/example" },
    { "names": ["*.blog.example.com", "blog.example.com"], "root": "sites/blog",
      "proxy": [{ "path": "/api", "upstream": "http://127.0.0.1:9000" }] },
    { "default": true, "root": "sites/fallback" }
  ]
}
```

| Key | Type | Meaning |
|---|---|---|
| `hosts[].names` | array of strings | Host names, matched without the port, case-insensitively. `*.a.test` matches any subdomain of `a.test` (not `a.test` itself) |
| `hosts[].name` | string | One name (alternative to `names`) |
| `hosts[].root` | string (required) | The site's directory, relative to the config file |
| `hosts[].default` | bool | This site answers unknown hosts and requests without a host. At most one |
| `hosts[].proxy` | array | Proxy mounts for this site only, tried before the top-level `proxy` mounts |

- A request for an unknown host goes to the `default` site, or gets `421 Misdirected Request`
  without one.
- With `hosts`, the top-level `root` is not served and need not exist; the other file keys
  (`index`, `mimeTypes`, `blockList`, `caching`, `compression`, `errorPages`) apply to every
  site. `errorPages` files resolve per site (see [Error pages](#error-pages)).
- With TLS, all names are served with the one identity in `tls.identity`, so use a certificate
  that covers every name (SAN or wildcard). There is no per-host certificate (SNI) selection.

## Authentication

`auth` protects path prefixes with HTTP Basic, JWT bearer tokens or static bearer tokens:

```json
{
  "auth": [
    { "paths": ["/admin"], "realm": "Admin", "basic": { "file": "users.htpasswd" } },
    { "paths": ["/api/private"], "realm": "API",
      "jwt": { "keys": [{ "id": "k1", "secretEnv": "JWT_KEY" }], "issuer": "https://id.example.com", "audience": "api" },
      "tokens": [{ "name": "ci", "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }] }
  ]
}
```

| Key | Type | Meaning |
|---|---|---|
| `paths` | string or array | Path prefixes starting with `/`. The first area covering a path decides |
| `realm` | string | Shown in the `WWW-Authenticate` challenge |
| `basic` | string or object | A credential file name, or `{"file", "users", "usersEnv"}`: lines `user:$pbkdf2-sha256$…` from a file, inline, or an environment variable. Plaintext passwords are refused |
| `jwt.keys` | array | `{"id"?, "secret" \| "secretEnv"}`; HS256 secrets of at least 32 bytes |
| `jwt.issuer`, `jwt.audience` | string; string or array | Required `iss` / `aud` when set |
| `jwt.leeway` | integer 0–3600 | Clock skew allowed, seconds |
| `jwt.requireExp` | bool | Default `true`: tokens need `exp` |
| `tokens` | array | Static bearer tokens as `{"name", "sha256"}` (hex SHA-256 of the token; the token itself is never stored) |

An area needs at least one of `basic`, `jwt` or `tokens`.

Make a Basic credential line (PBKDF2-SHA256, 600,000 iterations by default):

```bash
scripts/hash-password.sh alice >> users.htpasswd      # prompts for the password
```

Make a token digest: `printf %s "$TOKEN" | shasum -a 256`.

Behaviour: missing or wrong credentials get `401` with one challenge per accepted scheme;
passwords are compared in constant time; a client address with 10 failures within 60 seconds
gets `429` with `Retry-After` before any hashing; requests outside every area pass after one
prefix check. Credentials are never logged. Basic sends the password with every request, so
use it only over HTTPS. Auth runs before the proxy, so it also protects proxied paths; the
upstream receives the `Authorization` header unchanged.
