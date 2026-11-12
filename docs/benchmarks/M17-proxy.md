# M17: reverse proxy cost per request (#0120, #0121)

What the reverse proxy adds to a request over a warm keep-alive upstream pool, and the CPU
work of its per-request steps. Indicative only: these ran on the owner's workstation with
other agents building.

- Date: 2026-11-12, 13:35 PST
- Branch: `m17-0120-0121` (on `main` `c0716a6`)
- Load average (1, 5, 15 min): 2.78 3.63 4.02 (micro and first `proxy` run), 3.64 3.75 4.03
  (second and third `proxy` runs). Not a gating record.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |
| Commands | `sws-bench micro --filter Proxy`; `sws-bench proxy` (20,000 requests, three runs) |

## Per-request steps (`micro --filter Proxy`)

| Step | median ns | allocs/op |
|---|---:|---:|
| `writeHead`: request head with 6 fields into a reused buffer | 189 | 0 |
| `parseHead`: response head with 5 fields | 667 | 4 |
| mount lookup, miss (a static-file request passing through) | 36 | 0 |
| mount lookup, hit | 29 | 0 |
| `makeUpstreamRequest` (path, query, header rewrite, forwarded fields) | 846 | 7 |

The request head is written from the request's bytes (field names by their resolved ID, no
lowercasing or string building); the response head is parsed in place (allocations are the
returned fields' storage). Mount matching runs on the raw path bytes when the path is
already normalized (no `%`, dot segments or non-ASCII); other paths take the decoding slow
path, so `/%61pi` and `/x/../api` still match like `/api`.

## Round trip over a warm pool (`sws-bench proxy`)

One kept-alive connection to an in-process upstream on 127.0.0.1 that answers every request
with a 5-byte body; requests one after another (two loopback socket round trips each).
Allocations are process-wide, the upstream's included.

| Row | run 1 ns | run 2 ns | run 3 ns | allocs |
|---|---:|---:|---:|---:|
| raw (hand-written client) | 25,665 | 23,465 | 24,485 | 0 |
| `UpstreamHTTP1Client`, default timeouts | 36,293 | 42,814 | 36,043 | 27 |
| `UpstreamHTTP1Client`, timeouts off | 28,468 | 26,989 | 27,672 | 10 |
| `ReverseProxy.handle` + body, default timeouts | 43,762 | 41,451 | 42,389 | 45 |
| `ReverseProxy.handle` + body, timeouts off | 29,791 | 31,503 | 31,867 | 28 |

Added by the proxy (`proxy - raw`): about 18 µs per request with the default timeouts and
4-8 µs with them off. The difference is the per-read timeout: each wait for the response
head (and each body read that has to wait) races the receive against a sleep in a task
group, which costs about 17 allocations and 8-10 µs per request. Follow-up: a deadline on the
kqueue wait itself (an `EVFILT_TIMER` armed with the read) would remove it.

## Proxied hello world vs Apache mod_proxy and nginx (#0124)

Keep-alive HTTP/1.1 throughput and latency through each reverse proxy to the same upstream,
compared with hitting the upstream directly. Run with `scripts/bench-proxy.sh 5 1 16 64`.

- Date: 2026-11-12, 14:08 PST, branch `m17-0124` (`f85416b`)
- Upstream: `sws-bench serve` (built-in hello handler, 14-byte body), release build
- SwiftWebServer: release `SwiftWebServer --config`, one mount `{"path": "/", "upstream": …,
  "pool": {"maxIdle": 512}}`, default timeouts (so each upstream read races a timer, see above)
- Apache 2.4.67 (`/usr/sbin/httpd`, event MPM, `ServerLimit 16`, `ThreadsPerChild 64`),
  `ProxyPass / http://127.0.0.1:UP/ keepalive=On` plus `ProxyPassReverse`
- nginx 1.31.8, `worker_processes auto`, `proxy_pass http://app` with `upstream app { keepalive 512; }`,
  `proxy_http_version 1.1`, `Connection ""`, X-Forwarded-For/Proto set
- Client: oha 1.16.0, 1 s warm-up then 5 s per row, servers measured one at a time, all on
  127.0.0.1. Errors exclude the requests oha cancels at the deadline.
- Load: the owner's Rust build had pushed the 1-minute load to 20–60 minutes before; this run
  started at 7.9 and ended at 10.2 (per-row values below). Indicative, not gating.

| target | c | req/s | p50 ms | p99 ms | errors | upstream TIME_WAIT | load before | load after |
|---|---:|---:|---:|---:|---:|---:|---|---|
| direct | 1 | 24,908 | 0.037 | 0.075 | 0 | 5 | 7.53 20.11 21.14 | 7.17 19.82 21.03 |
| sws | 1 | 11,585 | 0.084 | 0.159 | 0 | 6 | 7.17 19.82 21.03 | 6.75 19.53 20.92 |
| apache | 1 | 11,134 | 0.086 | 0.176 | 0 | 8 | 6.75 19.53 20.92 | 6.45 19.25 20.82 |
| nginx | 1 | 15,033 | 0.057 | 0.166 | 0 | 8 | 6.17 18.98 20.71 | 5.92 18.72 20.61 |
| direct | 16 | 74,731 | 0.200 | 0.519 | 0 | 13 | 5.92 18.72 20.61 | 6.81 18.69 20.59 |
| sws | 16 | 31,045 | 0.468 | 1.054 | 0 | 10 | 6.81 18.69 20.59 | 6.82 18.49 20.51 |
| apache | 16 | 34,498 | 0.447 | 0.714 | 0 | 10 | 6.82 18.49 20.51 | 6.92 18.32 20.43 |
| nginx | 16 | 40,707 | 0.373 | 0.725 | 0 | 17 | 6.92 18.32 20.43 | 7.96 18.35 20.43 |
| direct | 64 | 81,406 | 0.754 | 1.158 | 0 | 28 | 7.81 18.14 20.35 | 8.14 18.04 20.30 |
| sws | 64 | 33,864 | 1.824 | 2.586 | 0 | 38 | 8.14 18.04 20.30 | 10.21 18.30 20.38 |
| apache | 64 | 38,496 | 1.604 | 2.129 | 0 | 56 | 10.21 18.30 20.38 | 10.11 18.15 20.31 |
| nginx | 64 | 37,066 | 1.742 | 2.155 | 0 | 57 | 10.11 18.15 20.31 | 10.51 18.10 20.28 |

Added latency over direct (p50 / p99, ms):

| c | SwiftWebServer | Apache | nginx |
|---:|---:|---:|---:|
| 1 | +0.047 / +0.084 | +0.049 / +0.101 | +0.020 / +0.091 |
| 16 | +0.268 / +0.535 | +0.247 / +0.195 | +0.173 / +0.206 |
| 64 | +1.070 / +1.428 | +0.850 / +0.971 | +0.988 / +0.997 |

- One connection at a time, the SwiftWebServer proxy matches Apache (11.6k vs 11.1k req/s, the
  same +0.05 ms p50) and trails nginx (15.0k). Each proxied request is two loopback round trips,
  so every proxy roughly halves the direct rate.
- Under concurrency SwiftWebServer is 10–20% behind Apache and nginx (31k vs 34.5k/40.7k at 16,
  33.9k vs 38.5k/37.1k at 64) with a p99 about 0.4–0.5 ms higher. The known per-request cost is
  the timeout race on each upstream read (about 17 allocations and 8–10 µs, see the round-trip
  table above); a kqueue-armed deadline is the follow-up.
- No errors and no connection churn in any row (TIME_WAIT counts stay at the warm-up level).
  An earlier run found that `pool.maxIdle` above 16 was silently capped by the client, so at 64
  connections the proxy closed most upstream connections after one exchange, ran the loopback
  port range out (16k ports, 30 s TIME_WAIT) and answered 502; fixed in `f85416b`. With the
  default `maxIdle` (16), more than 16 concurrent proxied requests still open and close extra
  connections: raise `pool.maxIdle` to the expected concurrency, as with nginx's `keepalive`.
