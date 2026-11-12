# Benchmarks

Every milestone records its performance here and compares it with the previous record
(docs/ROADMAP.md §1.6 and §7). The tool is `sws-bench` (`Sources/sws-bench`), which has no
dependencies beyond the package.

| File | Contents |
|---|---|
| `M0-baseline.md` | Legacy server load baseline (`scripts/bench-baseline.sh`), with oha and Caddy for scale |
| `M3-accept.md` | New-connection throughput, Network.framework against BSD sockets (#0113): `sws-bench accept` and `scripts/bench-accept.sh` |
| `compare-servers*.md` | `scripts/bench-compare.sh` runs against nginx, Apache, Caddy, lighttpd, h2o and the legacy server; `-staticfiles` is the run with StaticFiles (#0084) serving from disk |
| `M<N>-<name>.md` | One file per milestone: what changed, results, comparison with the previous record |

## The rule: a regression over 10% blocks the milestone

A milestone does not exit while any tracked number is more than 10% worse than the last
recorded value for the same case: lower req/s, higher p50 or p99 latency, higher ns/op, or
more allocations per op. Allocations are exact counts, so for zero-allocation targets any
increase at all is a regression.

Before calling something a regression, rule out noise:

1. Run on an otherwise idle machine (the record includes the load average) with a release build.
2. Repeat the run three times; use the median run. If the spread between runs is itself more
   than 10%, the measurement is not usable. Lengthen it or remove the noise source first.
3. Compare like with like: same client, same case (path, connections, keep-alive), same duration.

A regression that is accepted on purpose (e.g. a correctness fix that costs time) needs a line
in the milestone file saying what was traded and why, and the owner's agreement.

## Recording a milestone

1. `swift build -c release`, then on an idle machine:
   - `swift run -c release sws-bench micro --json > <scratch>/micro.json` for ns/op and allocations.
   - `scripts/bench-baseline.sh` (or a successor script for the new server) for load numbers.
2. Write `docs/benchmarks/M<N>-<name>.md` with: date, commit, machine (CPU, cores, memory, OS,
   Swift version, load average), the commands run, the result tables, and a comparison column
   against the previous record with the percent change (`Stats.percentChange`).
3. Commit the markdown. Raw JSON stays out of the repository unless a milestone needs it.

Run every server and client through `scripts/guarded.sh` and bind loopback only (AGENTS.md).

## `sws-bench micro`

Runs registered microbenchmarks:

```
sws-bench micro [--filter TEXT] [--iterations N] [--warmup N] [--batch N] [--list] [--json]
```

- Each benchmark is a closure; one call is one op. It runs `--warmup` untimed calls, then
  `--iterations` timed samples (default 200), each timing `--batch` consecutive calls with
  `ContinuousClock`. The batch is calibrated so a sample takes about 50 µs, which keeps clock
  overhead out of ns-scale results. Reported: min, median and p99 of the per-sample ns/op.
- **Allocations per op** are counted in a separate untimed pass by installing a callback in
  libmalloc's exported `malloc_logger` hook (the one `MallocStackLogging` uses), which fires on
  every allocation in every zone. `malloc_zone_statistics` and `mstats` were considered and
  rejected for this: they report blocks in use, so an allocation freed within the op nets to
  zero and is invisible. The `malloc_zone_statistics` blocks-in-use delta is still reported as
  "retained" per op, which catches leaks and growth. The `harness.allocateObject` benchmark
  must show 1.00 allocations/op; if it shows 0, counting is broken.
- Pass results through `blackHole(_:)`. It is `@_optimize(none)`, so the optimizer cannot delete
  the work or stack-promote an object passed to it (without it, the allocation benchmark
  reports 0 allocations in release builds because the object never reaches the heap).

### Adding benchmarks

Put them in `Sources/sws-bench/<Name>Bench.swift`:

```swift
func registerByteBufferBenchmarks() {
    var buffer = ByteBuffer(capacity: 4096)   // setup runs once, not timed
    Benchmark.register(name: "ByteBuffer.writeBytes") {
        buffer.clear()
        buffer.write(payload)
        blackHole(buffer.readableBytes)
    }
}
```

and add one line, `registerByteBufferBenchmarks()`, to `registerAllBenchmarks()` in
`Sources/sws-bench/BenchmarkRegistry.swift`. Name benchmarks `Target.operation` so `--filter`
selects a target.

Benchmarks that time themselves (the ByteBuffer, Huffman, QPACK and HTTP/3 frame benches
written before the harness) are registered with `Benchmark.registerSuite(name:run:)` in
`registerSelfTimedSuites()`. They report their own ns/op with no percentiles or allocation
counts (`batch` shows `self`); converting them to `register(name:body:)` closures adds both.

## `sws-bench h1conn`

The HTTP/1.1 connection loop (#0080) over an in-process transport that never suspends:

```
sws-bench h1conn [--requests N] [--json]
```

Reports ns and allocations per request for keep-alive (one request per receive) and pipelined
(16 per receive) traffic with the `serve` hello handler. Per-request figures are the difference
between an N-request and an N/10-request connection, so per-connection setup cancels out. The
target is 0 allocations per request.

## `sws-bench serve`

The new-stack HTTP/1.1 server on a `TCPListener` (loopback by default, port 0 picks a free port),
answering every request with `200 text/plain` `Hello, World!` or `--body-size N` bytes. Prints
`listening HOST:PORT`; SIGINT/SIGTERM drain and exit 0.

## `sws-bench load`

An HTTP/1.1 load client on Network.framework `NWConnection`:

```
sws-bench load --url http://127.0.0.1:PORT/ [--path PATH] [--connections N] [--duration S]
               [--keepalive | --no-keepalive] [--grace S] [--json]
```

- `--connections` workers each keep one request in flight for `--duration`. Requests still in
  flight `--grace` seconds after the duration (default 5) are cancelled and counted as `timeout`.
- Responses are framed from the head (`Content-Length`, `chunked`, no-body statuses, or
  close-delimited), so keep-alive works without reading to EOF. Bodies are counted, not stored.
- `--no-keepalive` sends `Connection: close` and opens a connection per request; latency then
  includes connect. In keep-alive mode a connection the server closed after a response is
  retried once on a new connection (counted as a stale retry, not an error).
- Reports requests/s, body MiB/s, latency p50/p90/p99/max/mean, status counts, and errors by kind.

Known limits of the client:

- Network.framework connection setup is expensive, so in close mode `sws-bench` saturates long
  before oha does (see the Caddy rows in `M0-baseline.md`); use oha's number for close-mode
  servers faster than that. Keep-alive mode is close to oha.
- Close mode on loopback runs out of ephemeral ports at about 550 new connections/s sustained
  (16k ports, TIME_WAIT 30 s); runs then show `connect` errors.
