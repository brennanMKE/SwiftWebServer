# M10 — QPACK dynamic table (#0106)

Decoder-side QPACK dynamic table. It is off by default (`H3Configuration.qpackMaxTableCapacity
= 0`), so the static-only decoding path must not change. `qpack.decode.dynamic` is new: it
decodes the same 10-field request with every field taken from the dynamic table (Indexed
Field Lines), including taking the queued Section Acknowledgment.

```bash
swift build -c release -j 2 --product sws-bench
scripts/guarded.sh -t 300 -- .build/release/sws-bench micro --filter q        # qpack suite
scripts/guarded.sh -t 300 -- .build/release/sws-bench micro --filter h3frame
```

## Setup

- 2026-11-12, Apple M4 Pro (12 cores), release build, branch `m10-0106` on 69846cd.
- Load average before / after: 3.71 3.78 4.06 / 3.59 3.75 4.04 (another agent was working).
- Three runs; the median is shown. Previous record: `M-final-micro.md` (load 7.27 / 6.92).

## Results (ns per field section or frame)

| Benchmark | Runs | Median | M-final | Change |
|---|---|---|---|---|
| `qpack.decode` (static only) | 661 / 665 / 659 | 661 | 680 | −2.8% |
| `qpack.encode` | 955 / 954 / 959 | 955 | 986 | −3.1% |
| `qpack.decode.dynamic` (new) | 114 / 116 / 114 | 114 | — | — |
| `h3frames.parse.whole` | 11.83 / 11.87 / 12.01 | 11.87 | 12.85 | −7.6% |
| `h3frames.parse.chunked37` | 41.45 / 41.55 / 41.70 | 41.55 | 42.97 | −3.3% |

- The static-only decoder (`QPACKDecoder`) is unchanged source; the differences against
  M-final are the lower machine load, not this change (no regression).
- With the table in use a request head decodes about 6× faster in this benchmark: dynamic
  entries are passed straight out of the table's arena, with no Huffman decoding. The cost
  is a `Mutex` per field section and connection-shared state, which is why it stays opt-in.
