# M5: HTTPS keep-alive throughput (#0087, #0088)

The first HTTPS numbers: `sws-bench serve --tls` (a Network.framework `TCPListener` with
`NWProtocolTLS`, TLS 1.3, ALPN `http/1.1`) against the same server in cleartext on both
transports, keep-alive, 16 connections, the built-in `Hello, World!\n` handler.

- Date: 2026-11-11, 16:11 PST
- Branch: `m05-tls` (base `main` `48961a7`)
- Not a gating record: the orchestrator runs gating benchmarks at milestone end. Other agents
  had the machine busy (load average 8–10, see each row); no build ran during the runs.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| Memory | 64 GB |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |
| Load tool | oha 1.16.0 |

## Method

For each round and each variant: start `.build/release/sws-bench serve --port 0` with
`--tls` (test identity from `scripts/make-test-identity.sh`, loaded in memory), `--transport nw`
or `--transport bsd`; warm up with `oha -z 1s -c 16`; then measure
`oha -z 5s -c 16 --insecure` (`https://` or `http://127.0.0.1:PORT/`); stop the server with
SIGTERM. Three rounds, variants interleaved. Every response was `200`; the 14–16 "errors" per
run are requests cut off at the 5 s deadline, as in `M3-accept.md`. The whole run went through
`scripts/guarded.sh`.

## Results

| Round | Variant | Load (1 min) | req/s | p50 | p99 |
|---|---|---|---|---|---|
| 1 | HTTPS (NW + TLS 1.3) | 9.62 | 44,642 | 0.369 ms | 0.420 ms |
| 1 | HTTP, NW | 9.13 | 70,012 | 0.216 ms | 0.373 ms |
| 1 | HTTP, BSD | 9.04 | 93,996 | 0.162 ms | 0.613 ms |
| 2 | HTTPS (NW + TLS 1.3) | 8.56 | 44,886 | 0.366 ms | 0.419 ms |
| 2 | HTTP, NW | 8.67 | 68,931 | 0.223 ms | 0.392 ms |
| 2 | HTTP, BSD | 8.57 | 94,113 | 0.162 ms | 0.620 ms |
| 3 | HTTPS (NW + TLS 1.3) | 8.52 | 44,464 | 0.371 ms | 0.425 ms |
| 3 | HTTP, NW | 8.24 | 69,626 | 0.218 ms | 0.401 ms |
| 3 | HTTP, BSD | 8.06 | 93,426 | 0.163 ms | 0.625 ms |

Medians:

| Variant | req/s | p50 | p99 | vs HTTP over NW |
|---|---|---|---|---|
| HTTPS (NW + TLS 1.3) | 44,642 | 0.369 ms | 0.420 ms | −36% req/s |
| HTTP, NW | 69,626 | 0.218 ms | 0.392 ms | — |
| HTTP, BSD | 93,996 | 0.162 ms | 0.620 ms | +35% req/s |

The spread between rounds is under 2% for every variant.

## Reading the numbers

- **TLS costs 36% of keep-alive throughput over the NW transport** and adds about 0.15 ms to
  the p50: record encryption and decryption of a small request and response inside
  Network.framework. There is no new code on our request path: the HTTP/1.1 runner, the
  handler and the transport adapter are the ones the cleartext NW case uses.
- The comparison that matters for HTTPS is HTTPS against cleartext over NW, since TLS stays on
  Network.framework (ROADMAP §2). The BSD row is for scale.
- Handshake cost is not in these numbers (keep-alive). With a new connection per request, NW's
  accept cost (about 665 µs per connection, `M3-accept.md`) comes before the handshake.
