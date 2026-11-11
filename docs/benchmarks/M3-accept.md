# M3 follow-up: new-connection throughput (#0113)

`docs/SERVER-COMPARISON.md` measured 2,266 req/s for the new server with a new connection
per request, against 21,344 for nginx. Keep-alive throughput was on par. This record measures
where the per-connection time goes, what was tried, and the result: an optional
`BSDSocketTransport` (POSIX sockets + kqueue, cleartext TCP only). It is now the default
transport of `sws-bench serve`.

- Date: 2026-11-11, 14:48–15:33 PST
- Branch: `m03-accept-perf` (base `main` `e158f56`)
- Not a gating record: the orchestrator runs gating benchmarks at milestone end. Other work
  was using the machine throughout (see the load average on each table). nginx was measured
  in the same runs, interleaved, as a same-conditions reference.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| Memory | 64 GB |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |
| Load tool | oha 1.16.0; nginx 1.31.8 (`worker_processes auto`, as in `bench-compare.sh`) |
| Ephemeral ports | 49152–65535 (16,384), `net.inet.tcp.msl` 15000 (30 s `TIME_WAIT`) |

## Method

**External (`scripts/bench-accept.sh`).** The script starts one `sws-bench serve
--body-size 626` per variant (`--transport nw`, `--transport bsd`) and nginx, all on
127.0.0.1. Each round runs `oha --disable-keepalive -n 10000 -c 16` against each server in
turn, then the keep-alive case `oha -z 5s -c 16`. 10,000 connections fit within the 16,384
ephemeral ports. The script waits for `TIME_WAIT` sockets to drain (fewer than 500) between
closed-connection runs, so no run is distorted by port exhaustion. With this setup every run
had 0 errors. The duration-based runs in `SERVER-COMPARISON.md` had thousands. The
keep-alive "errors" are requests cut off at the 5 s deadline.

```bash
scripts/guarded.sh -t 1500 -- scripts/bench-accept.sh 3 10000 16 nw="--transport nw" bsd="--transport bsd"
```

**In process (`sws-bench accept`).** This runs the full stack (`Server` + HTTP/1.1 + the
626-byte `HelloHandler`) over the chosen transport. The client is 16 threads with blocking BSD
sockets: each connects, sends a `Connection: close` request, reads to EOF, and closes with
`SO_LINGER` 0, so no `TIME_WAIT` builds up. Each connection gets a timeline on
`CLOCK_UPTIME_RAW`, matched by the client's port. Allocations are counted process-wide
(server, client, Network.framework) through the `malloc_logger` hook, divided by the number of
connections. There are 3 rounds of 5,000 connections and the median round is reported.

```bash
scripts/guarded.sh -t 200 -- .build/release/sws-bench accept --transport nw|bsd --connections 5000 --rounds 3
```

**Profiling.** `sample <pid>` on the `accept` process (no Instruments, no dtrace), `heap
<pid>` for live object counts, and `/usr/bin/time -l` for CPU time.

## Before: where the time goes with Network.framework

`sws-bench accept --transport nw`, load average 9.8 (1 min):

| Phase | p50 µs | p90 µs | p99 µs |
|---|---:|---:|---:|
| connect (kernel handshake, client side) | 628 | 721 | 780 |
| `connect` returns → NW `newConnectionHandler` | 1,986 | 3,498 | 4,550 |
| handover → `.ready` | 2,037 | 3,412 | 4,410 |
| ready → accept loop takes it | 3.1 | 3.8 | 7.8 |
| taken → first `receive` returns the request | 729 | 1,047 | 1,474 |
| first read → client sees first response byte | 341 | 552 | 642 |
| total | 5,774 | 7,075 | 9,256 |

- 2,652 connections/s for the median round. Rounds were 4,308, then 2,652, then 1,576: **the
  rate falls with every round.**
- **409 allocations per connection** and about **665 µs of CPU per connection** (20,000
  connections: 8.65 s user + 4.64 s sys over 12.5 s). Only about 1.06 cores were busy: the
  work is serialized.
- `sample`: 86% of samples are on Network.framework's **process-wide serial queue
  `com.apple.network.connections`**. Our per-connection queues (`sws.tcp.connection`) appear in
  2 of 1,552 samples, and our accept queue and task-group code is not visible. The hot path
  is `nw_listener_inbox_socket_handle_new_socket` → `nw_context_copy_registered_endpoint`
  → `nw_hash_table_get_node` → `nw_endpoint_is_equal`, plus `nw_path_evaluator_start` and
  `necp_client_action`.
