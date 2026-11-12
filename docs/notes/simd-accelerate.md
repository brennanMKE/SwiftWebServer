# SIMD and Accelerate on the request path (experiment, dropped)

> **Status: dropped, 2026-11-12.** This was an experiment, and none of its code was merged. SIMD made some per-byte
> work 2–3x faster but didn't change requests per second, because the server's own code is about 0.3 µs of a
> roughly 22 µs request. The prototype is commit `aa8fd5b` on the local branch `perf-simd`; it is not on `main`.
> The measurements are kept here so the question doesn't need answering again.

- Date: 2026-11-12, branch `perf-simd`
- Machine: Apple M4 Pro, 12 cores, release build (`swift build -c release -j 2`)
- Load average during the runs: 3.0 to 8.3 (two other agents were building). Treat the numbers as indicative; each "before/after" pair was taken in the same process seconds apart, and the parser pairs were repeated three times per side.
- Reproduce: `scripts/guarded.sh -t 300 -- .build/release/sws-bench micro --filter simd` and `--filter parse.head`

## Summary

SIMD does not move requests per second. The server spends about 0.3 µs per request in its own code and about 22 µs in Network.framework receive and send (`docs/SERVER-COMPARISON.md`). The whole head parse is 130 ns, or 0.6% of a request, and it was already scanning eight bytes at a time. The best parser change here saves about 17 ns on a realistic 1.1 KiB Chrome head, which is under 0.1% of a request.

SIMD does pay where the server touches every payload byte: WebSocket text validation is 3x faster on ASCII, and small-frame unmasking is 2x faster. Generic byte search (`ASCII.firstIndex`, used off the hot path and by the proxy) is 2x to 14x faster.

Accelerate has nothing for this workload. vDSP and vImage work on floats and pixels; libcompression is already in use for Brotli.

## Ranked results

"% of request" is the saving against roughly 22 µs per kept-alive HTTP/1.1 request, or per WebSocket message where noted.

| # | Hot spot | Before | After | Speedup | % of request | Status |
|---|---|---|---|---|---|---|
| 1 | UTF-8 validation, ASCII JSON 1 KiB (WebSocket text) | 41 ns | 13.5 ns | 3.0x | per message: about 28 ns per KiB | Prototyped |
| 1 | UTF-8 validation, ASCII 125 B | 12.2 ns | 6.5 ns | 1.9x | | Prototyped |
| 1 | UTF-8 validation, mixed Latin 1 KiB | 303 ns | 248 ns | 1.2x | | Prototyped |
| 1 | UTF-8 validation, CJK 1 KiB | 790 ns | 618 ns | 1.3x | | Prototyped (noisy; second run 777 vs 874 median) |
| 2 | WebSocket unmask, 125 B frame | 8.1 ns | 4.1 ns | 2.0x | negligible per message | Prototyped |
| 2 | WebSocket unmask, 16 B / 1 KiB / 16 KiB | 2.6 / 10.3 / 154 ns | 2.6 / 9.6 / 141 ns | 1.0x to 1.1x | | Prototyped; no real gain (see below) |
| 3 | Field-value scan, 117 B `user-agent` | 7.6 ns | 4.3 ns | 1.8x | | Prototyped in `HTTP1Parser` |
| 3 | Field-value scan, 600 B cookie | 28.4 ns | 13.0 ns | 2.2x | | Prototyped |
| 3 | `parse.head`, 16-header Chrome request (1.1 KiB) | 210 min / 237 median | 193 min / 221 median | 1.08x | under 0.1% | Prototyped |
| 3 | `parse.head`, 10-header browser request (330 B) | 117 / 130 | 118 / 133 | 1.0x | 0 | Neutral |
| 4 | `ASCII.firstIndex`, hit at byte 23 / 127 / 1023 | 12.2 / 44 / 279 ns | 5.1 / 6.7 / 19 ns | 2.4x / 6.6x / 14x | off the hot path | Prototyped; also drove the proxy's `findHeadEnd` |
| 5 | `ASCII.equalsCaseInsensitive`, 10 B token | 7.6 ns | 3.1 ns | 2.5x (SWAR, not SIMD) | about 0.02% | Prototyped |

## What the prototype changed (not merged)

- `Sources/HTTPCore/SIMDScan.swift` (new): `firstIndex(of:)`, `firstControlOrDelete`, `firstNonAlphanumericOrDash`, `firstNonASCII`, and `xor(_:into:count:repeating:)` over `SIMD16<UInt8>`. No allocation, no reads outside the given range, results independent of alignment and split point.
- `HTTP1Parser` `.value` state: a 16-byte block loop ahead of the SWAR loop. The compare mask locates the CR, so a value normally ends without the byte loop. Split-invariance holds because the scan still stops at the same byte; the existing differential and split tests pass unchanged.
- `UTF8Validator`: after an ASCII byte, the rest of the ASCII run is skipped with `firstNonASCII` (one 8-byte word, then 16-byte blocks, then 64 bytes per step).
- `WSMasking.xor`: 64 bytes per step, then 16, 8, and a tail.
- `ASCII.firstIndex(of:in:from:)` and `ASCII.firstCRLF` use `SIMDScan`; `ASCII.equalsCaseInsensitive` compares 8-byte words with an overlapping last word.
- `UpstreamResponseParser.findHeadEnd` jumps from LF to LF.
- `sws-bench`: `SIMDBench.swift` keeps a verbatim copy of each replaced routine as the "before" side, plus a realistic Chrome head for `parse.head`.
- Tests: `Tests/HTTPCoreTests/SIMDScanTests.swift` checks every scan against a byte loop for every byte value, position, length and start offset around the block boundaries, and XOR at every length 1...200, in place and out of place.

