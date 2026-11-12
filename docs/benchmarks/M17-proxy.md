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
