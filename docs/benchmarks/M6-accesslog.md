# M6: AccessLog and metrics (#0090)

What the access log and request metrics cost per request when registered, and whether the
extension point they need (`ConnectionObserver`, `ConnectionContext.requestContext`) costs
anything when nothing is registered.

- Date: 2026-11-11, 16:36–16:38 PST
- Branch: `m06-accesslog` (merged with `main` `f5673a9`); baseline binary built from `f5673a9`
- Load average (1, 5, 15 min): 4.46 7.92 11.21 before, 11.66 10.36 11.79 after (other agents
  building and testing). Not a gating record.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |

## Cases

`sws-bench h1conn --requests 1000000` gained access log variants. Each puts one `AccessLog`
in front of the prebuilt `HelloHandler` with the builder, opens its per-connection state through
`ConnectionObservers` as `Server` does, and runs the log's writer (its `ServerComponent`) in a
task beside the measurement.

| Case | Chain |
|---|---|
| `request` | `HelloHandler` alone: the unregistered case |
| `empty` | `CompiledChain(hello)`: the chain boundary every chain with a middleware pays |
| `log-metrics` | `{ AccessLog(metrics:); hello }`: counters and latency histogram, no lines |
| `log-null` | `{ AccessLog(format: .common, destination: .discard); hello }`: lines formatted, batched and handed to the writer, which drops them |
| `log-json` | the same with `.json` lines |
| `log-file` | Common lines appended to a file in `$TMPDIR` (`O_APPEND`, deleted after) |
| `log-file-metrics` | `log-file` plus metrics |

`dispatch log-*` rows call the same chains in a loop through `any HTTPHandler`, with no
connection loop (one fixed start time, so every request takes the same histogram bucket).

The access log's cost is a log row minus `empty`: it includes the start-time stamp
(`starttime` − `request`, about 4–11 ns) and the end-of-request clock read.

## Results

Baseline and new binaries interleaved, 7 runs each; median ns per request (min in brackets).

| Benchmark | Baseline `f5673a9` | #0090 | Change |
|---|---|---|---|
| `h1conn.keepalive request` | 244.8 (235.0) | 243.6 (232.4) | −0.5% (min −1.1%) |
| `h1conn.pipelined16 request` | 174.2 (172.3) | 176.3 (166.8) | +1.2% (min −3.2%) |
| `h1conn.keepalive empty` | 265.3 (260.8) | 267.1 (261.5) | +0.7% |
| `h1conn.pipelined16 empty` | 195.5 (184.0) | 197.4 (193.2) | +1.0% |

| Case | keep-alive ns/req | − `empty` | pipelined16 ns/req | − `empty` | allocs/req |
|---|---|---|---|---|---|
| `empty` | 267.1 (261.5) | | 197.4 (193.2) | | 0.000 |
| `log-metrics` | 301.8 (283.3) | +35 | 218.4 (209.6) | +21 | 0.000 |
| `log-null` | 328.2 (308.3) | +61 | 243.3 (238.0) | +46 | 0.001–0.002 |
| `log-json` | 345.2 (339.1) | +78 | 261.8 (251.9) | +64 | 0.026–0.030 |
| `log-file` | 317.2 (308.3) | +50 | 237.4 (231.8) | +40 | 0.001–0.002 |
| `log-file-metrics` | 326.0 (320.4) | +59 | 243.4 (237.3) | +46 | 0.001–0.002 |

| Dispatch | ns/call | − `dispatch empty` (39.2) |
|---|---|---|
| `dispatch log-metrics` | 52.3 (51.2) | +13 |
| `dispatch log-null` | 72.4 (69.3) | +33 |
| `dispatch log-json` | 92.5 (87.7) | +53 |

Only the JSON log dropped lines: 337,474 of 13.2 million in a check run, counted in
`linesDropped`. Its `h1conn` rows and `dispatch log-json` share one log, and the dispatch row
produces 11 million of those lines at about 11 million a second from one core, faster than the
writer drains them; the drops did not slow the calls. The Common logs (null and file) dropped
nothing.

## Reading

- **Unregistered costs nothing.** `request` (no component) and `empty` are within noise of the
  baseline (−0.5% / +1.2% medians, mins −1.1% / −3.2%), under the 2% bar. With no observer a
  connection pays one empty-array check, and the runners read `context.requestContext` where
  they built a `RequestContext` before. (`dispatch empty` reads 4 ns slower in the new binary in
  every run while the same chain in the connection loop does not; it runs after the log rows,
  with their writers still alive, and is not on any changed path.)
- **Registered: tens of ns.** Metrics alone cost 13 ns per call (an end-of-request clock read,
  four relaxed atomic adds on the connection's own counters, one leading-zero count for the
  bucket) plus the start-time stamp, about 20–35 ns in the loop. A Common Log Format line costs
  about 30 ns more (40–60 ns in the loop, file or null sink alike: the write happens on the
  writer's task), JSON about 20 ns more than Common (longer lines, more escaping calls).
- **What made it cheap** (development measurements, same machine):
  - First version: `log-null` +103 ns (keep-alive) / +82 ns (pipelined). Fields struct holding a
    copy of the `HTTPRequest` (two retains per line) and a global "lines logged" atomic bumped
    per request: removed (the counter is now bumped per batch; a per-request global counter
    would also bounce its cache line between cores).
  - Pre-rendered line prefix: the peer, the date and (JSON) the protocol are rendered once per
    second per connection, so a line is about ten appends.
  - The batch hand-off dominated: with 8 KiB batches it cost about 16 ns per line (64 KiB
    batches cut `dispatch log-null` from 88 to 72 ns). Two causes: waking the writer for every
    batch (`trySend` resumes a waiting consumer, a thread wake-up paid by the request path), and
    a `malloc` per batch freed on the writer's thread. Now the writer drains in bursts and
    sleeps 1 ms between them (at most about 1000 wake-ups a second), and written buffers are
    recycled to the connections (up to 64 spares).
  - An uncontended `Mutex` (the per-connection buffer's lock) and a relaxed `wrappingAdd` each
    measured 1.8 ns in isolation: not worth avoiding.
- **Allocations** are per batch, not per request: a new buffer when no spare is left, and the
  writer's own async bookkeeping (counted process-wide). `log-json` allocates more because its
  lines are about three times longer, so batches are three times as frequent.
- **Drops instead of waits.** The writer must drain a millisecond of lines between bursts; the
  default queue (1024 batches of 8 KiB) holds about 8 MiB. A sustained rate beyond what the
  writer can write drops whole batches and counts their lines; the request path never waits.