## What did not help

- **SIMD field-name scan in the parser.** Tried and removed. With it, the 10-header head went from 118 to 131 ns minimum and the Chrome head from 210 to 221. Names are 4 to 25 bytes, the classification needs seven vector operations, and moving the mask out of a vector register costs more than the two SWAR words it replaces. `SIMDScan.firstNonAlphanumericOrDash` stays in the library (tested) but the parser does not call it.
- **Masking large frames.** LLVM already auto-vectorises the old 8-byte loop: 1 KiB in 10 ns is about 100 GB/s, which is memory bandwidth. The explicit SIMD loop only wins between 16 and a few hundred bytes, where the auto-vectorised loop's runtime checks and scalar remainder dominate.
- **ASCII scan order.** Checking 64 bytes first made mixed Latin text 13% slower than before (337 vs 297 ns), because short ASCII runs between multi-byte characters paid for four loads and a vector-to-integer move. Checking one 8-byte word first fixed that (248 ns).
- **Accelerate.** vDSP and vImage have no byte-classification or delimiter-search primitives; converting bytes to floats to use them would be slower than the scalar loop. Not used.

## Swift SIMD pitfalls seen

- There is no `movemask` on NEON and Swift exposes no intrinsics. Reinterpreting the compare mask as `SIMD2<UInt64>` and taking `trailingZeroBitCount >> 3` of the first non-zero lane works and compiles to two moves.
- Moving a mask from a vector register to an integer register costs a few cycles. For inputs under about 16 bytes a SWAR word is as fast or faster.
- Swift has no byte shuffle with a runtime index vector (`vqtbl1q` / `pshufb`). That rules out the lookup-table algorithms (full SIMD UTF-8 validation, SIMD token-class tables) in pure Swift.
- `Array.span` needs macOS 26; use `withUnsafeBufferPointer { $0.span }` on macOS 15.

## Surveyed and left alone

| Candidate | Current | Why no SIMD |
|---|---|---|
| Huffman decode (HPACK/QPACK) | 277 ns per 117 B value (2.4 ns/byte) | The bit stream is serially dependent, so there is nothing to vectorise. It is still the largest per-byte codec cost on HTTP/2 and HTTP/3; see follow-up 1 |
| Huffman encode | 333 ns per 117 B value | Same; see follow-up 2 |
| QPACK decode / encode | 663 / 963 ns per block | Dominated by Huffman and table work |
| HPACK integer decoding, HTTP/2 frame header | 9-byte header, 1 to 3 byte integers | Fixed-size loads already; H3 frames parse in 13 ns |
| Chunked size parsing | 1 to 4 hex digits | Too short |
| Request-target scan | SWAR, 8 bytes per step | Targets are short; not measured with SIMD |
| Percent-decoding, path normalisation | StaticFiles hit 81 ns, +15 ns when percent-encoded | Short inputs with a data-dependent state machine |
| Response serialisation | 73 ns for 5 headers | Already `memcpy` of pre-rendered names and values; date is cached (8.8 ns) |
| ETag and date formatting | 24.9 ns to render, once per second | Cached |
| Compression | gzip level 4: 207 µs per 50 KiB; Brotli 130 µs | zlib and libcompression are already vectorised internally. Not measured: libcompression's `COMPRESSION_ZLIB` against system zlib for dynamic gzip |

HPACK and HTTP/2 frame benchmarks exist (`HPACKBench.swift`, `H2FrameBench.swift`) but are not registered with `sws-bench micro`, so there are no HPACK numbers in this note.

## Ideas that came out of it

These don't depend on the SIMD code. None is filed yet.

1. **Huffman decode by byte instead of by nibble.** A 256-state by 256-entry table (or a two-symbol-per-lookup table) should roughly halve the 277 ns. This is the biggest remaining CPU item in header decoding for `:path`, `cookie` and other literals.
2. **Huffman encode with 8-byte flushes** into a reserved region instead of four `sink.append` calls per 32 bits.
3. **Register `HPACKBench` and `H2FrameBench` in the micro harness** so HTTP/2 per-request cost can be broken down the way HTTP/1.1 is.
4. **Full SIMD UTF-8 validation** (the simdjson lookup algorithm) for non-ASCII text needs a byte shuffle. That means a small C target using `arm_neon.h`; decide whether a C target fits the zero-dependency rule before starting. Expected gain: CJK from about 0.6 ns/byte to about 0.1.
5. **Benchmark `COMPRESSION_ZLIB` against zlib level 4** for dynamic gzip responses.
6. **Proxy `UpstreamResponseParser`** still parses from `[UInt8]` byte by byte after `findHeadEnd`; it could reuse the request parser's field-value scan.
7. Re-run the pairs in this note on an idle machine and record them under `docs/benchmarks/`.

## Tests run

Debug, filtered, all passing: HTTPCoreTests (187), HTTP1Tests (142), WebSocketsTests (96), ProxyTests (18), SWSBenchTests (31), AuthTests (27), StaticFilesTests (45), CompressionTests (60), HTTPServerTests (17). The full suite, the integration tests and the load benchmarks were not run because other agents were building.
