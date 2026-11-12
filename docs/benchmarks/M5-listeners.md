# M5: cleartext, HTTPS and HTTP/3 from one process (#0089, #0103)

A quick keep-alive throughput check of the shipped `SwiftWebServer` serving all three
listeners from one config: cleartext HTTP/1.1 (BSD sockets), HTTP/1.1 over TLS
(Network.framework, TLS 1.3) and HTTP/3 over QUIC on the TLS port number (UDP). The response
is `Root/Public/index.html` (626 bytes) through `ErrorPages` + `StaticFiles`, and, since
`http3` is on, the `Alt-Svc` middleware (it adds the header on HTTPS responses).

- Date: 2026-11-11, 17:00 PST
- Branch: `m05-listeners` (base `main` `6a3bceb`)
- Not a gating record. Other agents shared the machine (load average 6.7–11, see each row);
  no build ran during the runs.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| Memory | 64 GB |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product SwiftWebServer` |
| Clients | oha 1.16.0; Homebrew curl 8.23.0 (ngtcp2 1.26.0, nghttp3 1.19.0) |

## Method

One server process, started with a scratch config:

```json
{"port": 0, "root": "<repo>/Root/Public",
 "tls": {"identity": "<repo>/.test-identity/server.p12", "password": "sws-test-password", "port": 0},
 "http3": {"enabled": true}, "drainTimeout": 2}
```

Two clients, because neither covers everything here:

- **oha** (cleartext and HTTPS): `oha -z 1s -c 16` warm-up, then `oha -z 5s -c 16`
  (`--insecure` for HTTPS). This oha build has no HTTP/3 ("has not been built with HTTP/3
  support"), and `h2load --h3` fails every request at once on this Mac (0 started), so:
- **curl `--parallel`** (HTTPS and HTTP/3): one Homebrew curl process fetches
  `index.html?[1-20000]` with `--parallel --parallel-max 16 -sk -o /dev/null`, timed from
  start to exit, after a 500-request warm-up. With `--http3-only` the 16 in-flight requests are
  streams of one QUIC connection; with `--http1.1` they use up to 16 TLS keep-alive
  connections. Every response was `200`.

Scripts in the session scratchpad drove both, under `scripts/guarded.sh`; the server stopped
with SIGTERM and exit 0 after each run.

## Results

oha, 16 connections, 5 s:

| Round | Listener | Load (1 min) | req/s | p50 | p99 |
|---|---|---|---|---|---|
| 1 | HTTP/1.1 cleartext (BSD) | 8.89 | 92,766 | 0.165 ms | 0.346 ms |
| 1 | HTTP/1.1 over TLS (NW) | 8.74 | 44,061 | 0.365 ms | 0.432 ms |
| 2 | HTTP/1.1 cleartext (BSD) | 10.76 | 92,832 | 0.165 ms | 0.595 ms |
| 2 | HTTP/1.1 over TLS (NW) | 9.98 | 42,988 | 0.385 ms | 0.433 ms |

curl `--parallel`, 20,000 requests, 16 in flight:

| Round | Protocol | Load (1 min) | Time | req/s |
|---|---|---|---|---|
| 1 | HTTP/3 (one QUIC connection) | 7.04 | 2.33 s | 8,579 |
| 1 | HTTP/1.1 over TLS | 6.79 | 0.62 s | 32,096 |
| 2 | HTTP/3 (one QUIC connection) | 6.79 | 2.32 s | 8,612 |
| 2 | HTTP/1.1 over TLS | 6.79 | 0.62 s | 32,518 |
| 3 | HTTP/3 (one QUIC connection) | 6.79 | 2.41 s | 8,299 |
| 3 | HTTP/1.1 over TLS | 6.73 | 0.62 s | 32,335 |

Medians: HTTP/3 **8,579 req/s**; HTTPS (curl) 32,335 req/s; HTTPS (oha) about 43,500 req/s;
cleartext (oha) about 92,800 req/s. The spread between rounds is under 4% for every row.

## Reading the numbers

- **HTTPS matches the M5 TLS record.** `M5-tls.md` measured 44,642 req/s for HTTPS over NW
  with `sws-bench serve --tls` and its in-memory hello handler; the shipped binary with
  `StaticFiles`, `ErrorPages` and `Alt-Svc` gets 43,000–44,000 req/s at a similar load. The
  cleartext BSD listener in the same process is unaffected (about 92,800 req/s against 94,000
  in `M5-tls.md`).
- **HTTP/3 is about 3.8× slower than HTTPS from the same curl** (8,600 against 32,300 req/s).
  The client is part of that: curl's HTTP/3 is one QUIC connection driven by one thread, while
  its HTTP/1.1 run spreads over 16 TCP connections. The ROADMAP's measured NW per-stream cost
  (about 590 allocations and 0.4–0.8 ms of setup per stream, `docs/spikes/quic-spike.md`) is
  the other part: every request opens a new QUIC stream. Proper HTTP/3 load numbers (several
  connections, a client that is not the bottleneck) are #0105 (M10).
- curl's own ceiling is visible on the HTTPS row too: oha drives the same listener about 35%
  faster than curl `--parallel`.
