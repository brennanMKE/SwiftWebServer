# M6: Compression (#0091)

What response compression costs: CPU per dynamically compressed response, the cost of a cache
hit on a precompressed static variant (compared with an uncompressed hit), throughput on a
50 KiB HTML page with `oha -H 'Accept-Encoding: br, gzip'`, and whether `StaticFiles` got slower
for servers that do not use compression.

- Date: 2026-11-11, 17:40–18:25 PST
- Branch: `m06-compression` (merged with `main` `5f33eb4`); baseline binary built from `5f33eb4`
- Load average (1, 5, 15 min): other agents were building and testing throughout. Per run:
  micro hits 4.11 10.38 24.05 → 3.78 10.21 23.91; StaticFiles comparison 7.46 15.69 29.28 →
  6.39 15.19 28.95; load tests 4.04 10.15 23.81 → 9.91 10.66 23.28 (each row below gives
  its own). The first dynamic runs were taken at 9–28. Not a gating record.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` and `--product SwiftWebServer` |
| Load client | oha 1.16.0, `-z 10s -c 16`, HTTP/1.1 keep-alive, loopback |

## The page

`CompressionFixture.page` in `Sources/sws-bench/CompressionBench.swift`: 51,199 bytes of
HTML-like markup (tags and words from a small vocabulary in a fixed pseudo-random order, some
hex noise), written to `$TMPDIR/sws-bench-compression/index.html`. The load test serves that
file. Encoded sizes:

| Coding | Size | Ratio |
|---|---|---|
| none | 51,199 | 1.000 |
| `br` (libcompression, Brotli quality 2, the only level Apple ships) | 12,101 | 0.236 |
| `gzip` level 4 (dynamic default) | 11,799 | 0.230 |
| `gzip` level 9 (precompressed default) | 10,256 | 0.200 |

## CPU per response (dynamic)

`sws-bench micro --filter Compression.dynamic`: `Compression.encode` on a `.bytes` response
with the page, one-shot into a buffer, pooled zlib encoder. Median of 100 samples, load 5.96.

| Case | µs per response | MB/s | allocs |
|---|---|---|---|
| `br` | 134.4 | 381 | 16 (inside libcompression) |
| `gzip` level 1 | 87.1 | 588 | 8 |
| `gzip` level 4 (default) | 183.9 | 278 | 8 |
| `gzip` level 6 | 831.1 | 62 | 8 |
| `deflate` level 4 | 192.7 | 266 | 8 |

- Level 6 is 4.5× level 4 on this page for 5% smaller output: its lazy matching walks the long
  hash chains a small vocabulary builds. Level 4 compresses to about Brotli-q2 size at a
  fraction of level 6's CPU, hence the default (`CompressionConfiguration.level`).
- Brotli q2 is the cheapest per byte saved and is preferred for dynamic responses (`br` >
  `gzip` > `deflate` at equal weight).
- The 8 allocations are the output buffer, the header copy (the response gains `Vary`,
  `Content-Encoding` and a new `ETag`) and the `ETag` buffer; the pooled encoder saves zlib's
  ~256 KiB state per response.
- Skips cost little: `image/png` 67 ns (type check, no allocation); a compressible response to a
  client that accepts no coding 192 ns and 4 allocations (the headers are copied to add `Vary`).

## Cached variant hit

`sws-bench micro --filter Compression.hit` / `.304`: `StaticFiles.respond` for the page on a
cache hit. Three runs, median ns per request (the first run was disturbed; runs 2–3 shown),
0 allocations in every case.

| Case | Run 2 | Run 3 | vs uncompressed hit |
|---|---|---|---|
| No precompression configured (`Accept-Encoding: br, gzip` ignored) | 75.97 | 75.76 | — |
| Precompressed, no `Accept-Encoding` (identity) | 75.38 | 77.38 | +0–2 ns |
| Precompressed, `Accept-Encoding: br` | 84.91 | 84.85 | +9 ns |
| Precompressed, `Accept-Encoding: deflate, gzip` (curl) | 92.71 | 92.09 | +16 ns |
| Precompressed, `Accept-Encoding: gzip, deflate, br, zstd` (browsers) | 99.40 | 100 | +24 ns |
| `304` for the `br` variant's `If-None-Match` | 178 | 174 | (identity `304`: 155–166) |

`Compression.negotiate` alone (the `Accept-Encoding` scan, one pass over the bytes, tokens
compared as packed integers) is 43 ns for the browser header and 46 ns for
`br;q=1.0, gzip;q=0.8, *;q=0.1` through the generic `HTTPFieldCollection` path; inlined into
`StaticFiles` it adds the 9–24 ns above. A variant hit is an uncompressed hit plus that scan:
no compression, no allocation, the variant's headers and bytes were rendered once when the
file entered the cache. Earlier versions of the scanner (list splitter closure per element,
`Span` comparisons) cost +135 ns, then +60 ns.

## Throughput (`oha -H 'Accept-Encoding: br, gzip'`, 50 KiB page)

`SwiftWebServer` release build, `{"port": 0, "errorPages": false, …}`, one process, 16
keep-alive connections for 10 s.

| Config | Sent | Requests/s | Mean latency | Data | Load before → after |
|---|---|---|---|---|---|
| no `compression` | identity, 51,199 B | 61,728 | 0.258 ms | 29.4 GiB | 4.04 → 4.27 |
| `"compression": true` (precompressed variants) | `gzip`, 10,256 B | **91,938** | 0.173 ms | 8.8 GiB | 4.08 → 4.01 |
| dynamic only (`precompress: false, sidecars: false`) | `br`, 12,101 B | 43,790 | 0.365 ms | 4.9 GiB | 4.01 → 7.56 |
| dynamic only, `encodings: ["gzip"]` | `gzip` L4, 11,799 B | 25,470 | 0.627 ms | 2.8 GiB | 7.56 → 9.91 |

- Precompressed variants serve 1.49× the requests of the uncompressed file with a fifth of the
  bytes: the response is smaller and costs no CPU to produce.
- For `br, gzip` the cache sends `gzip`: at equal weight `StaticFiles` sends the smallest
  stored variant, and gzip level 9 (10,256 B) beats Brotli quality 2 (12,101 B) on this page.
  A `index.html.br` sidecar made with `brotli -q 11` would win instead.
- Dynamic compression is CPU-bound: 43.8k responses/s at ~134 µs each is ~5.9 CPU-seconds per
  second spread over the server's cores; gzip level 4 halves that again. Use precompression
  (the default with `"compression": true`) for static files; dynamic compression is for
  generated responses and large files.
- An earlier run at load 6.5–10 gave the same picture (precompressed with `br` preferred:
  83,264/s; dynamic `br` 44,315/s; dynamic `gzip` 36,249/s).

## Unregistered: StaticFiles without compression

The only change on the uncompressed path is one `variants.isEmpty` check per hit (and the
`CachedFile` fields). `sws-bench micro --filter StaticFiles.`, baseline `5f33eb4` and this
branch interleaved, three runs each; median of the three medians, ns per request.

| Benchmark | Baseline | #0091 | Change |
|---|---|---|---|
| `hit 626-byte index.html` | 80.72 | 77.97 | −3.4% |
| `hit directory index` | 67.19 | 68.01 | +1.2% |
| `hit 1 MiB file region` | 82.06 | 77.84 | −5.1% |
| `hit percent-encoded path` | 91.10 | 91.73 | +0.7% |
| `range 0-99 of 626 bytes` | 250 | 245 | −2.0% |
| `304 If-None-Match` | 162 | 158 | −2.5% |
| `304 If-None-Match list` | 214 | 220 | +2.8% |
| `304 If-Modified-Since` | 103 | 105 | +1.9% |
| `304 If-None-Match 1 MiB file` | 161 | 160 | −0.6% |
| `200 If-None-Match stale` | 119 | 123 | +3.4% |

The spread within each binary's own runs is 3–15% at this load (baseline `hit 626-byte`:
93.75, 79.44, 80.72), and the changes go both ways: no measurable cost. The `Compression`
middleware itself is not in the chain unless configured (`if let compressor { compressor }`),
and HTTP/1.1 and the server are untouched, so `h1conn` was not rerun.