- `heap`: after about 10,600 connections the process holds 10,586 `NWConcrete_nw_association`
  objects, each with a path evaluator, parameters, endpoints and a `deactivation_timer`. Our
  side holds about 24 live `TCPTransport`/`nw_connection` objects (the ones in flight), so
  nothing of ours leaks. NW keeps one association per **distinct remote endpoint** for about
  60 s after the connection closes; the count dropped all at once after about 60 s idle. The
  endpoint lookup slows as that table grows, which is why every round is slower than the last.
  Under sustained load from many client ports, the accept rate settles low.

### Network.framework fixes tried

Each variant ran in a fresh process: 3 back-to-back rounds of 4,000 connections, two
interleaved repetitions, at load 25–30. The results are noisy, but no variant changed the shape.

| Variant | Rounds (connections/s), rep 1 | Rep 2 | Allocations |
|---|---|---|---:|
| baseline | 4128, 1898, 1440 | 1628, 1251, 939 | 410 |
| own `NWParameters.PrivacyContext` | 4606, 2470, 1189 | 2045, 1753, 978 | 409 |
| + `disableLogging()` | 3863, 2322, 1196 | 1981, 1421, 906 | 409 |
| + `flushCache()` every 500 accepts | 2128, 1133, 1327 | 3100, 1908, 1114 | 410 |
| shared pool of 8 serial queues | 3761, 2467, 1881 | 2881, 2051, 1250 | 407 |

- **Queue pool:** no effect. The cost is not in our queues; all NW work runs on NW's own
  serial queue.
- **Privacy context, logging off, cache flush:** no effect on the decay. The associations are
  not part of the flushable cache.
- **`newConnectionLimit`:** not tried. The cost is inside NW's own accept handling, before the
  hand-over that the limit gates, so limiting hand-overs is not expected to shorten it.
- **Receive before `.ready`, fewer continuation hops:** our hops are not where the time goes.
  The accept loop takes a ready connection in 3 µs. The first receive takes 0.7–1 ms only
  because it waits on the same saturated NW queue.
- **TCP options:** `TCP_NODELAY` was already on. TCP Fast Open needs client support (oha does
  not use it) and would not touch the server-side cost.

The temporary experiment switches were removed. The only change kept in the NW adapter is the
`@_spi(Benchmark) acceptTimestamps` instrumentation, which costs two clock reads per
connection.

## After: `BSDSocketTransport`

`BSDSocketListener` + `BSDSocketTransport` (`Sources/NetworkTransport/BSD*.swift`):
non-blocking sockets, with system calls made directly on the calling task. A one-shot kqueue
wait (two process-wide loop threads) is armed only on `EAGAIN`. Accept and receive happen
only on demand, nothing is read ahead, and `send` returns when the kernel has accepted every
byte. The accept backlog lives in the kernel (`listen` backlog). The shared transport tests
run against both adapters.

`sws-bench accept --transport bsd`, same session as the NW table above (load average 9.2):

| Phase | p50 µs | p90 µs | p99 µs |
|---|---:|---:|---:|
| connect (kernel handshake, client side) | 260 | 312 | 376 |
| `connect` returns → `accept(2)` returns it | 80 | 114 | 149 |
| accepted → ready | 0 | 0 | 0 |
| ready → accept loop takes it | 1.2 | 2.1 | 4.7 |
| taken → first `receive` returns the request | 13.2 | 24.7 | 56.1 |
| first read → client sees first response byte | 122 | 157 | 207 |
| total | 484 | 601 | 667 |

- **31,313 connections/s** for the median round. Rounds were 34,748, 31,313 and 27,283, with
  no decay (an earlier session: 25,458 / 25,369 / 24,837 and 25,987 / 29,964 / 31,462).
- **24.1 allocations per connection** (NW: 409), process-wide, including the server task,
  HTTP/1.1 buffers and the transport objects.
- The first read drops from 729 µs to 13 µs: the request has usually arrived by the time the
  connection is taken, so `read` returns it at once with no hop.

## External results (oha, 16 concurrent)

