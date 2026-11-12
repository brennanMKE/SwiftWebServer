# M6: VirtualHosts (#0092) and Auth (#0093)

What the per-request work of the two components costs, and whether it allocates.

- Date: 2026-11-11, 18:18 PST
- Branch: `m06-vhosts-auth` (from `main` `2823cdd`)
- Load average (1, 5, 15 min): 2.76 4.44 13.59 before and after the VirtualHosts runs (other
  agents active). Not a gating record.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |
| Command | `sws-bench micro --filter VirtualHosts` and `--filter Auth`, 3 runs each |

## VirtualHosts lookup

The set is 61 sites: `site0.example.com` … `site49.example.com` (each with a `www.` alias),
ten wildcard sites `*.tenant0.example.net` …, and a default. One op is one
`VirtualHosts.route(request)` on a prebuilt request carrying a `Host` field: finding the field,
stripping the port, hashing and probing. That is everything the component does before calling
the matched host's chain (one closure call).

Median ns per op over three runs (min of the three medians in brackets).

| Case | `Host` | ns/op | allocs/op |
|---|---|---|---|
| exact name | `site42.example.com` | 33.5 (33.3) | 0.00 |
| exact, with port, mixed case | `WWW.Site42.Example.com:8443` | 40.0 (39.0) | 0.00 |
| wildcard | `acme.tenant7.example.net` | 40.8 (40.8) | 0.00 |
| unknown, default host answers | `unknown.example.org` | 26.8 (26.3) | 0.00 |

- No allocation and no `String` on hits, misses and wildcards. The names are compiled once into
  two open-addressing tables (exact names, wildcard suffixes) keyed by an FNV-1a hash of the
  lowercased bytes taken right to left, so one leftward pass yields the hash of the whole name
  and of every dot-suffix; a suffix probe happens only at dots and only when wildcards exist.
- The cost grows with the host's length (one hash step per byte, one lowercased compare per byte
  on a hit), not with the number of sites.
- `recordsHost: true` (off by default) adds one small allocation per request: setting
  `MatchedVirtualHost` in the `RequestContext` (see #0094's note on typed values).

## Auth

Recorded 18:34 PST, load average 3.78 3.52 6.73 before and 4.20 3.61 6.75 after; command
`sws-bench micro --filter Auth`, 3 runs.

The authenticator has two policies (`/api` and `/admin`) accepting Basic, HS256 JWTs and one
static token. One op is everything it does for one request before calling `next`: the policy
lookup by path (`Authenticator.policy(for:)`) and, for a covered path,
`Authenticator.authenticate` (header lookup, failure-limiter check, scheme parse,
verification, building the `Principal`). The JWT is a typical one: header
`{"alg":"HS256","typ":"JWT","kid":"k1"}`, claims `sub`, `iss`, `aud`, `iat`, `exp` (about 224 bytes
encoded).

| Case | ns/op | allocs/op |
|---|---|---|
| path outside every policy (pass-through) | 38.5 (35.6) | 0.00 |
| covered path, no `Authorization` (`401`) | 35.5 (34.2) | 0.00 |
| `Bearer` JWT HS256, through the authenticator | 835 (791) | 0.00 |
| `JWTVerifier.verify` alone | 757 (741) | 0.00 |
| `Bearer` static token (SHA-256 + constant-time compare) | 218 (209) | 0.00 |
| `Basic`, verified-value cache hit (keyed HMAC of the header) | 343 (309) | 0.00 |
| `Basic`, PBKDF2 at 1,000 iterations, no cache | 142,800 (135,900) | 0.00 |

- JWT verification: base64url decoding into stack buffers, a byte-level JSON scan of header
  and claims (no `String` except `sub`, which is small-string inline here), one HMAC-SHA256 and
  a constant-time compare. About two thirds of the time is the HMAC itself.
- The first version used CryptoKit's `HMAC<SHA256>` and `SHA256.hash`: JWT 1,600 ns with 9
  allocations, static token 360 ns with 2, the Basic cache hit 1,160 ns with 8. CommonCrypto's
  one-shot `CCHmac`/`CC_SHA256` (also a system library, no keychain) allocate nothing, so the
  request path uses them.
- The first scope check copied each `AuthPolicy` (a struct of ten references) while looping:
  127 ns for a pass-through. The prefixes now live in one flat `ScopeTable`: 36-40 ns.
- PBKDF2 is slow by design and scales linearly with iterations: the 600,000-iteration default
  costs about 85 ms of CPU per uncached Basic verification (extrapolated). The verified-value
  cache (256 slots, 5-minute lifetime, keyed with a per-process random HMAC key) makes repeat
  requests with the same header cost one HMAC, and the failure limiter caps how often one peer
  can make the server run PBKDF2 with wrong passwords.

## Unregistered

Both components are middlewares in their own targets. A server that does not put them in its
builder chain does not compile them into the request path (docs/MIDDLEWARE.md), and neither
issue changes code in `HTTPCore`, `HTTP1`, `HTTP2`, `HTTP3` or `HTTPServer`, so the
unregistered cost is unchanged by construction. The executable registers `VirtualHosts` only
when the config has `hosts` (it then replaces the single `StaticFiles`, via an `EitherHandler`
whose branch is one predictable switch). `h1conn` was not rerun for this record (other agents
were building).
