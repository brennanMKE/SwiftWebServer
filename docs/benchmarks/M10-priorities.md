# M10 — RFC 9218 priorities (#0065 HTTP/2, #0107 HTTP/3)

Two concurrent downloads on one HTTP/2 connection, the low-priority one requested first
(stream 1 `/low`, stream 3 `/high`, sent in one write). h2load cannot set `priority`, so the
client is the in-memory test client: `Tests/HTTP2Tests/H2PriorityBenchmarkTests.swift`.

The client reads like a browser: SETTINGS_INITIAL_WINDOW_SIZE of 1 GiB per stream, and the
connection window (65,535 bytes at start) returned every 32 KiB it consumes, so the connection
window is the contended resource and the server's fair queue (#0054) decides which stream's
DATA goes next.

```bash
SWS_PRIORITY_BENCH_MB=16 scripts/guarded.sh -t 300 -- swift test -j 2 --filter H2PriorityBenchmarkTests
```

## Setup

- Apple M4 Pro (Mac16,11), debug build (`swift test`), in-memory transport, no TLS.
- Load average while running: 6.19 / 7.09 / 7.94 before, 5.81 / 6.96 / 7.87 after (other
  agents were building). Absolute times are noisy; the completion order is the result.
- 16 MiB per download, three runs.

## Results

| Scenario | First done | Second done | Other stream's bytes when the first finished |
|---|---|---|---|
| `/low` `u=7`, `/high` `u=0` | `/high` at 76.5 / 73.9 / 84.4 ms | `/low` at 132.3 / 126.4 / 144.0 ms | 1,631 / 1,711 / 1,391 KiB of 16,384 |
| no `priority` field (both `u=3`, not incremental) | `/low` at 69.3 / 63.1 / 71.6 ms | `/high` at 126.6 / 109.7 / 140.2 ms | 1,343 / 1,135 / 1,023 KiB |
| both `priority: i` (`u=3`, incremental) | either, at 126.2 / 108.5 / 127.0 ms | the other, < 1.5 ms later | 16,303 / 16,367 / 16,047 KiB |

- **Urgency wins.** Requested second, the `u=0` download finishes first, in about half the
  total time; the `u=7` one finishes when both would have.
- **Non-incremental at one urgency is first come, first served.** Without a field (the
  RFC default `u=3`, not incremental) stream 1 goes first, one response at a time.
- **Incremental streams share.** Both finish together, as #0054's round robin did for every
  stream before this change.
- **No starvation.** The background stream still gets 6–10% of the bytes while the urgent
  one runs: one turn in 16 goes to the oldest waiter (`HTTP2SharedState.fairShareInterval`),
  plus turns at moments the urgent writer is not waiting.

The default (2 MiB) run is part of the test suite and asserts the completion orders.

## HTTP/3

HTTP/3 orders only sends that wait for the connection's send budget
(`H3AbuseLimits.maxConnectionSendBuffer`, 4 MiB by default): QUIC packet scheduling between
streams belongs to Network.framework, which offers no per-stream priority API to this server.
The budget's ordering is covered by `Tests/HTTP3Tests/H3PriorityTests.swift`
(`budgetServesUrgentWaitersFirst`, `budgetInterleavesIncrementalStreams`,
`budgetKeepsAShareForLowPriority`).

### Measured over Network.framework QUIC

`Tests/HTTP3Tests/H3QUICPriorityTests.swift`: real QUIC on 127.0.0.1 (port 0, in-memory test
identity), two streamed 8 MiB downloads (64 KiB writes), `/low` `u=7` requested before
`/high` `u=0`, the client reading both streams concurrently. Debug build, load average
5.23 / 6.22 / 7.46.

```bash
scripts/guarded.sh -t 180 -- swift test -j 2 --filter H3QUICPriorityTests
```

| Send budget | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| 64 KiB (contended) | `/high` 77.4 ms, `/low` 77.5 ms | `/low` 69.2 ms, `/high` 69.4 ms | `/low` 64.3 ms, `/high` 64.5 ms |
| 4 MiB (default) | `/high` 56.4 ms, `/low` 56.9 ms | `/high` 54.3 ms, `/low` 54.8 ms | `/low` 48.4 ms, `/high` 48.4 ms |

**Network.framework gives no usable control.** Both downloads finish within half a
millisecond of each other in every run, in either order, whatever the budget: a send
completes once Network.framework has buffered it, so the budget is rarely what holds a
stream back, and the QUIC stack then interleaves the streams' packets itself. The send-budget
ordering is a hint that matters only when the budget is truly exhausted (a client that stops
reading, #0104); it does not make an urgent HTTP/3 response finish first on an uncongested
link. Doing better would need per-stream priority in Network.framework's QUIC, which
`NWProtocolQUIC` does not expose, or pacing response sends ourselves.
