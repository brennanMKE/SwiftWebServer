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
| Command | `sws-bench micro --filter VirtualHosts`, 3 runs |

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

## Unregistered

Both components are middlewares in their own targets. A server that does not put them in its
builder chain does not compile them into the request path (docs/MIDDLEWARE.md), and neither
issue changes code in `HTTPCore`, `HTTP1`, `HTTP2`, `HTTP3` or `HTTPServer`, so the
unregistered cost is unchanged by construction. The executable registers `VirtualHosts` only
when the config has `hosts` (it then replaces the single `StaticFiles`, via an `EitherHandler`
whose branch is one predictable switch). `h1conn` was not rerun for this record (other agents
were building).
