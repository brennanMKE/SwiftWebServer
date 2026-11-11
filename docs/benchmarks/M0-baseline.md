# M0 baseline: legacy SwiftWebServer

Recorded by `scripts/bench-baseline.sh` on 2026-11-11T21:08:56Z from branch `m00-bench` (legacy server code unchanged from `main` `16a558a` apart from `LISTEN_HOST`).
This is the reference that later milestones compare against (see [README](README.md)).

> **Provisional: recorded on a loaded machine** (1-minute load average 206 on 12 cores, from other work running in parallel). These numbers are depressed and noisy. Re-run `scripts/bench-baseline.sh` on an idle machine before using them as a gate.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| Memory | 64 GB |
| OS | macOS 27.0 (26A428) |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release` |
| Load tools | `sws-bench load`, oha 1.16.0 |
| Ephemeral ports | 49152-65535, MSL 15000 ms |
| Load average at end | 206.23 150.77 82.00 (1, 5, 15 min) |

## Method

- Server: the legacy `SwiftWebServer` release binary, `ROOT_PATH` pointing at a temporary
  root whose `http-config.json` is `Root/http-config.json` with a free port, serving a copy
  of `Root/Public` plus a generated 8 MiB random `large.bin`. `LISTEN_HOST=127.0.0.1`
  keeps it on loopback. Each client run gets a fresh server process, because the legacy
  server slows down and grows as it serves (unbounded per-connection streams and tasks).
- Each run: 16 connections, 10 s, client and server on the same
  machine over loopback. `sws-bench load` then `oha` against the same URL.
- The legacy server closes the connection after every response, so it is measured with
  keep-alive off (`--no-keepalive`, `oha --disable-keepalive`); latency then includes the
  TCP connect.
- Latency is request start to last response byte. `sws-bench` p50/p99 interpolate between
  ranks; oha reports its own percentiles.

## Legacy server

| Case | Client | req/s | p50 ms | p99 ms | body MiB/s | errors |
|---|---|---:|---:|---:|---:|---|
| legacy `/` (626 B), close | sws-bench | 701 | 17.576 | 96.027 | 0.4 | 0 |
| legacy `/` (626 B), close | oha | 898 | 10.597 | 104.818 | 0.5 | 0 (+16 cut at deadline) |
| legacy `/large.bin` (8 MiB), close | sws-bench | 75 | 201.657 | 505.514 | 597.9 | 0 |
| legacy `/large.bin` (8 MiB), close | oha | 83 | 176.498 | 477.229 | 652.5 | 0 (+16 cut at deadline) |

Legacy server RSS after each run (fresh process per run): legacy `/` (626 B), close / sws-bench: 808 MiB; legacy `/` (626 B), close / oha: 701 MiB; legacy `/large.bin` (8 MiB), close / sws-bench: 487 MiB; legacy `/large.bin` (8 MiB), close / oha: 439 MiB.

## Reference: Caddy v2.11.1

`caddy file-server` on the same files, for scale only. Not a gate.

| Case | Client | req/s | p50 ms | p99 ms | body MiB/s | errors |
|---|---|---:|---:|---:|---:|---|
| caddy `/` (626 B), close | sws-bench | 633 | 13.642 | 125.590 | 0.4 | 0 |
| caddy `/` (626 B), close | oha | 6,446 | 0.699 | 40.807 | 2.3 | 0 (+15 cut at deadline) |
| caddy `/large.bin` (8 MiB), close | sws-bench | 217 | 69.733 | 188.610 | 1,733.7 | 0 |
| caddy `/large.bin` (8 MiB), close | oha | 556 | 15.499 | 173.641 | 4,436.4 | 0 (+16 cut at deadline) |
| caddy `/` (626 B), keep-alive | sws-bench | 3,929 | 1.116 | 55.624 | 2.3 | 0 |
| caddy `/` (626 B), keep-alive | oha | 9,608 | 0.501 | 35.061 | 3.4 | 0 (+13 cut at deadline) |

## Notes

- `sws-bench load` opens connections through Network.framework (`NWConnection`), whose
  per-connection setup is far more expensive than oha's raw sockets. With keep-alive off the
  client itself caps throughput; the Caddy close rows show that ceiling. When a close-mode
  server number approaches it, oha's figure is the one that measures the server.
  With keep-alive on, the two clients are much closer.
- Close-mode load is limited by ephemeral ports: every request leaves a loopback TIME_WAIT
  socket for 2 x MSL, so above about 16k / 30 s = 550 new connections per second sustained,
  a run of more than a few seconds starts failing connects (oha: "Can't assign requested
  address"; sws-bench: `connect` errors). The script waits for TIME_WAIT to drain between
  runs, but a fast server in close mode (the Caddy close rows) still hits the limit within
  one run. Keep-alive numbers do not have this problem.
- Other work on the machine shows in the load average above; a loaded machine depresses
  every number. Compare runs only at similar load.
- oha reports requests in flight at the deadline as errors ("cut at deadline"); they are
  listed separately and are not failures.
- Compare a server only against numbers taken with the same client, case and settings.
- Re-run with `scripts/bench-baseline.sh`; set `DURATION`, `CONNECTIONS`, `LARGE_MB` to change
  the load. Raw JSON is written to a temporary directory and discarded.
