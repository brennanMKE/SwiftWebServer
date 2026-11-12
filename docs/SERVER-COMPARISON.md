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
| **new server** | this repo, `sws-bench serve` | release build, HTTP/1.1 runner (#0080/#0081). In this run it answered from memory (`--body-size 626`); see [StaticFiles results](#staticfiles-results-0084) for the run that serves the file from disk |
| nginx | 1.31.8 | `worker_processes auto`, sendfile, `open_file_cache`, access log off |
| Apache httpd | 2.4.67, event MPM | default MPM settings, unlimited keep-alive requests, sendfile, no access log |
| Caddy | 2.11.1 | `file_server`, admin API off, no access log |
| lighttpd | 1.4.85 | defaults (single process, event loop), keep-alive requests 65535 |
| h2o | 2.2.6 | one thread per core |
| legacy SwiftWebServer | this repo, `Legacy` target (deleted in #0086) | release build; closes every connection |

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

- **Keep-alive: the new server is competitive.** It is within 4% of nginx at both concurrency levels, ahead of Apache and Caddy, and about 15–20% behind lighttpd and h2o. At 64 connections it has the tightest tail of any server measured: p99 1.44 ms, p99.9 2.37 ms. This run did not serve from disk; the [StaticFiles results](#staticfiles-results-0084) below do.
- **The bottleneck is not our code.** The server spends about 0.3 µs per request in its own code, with no allocations (`sws-bench h1conn`). The rest of the time goes to Network.framework receive and send, at about 6.6 µs and 15.6 µs per call (`docs/notes/nw-transport.md`), and to the load client sharing the same cores.
- **New connections are the clear weakness.** The new server accepts about 2,300 connections per second, roughly 10× fewer than nginx, with a 6 ms p50. Setting up each connection through Network.framework (`NWListener` → `NWConnection` → `start`) is expensive. The QUIC spike and #0078 saw the same cost. Tracked in #0113.
- **Against the legacy server:** about the same rate of new connections, but with far fewer errors and a much tighter p99.9 (25 ms against 386 ms). The legacy server cannot keep connections alive at all.

## Caveats

- The client runs on the same 12 cores as the server, so every server here is partly limited by `oha`. The ranking is more meaningful than the absolute numbers.
- One agent was building during the run (load average 9–15). Re-run on an idle machine before quoting numbers externally.
- All servers use their default concurrency model. nginx and Apache spread across processes, h2o uses threads, lighttpd is a single event loop, and the new server uses Swift Concurrency's cooperative pool.
- HTTP/2, HTTP/3, TLS, and large-file comparisons will be added as those milestones land.

## StaticFiles results (#0084)

Run of 2026-11-11, commit `2e512a7`. Raw results: [benchmarks/compare-servers-staticfiles.md](benchmarks/compare-servers-staticfiles.md). Re-run with:

```bash
scripts/guarded.sh -t 2400 -- scripts/bench-compare.sh 10 docs/benchmarks/compare-servers-staticfiles.md
```

The new server now serves the same 626-byte `index.html` from disk with `sws-bench serve --root` (StaticFiles #0084) over the BSD socket transport (#0113). Like nginx with `open_file_cache`, it keeps small files in memory with their headers rendered once (`Content-Type`, strong `ETag`, `Last-Modified`, `Accept-Ranges`) and re-checks each with `realpath` + `stat` at most once per second. A cache hit costs about 75 ns with no allocations (`sws-bench micro --filter StaticFiles`).

Load average 4.7 at the start; other agents started building during the closed-connection rows (27.6 at the end).

| Server | keep-alive, 16 conns | keep-alive, 64 conns | new connection per request, 16 |
|---|---:|---:|---:|
| lighttpd | **107,091** | **115,349** | 12,411 |
| **new server** | 89,439 | 90,236 | 8,464 |
| nginx | 79,804 | 74,377 | **19,385** |
| h2o | 71,811 | 87,367 | 10,324 |
| Apache | 53,313 | 49,191 | 5,452 |
| Caddy | 42,140 | 42,907 | 3,854 |
| legacy SwiftWebServer | – | – | 1,156 |

(req/s; latency columns are in the raw file.)

- **Serving from disk costs nothing measurable.** Keep-alive throughput went from 63k to 89k req/s against the earlier in-memory run. Most of that gain is probably the BSD socket transport (#0113), not StaticFiles (not measured separately). The new server is second only to lighttpd and 12–21% ahead of nginx. nginx still has the tighter p99 at 16 connections (0.27 ms against 0.61 ms). At 64 connections the new server's p99 of 1.07 ms beats nginx's 1.47 ms.
- **New connections:** about 8,500 per second, 3.7× the Network.framework listener's 2,300, but under the load that rose during these rows. nginx still leads. Repeat on an idle machine before ranking.
- **Large files:** `BSDSocketTransport.sendFile` now uses `sendfile(2)`. Serving a page-cached 512 MiB file to curl over loopback took 9.0 GB/s (median of 5) against 5.8 GB/s with the bounded `pread` loop on the same transport and 2.3 GB/s on Network.framework, with about 35% less server CPU than the `pread` loop. Measured at load average about 17, so treat these as relative figures. A 1 GiB download keeps server RSS flat at 8 MiB (`StaticFilesIntegrationTests`).

## Latest run: end of day, 2026-11-11 (commit b6fc9a6)

The new server serves the file from disk through StaticFiles on the default BSD socket transport. No agents were building, and the load average was 6–7. Raw output is in [benchmarks/compare-servers-final.md](benchmarks/compare-servers-final.md).

| Server | Keep-alive, 16 conns | Keep-alive, 64 conns | p99 at 64 conns |
|---|---:|---:|---:|
| lighttpd | **103,737** | **122,251** | 0.98 ms |
| **new server** | 93,132 | 97,265 | 0.99 ms |
| h2o | 87,251 | 87,459 | 0.85 ms |
| nginx | 81,572 | 81,023 | 1.03 ms |
| Apache | 52,247 | 55,318 | 12.3 ms |
| Caddy | 37,605 | 45,487 | 7.2 ms |

- With kept-alive connections the new server is second only to lighttpd: it beats nginx by 14–20% and h2o by 7–11%.
- Closed-connection rows in the raw file have thousands of client-side errors (loopback ephemeral ports run out), so they are not used for ranking here. The dedicated accept benchmark (`scripts/bench-accept.sh`, #0113) measured the new server at about 21.9k new connections/s against nginx's 18.0k.
- HTTP/2 (h2load, `-c 16 -m 10`, in-memory body): 374,655 req/s against nginx h2c's 135,367 req/s (`benchmarks/M13-h2.md`). h2spec passes 146/146.
