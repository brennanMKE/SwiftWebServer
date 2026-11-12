# M4 cut-over: shipped SwiftWebServer load and memory

Recorded by `scripts/bench-baseline.sh` on 2026-11-12T00:32:31Z at commit `177a569`.
Compared with the M0 legacy baseline ([M0-baseline.md](M0-baseline.md)); the legacy server
itself was deleted in #0086.

> **Recorded on a loaded machine** (1-minute load average 7.6 on 12 cores, from other work running in parallel). Numbers are depressed and noisy; re-run `scripts/bench-baseline.sh` on an idle machine before using them as a gate.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| Memory | 64 GB |
| OS | macOS 27.0 (26A428) |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release` |
| Load tools | `sws-bench load`, oha 1.16.0, curl |
| Load average before / after | 4.67 12.61 14.31 / 7.56 9.42 12.47 (1, 5, 15 min) |

## Method

- Server: the release `SwiftWebServer` with a config of only `host`, `port: 0` and `root`
  (every other setting at its default: BSD transport, HTTP/1.1, ErrorPages + StaticFiles,
  `maxConnections` 1024), serving a copy of `Root/Public` plus a 8 MiB random
  `large.bin`, as in M0. One server process for the whole run.
- Each run: 16 connections, 10 s, loopback, `sws-bench load` then oha.
  The close rows match the M0 cases (the legacy server closed every connection); the
  keep-alive rows have no M0 equivalent.
- Memory: `curl --limit-rate 256M` downloads a sparse 1 GiB `huge.bin` once (a client slower than
  the server, so backpressure is exercised) while the server's RSS
  is sampled every 50 ms.

## Load

| Case | Client | req/s | p50 ms | p99 ms | body MiB/s | errors | M0 legacy req/s | change |
|---|---|---:|---:|---:|---:|---|---:|---:|
| `/` (626 B), close | sws-bench | 3,630 | 4.131 | 11.271 | 2.2 | 0 | 701 | +418% |
| `/` (626 B), close | oha | 10,787 | 0.690 | 2.526 | 6.2 | Can't assign requested address (os error 49) 4004 (+16 cut at deadline) | 898 | +1,101% |
| `/large.bin` (8 MiB), close | sws-bench | 975 | 16.289 | 21.178 | 7,800.7 | 0 | 75 | +1,200% |
| `/large.bin` (8 MiB), close | oha | 958 | 16.527 | 22.190 | 7,649.9 | 0 (+16 cut at deadline) | 83 | +1,054% |
| `/` (626 B), keep-alive | sws-bench | 61,348 | 0.266 | 0.418 | 36.6 | 0 |  |  |
| `/` (626 B), keep-alive | oha | 78,696 | 0.174 | 0.742 | 47.0 | 0 (+13 cut at deadline) |  |  |
| `/large.bin` (8 MiB), keep-alive | sws-bench | 1,079 | 14.813 | 19.404 | 8,630.6 | 0 |  |  |
| `/large.bin` (8 MiB), keep-alive | oha | 798 | 19.922 | 32.013 | 6,373.6 | 0 (+16 cut at deadline) |  |  |

## Memory

| Point | RSS MiB |
|---|---:|
| idle, before load | 7.2 |
| after `/` (626 B), close / sws-bench | 14.2 |
| after `/` (626 B), close / oha | 39.3 |
| after `/large.bin` (8 MiB), close / sws-bench | 14.2 |
| after `/large.bin` (8 MiB), close / oha | 39.4 |
| after `/` (626 B), keep-alive / sws-bench | 14.2 |
| after `/` (626 B), keep-alive / oha | 39.4 |
| after `/large.bin` (8 MiB), keep-alive / sws-bench | 14.3 |
| after `/large.bin` (8 MiB), keep-alive / oha | 39.4 |

1 GiB download: HTTP 200, 1,073,741,824 bytes in 4.00 s (256 MiB/s). Server RSS before 39.4 MiB, peak during
39.4 MiB, after 39.2 MiB.

## Exit criterion (M4)

- **Throughput beats the M0 baseline** in every comparable case, by 4x to 12x with both clients
  (the M0 run had a load average of 206, this one about 5 to 8, so the ratio overstates the gain;
  the margin is still far beyond the 10% rule). The oha small-file close row hit loopback
  ephemeral-port exhaustion ("Can't assign requested address", see the M0 notes): the server
  was faster than TIME_WAIT allows, so that row is limited by the client, not the server.
- **Memory stays flat on a large file**: RSS did not move while streaming 1 GiB to a
  rate-limited client (39.4 MiB before and at peak). The legacy server read every file into
  memory, and its RSS reached 439-808 MiB in M0. Growth during the load runs (7 MiB idle to
  39 MiB) comes from 16 concurrent connections' buffers and the file cache, and stays level across
  later runs.
- The keep-alive rows have no legacy equivalent. They are in line with M3 (about 61-79k req/s
  for the small file).