Run 2 (load average 10.24 / 38.65 / 39.25 before, 10.88 / 23.36 / 31.80 after; a build had just
finished):

| Server | Mode | Round 1 req/s | Round 2 | Round 3 | Median req/s | Median-round p50 ms | p99 ms |
|---|---|---:|---:|---:|---:|---:|---:|
| new server, NW (before) | close | 2,672 | 2,536 | 753 | 2,536 | 5.493 | 25.198 |
| new server, BSD (after) | close | 21,684 | 21,932 | 21,921 | **21,921** | 0.683 | 1.614 |
| nginx | close | 23,489 | 15,770 | 18,027 | 18,027 | 0.868 | 1.891 |
| new server, NW | keep-alive | 57,949 | 60,611 | 61,852 | 60,611 | 0.255 | 0.570 |
| new server, BSD | keep-alive | 72,190 | 77,665 | 76,930 | **76,930** | 0.197 | 0.573 |
| nginx | keep-alive | 67,464 | 68,518 | 58,632 | 67,464 | 0.231 | 0.387 |

Run 1 (load average 25.59 / 16.63 / 18.78 before, 43.64 / 34.63 / 27.02 after; another agent
was building):

| Server | Mode | Round 1 req/s | Round 2 | Round 3 | Median |
|---|---|---:|---:|---:|---:|
| new server, NW | close | 2,824 | 1,863 | 2,508 | 2,508 |
| new server, BSD | close | 21,117 | 18,974 | 20,512 | 20,512 |
| nginx | close | 21,296 | 23,679 | 24,141 | 23,679 |
| new server, NW | keep-alive (1 run) | 27,871 | | | |
| new server, BSD | keep-alive (1 run) | 64,730 | | | |
| nginx | keep-alive (1 run) | 26,028 | | | |

The baseline before any change (`main`, default serve, load 61 → 18): new server 1,087 /
1,281 / 1,938 against nginx 18,607 / 17,654 / 19,026 req/s.

### Comparison

| Case | Before (NW) | After (BSD) | Change | nginx, same run |
|---|---:|---:|---:|---:|
| New connection per request, median req/s | 2,536 | 21,921 | +764% (8.6×) | 18,027 |
| New connection, p50 latency | 5.49 ms | 0.68 ms | −88% | 0.87 ms |
| Keep-alive, median req/s | 60,611 | 76,930 | +27% | 67,464 |
| Keep-alive, p50 latency | 0.255 ms | 0.197 ms | −23% | 0.231 ms |
| Allocations per new connection (in process) | 409 | 24.1 | −94% | |

**Target met:** with a new connection per request the new server is within 2× of nginx (run 2:
21,921 req/s against nginx's 18,027, so 1.22× nginx's rate; run 1: 20,512 against 23,679, 0.87×), and about level with the 21k req/s that `SERVER-COMPARISON.md`
recorded for nginx.

## Decision: BSD sockets are the default for cleartext TCP

`sws-bench serve` now defaults to `--transport bsd`, and `--transport nw` (or `"transport":
"nw"` in the config file) selects Network.framework. The task set the bar as winning clearly
in both modes, and BSD does:

- New connections: 8.6× NW, at or above nginx, with no decay over time (NW gets slower with
  every distinct client endpoint seen in the last minute).
- Keep-alive: +27% over NW in the same run, with a lower p50 and the same p99. Each `receive`
  and `send` is one system call on the calling task instead of a block hop through NW's
  serial queue.

What stays on Network.framework: **TLS and QUIC** (TLS through Network.framework parameters,
`QUICListener`), and every outbound client in `LoadClient`. `TCPListener` /
`TCPTransport` stay in the package, are still tested by the same suite, and remain selectable.

## Caveats

- Client and server share the 12 cores, so oha's own cost limits every row. nginx's
  closed-connection numbers swing between 15.8k and 24.1k from run to run.
- The machine was not idle. Load averages are listed with each table. The orchestrator's
  milestone-end idle run should replace these numbers.
- The in-process client resets connections (`SO_LINGER` 0) to avoid `TIME_WAIT`. The external
  runs use oha's normal close.
- `BSDSocketTransport` keeps the default `sendFile` (a bounded `pread` loop). A `sendfile(2)`
  override is a follow-up for StaticFiles (#0084).
