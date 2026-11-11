# Server comparison

How the new SwiftWebServer stack compares with established HTTP servers on the same hardware. The raw results are in [benchmarks/compare-servers.md](benchmarks/compare-servers.md). Re-run with:

```bash
scripts/guarded.sh -t 2400 -- scripts/bench-compare.sh 10 docs/benchmarks/compare-servers.md
```

Run of 2026-11-11, commit `6bd196a` (end of M3.2: HTTP/1.1 keep-alive, pipelining, request bodies).

## Setup

| | |
|---|---|
| Machine | Apple M4 Pro, 12 cores, macOS (load average 9–15 during the run: one agent was building) |
| Client | `oha` 1.16.0 on the same machine, so client and server compete for cores |
| Network | loopback (127.0.0.1) only |
| Payload | `GET /index.html`, 626-byte HTML body |
| Duration | 10 s per run, servers measured one at a time |

| Server | Version | Configuration |
|---|---|---|
| **new server** | this repo, `sws-bench serve` | release build, HTTP/1.1 runner (#0080/#0081). Answers from memory until StaticFiles (#0084) lands |
| nginx | 1.31.8 | `worker_processes auto`, sendfile, `open_file_cache`, access log off |
| Apache httpd | 2.4.67, event MPM | default MPM settings, unlimited keep-alive requests, sendfile, no access log |
| Caddy | 2.11.1 | `file_server`, admin API off, no access log |
| lighttpd | 1.4.85 | defaults (single process, event loop), keep-alive requests 65535 |
| h2o | 2.2.6 | one thread per core |
| legacy SwiftWebServer | this repo, `Legacy` target | release build; closes every connection |

## Results

### Keep-alive, 16 connections

| Server | req/s | p50 ms | p99 ms | p99.9 ms |
|---|---:|---:|---:|---:|
| lighttpd | **75,909** | **0.188** | 0.621 | 1.682 |
| h2o | 72,606 | 0.209 | **0.404** | 0.749 |
| nginx | 65,615 | 0.233 | 0.422 | **0.732** |
| **new server** | 63,416 | 0.244 | 0.624 | 0.779 |
| Apache | 43,003 | 0.310 | 1.596 | 6.400 |
| Caddy | 34,997 | 0.345 | 2.347 | 9.361 |

### Keep-alive, 64 connections

| Server | req/s | p50 ms | p99 ms | p99.9 ms |
|---|---:|---:|---:|---:|
| lighttpd | **79,312** | 0.763 | 1.985 | 4.154 |
| h2o | 71,837 | 0.854 | 2.413 | 20.751 |
| nginx | 64,604 | 0.981 | 1.903 | 6.624 |
| **new server** | 61,685 | 1.039 | **1.438** | **2.374** |
| Apache | 46,199 | **0.410** | 23.091 | 60.004 |
| Caddy | 37,351 | 1.207 | 10.511 | 21.160 |

### New connection per request, 16 concurrent

| Server | req/s | p50 ms | p99 ms | errors |
|---|---:|---:|---:|---:|
| nginx | **21,344** | **0.589** | 3.064 | 15 |
| lighttpd | 10,845 | 0.685 | **1.349** | 3,138 |
| h2o | 9,498 | 0.907 | 1.777 | 2,361 |
| Apache | 7,384 | 0.822 | 3.763 | 2,808 |
| Caddy | 5,329 | 0.819 | 7.118 | 3,523 |
| legacy SwiftWebServer | 2,518 | 6.785 | 18.451 | 8,818 |
| **new server** | 2,266 | 6.394 | 14.634 | 16 |

**The closed-connection numbers are not reliable for ranking.** Each run opens tens of thousands of connections on loopback, which exhausts the client's ephemeral ports (sockets wait in TIME_WAIT). The thousands of errors on most rows are mostly the client failing to connect, not server failures. The ~15 errors on the keep-alive rows are requests cut off at the 10-second deadline.

## Takeaways

- **Keep-alive: the new server is competitive.** It is within 4% of nginx at both concurrency levels, ahead of Apache and Caddy, and about 15–20% behind lighttpd and h2o. At 64 connections it has the tightest tail of any server measured: p99 1.44 ms, p99.9 2.37 ms. At this point it is not serving from disk, so the comparison will be repeated after StaticFiles (#0084).
- **The bottleneck is not our code.** The server spends about 0.3 µs per request in its own code, with no allocations (`sws-bench h1conn`). The rest of the time goes to Network.framework receive and send, at about 6.6 µs and 15.6 µs per call (`docs/notes/nw-transport.md`), and to the load client sharing the same cores.
- **New connections are the clear weakness.** The new server accepts about 2,300 connections per second, roughly 10× fewer than nginx, with a 6 ms p50. Setting up each connection through Network.framework (`NWListener` → `NWConnection` → `start`) is expensive. The QUIC spike and #0078 saw the same cost. Tracked in #0113.
- **Against the legacy server:** about the same rate of new connections, but with far fewer errors and a much tighter p99.9 (25 ms against 386 ms). The legacy server cannot keep connections alive at all.

## Caveats

- The client runs on the same 12 cores as the server, so every server here is partly limited by `oha`. The ranking is more meaningful than the absolute numbers.
- One agent was building during the run (load average 9–15). Re-run on an idle machine before quoting numbers externally.
- All servers use their default concurrency model. nginx and Apache spread across processes, h2o uses threads, lighttpd is a single event loop, and the new server uses Swift Concurrency's cooperative pool.
- HTTP/2, HTTP/3, TLS, and large-file comparisons will be added as those milestones land.
