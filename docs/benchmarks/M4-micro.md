# M4 micro benchmarks

- Date: 2026-11-11 16:35 PST
- Commit: 372e5b6
- Machine: Apple M4 Pro, 12 cores
- Load average before / after: 5.51 8.59 11.59 / 5.51 8.59 11.59
- Tests: 929 passed (debug), 928 passed (release)

```
benchmark                                        min ns  median ns     p99 ns  allocs/op  retained    batch
harness.noop                                       1.05       1.15       1.28       0.00      0.00    33333
harness.allocateObject                            26.03      29.71      37.35       1.00      0.00     1255
fields.fill+clear 10-header request               79.76        110        121       0.00      0.00      455
fields.scan+hash+fill 10-header request             246        253        289       0.00      0.00      189
fields.lookupWellKnown                            10.12      10.24      11.33       0.00      0.00     4379
fields.lookupUnknown                              10.13      10.14      10.83       0.00      0.00     4838
fields.firstValue(host)                           12.57      12.64      14.36       0.00      0.00     1754
fields.containsMiss                                7.16       7.17       7.95       0.00      0.00     6818
fields.contentLength                              18.34      18.53      19.88       0.00      0.00     2631
fields.methodParseGET                             14.38      14.52      15.37       0.00      0.00     3314
fields.statusLine200                              12.63      13.94      16.22       0.00      0.00     3333
fields.response 5 static + removeAll              38.93      40.09      46.74       0.00      0.00     1202
parse.head 10-header browser request                130        132        148       0.00      0.00      362
parse.head minimal request                        27.97      28.36      31.35       0.00      0.00     1719
parse.head into HTTPRequestStorage                  143        144        161       0.00      0.00      339
serialize.200 5-header 9-byte body                72.60      75.98      87.05       0.00      0.00      652
serialize.200 10-header 9-byte body                 106        114        136       0.00      0.00      446
serialize.200 5-header chunked head               67.43      77.37      85.37       0.00      0.00      681
serialize.304 2-header                            28.96      29.56      32.01       0.00      0.00     1325
serialize.chunk 9-byte                            18.52      19.28      25.32       0.00      0.00     2531
date.clock_gettime                                15.46      15.59      16.57       0.00      0.00     3108
date.refresh same second                           9.14       9.15       9.74       0.00      0.00     5405
date.render                                       22.86      24.21      33.06       0.00      0.00     1511
StaticFiles.hit 626-byte index.html               71.72      78.67      83.33       0.00      0.00       18
StaticFiles.hit directory index                   64.04      64.77      68.15       0.00      0.00      460
StaticFiles.hit 1 MiB file region                 74.93      77.85      84.09       0.00      0.00      441
StaticFiles.hit percent-encoded path              90.01      90.65      95.77       0.00      0.00      393
StaticFiles.range 0-99 of 626 bytes                 232        241        277       7.00      0.02      181
StaticFiles.304 If-None-Match                       161        161        172       0.00      0.00      284
StaticFiles.304 If-None-Match list                  222        224        249       0.00      0.00      219
StaticFiles.304 If-Modified-Since                 95.38      96.03        107       0.00      0.00      512
StaticFiles.304 If-None-Match 1 MiB file            153        154        180       0.00      0.00      319
StaticFiles.200 If-None-Match stale                 125        127        136       0.00      0.00      381
bytebuffer: bytebuffer.append decimal              9.64       9.64       9.64        n/a       n/a     self
bytebuffer: bytebuffer.append+parse decimal       29.36      29.36      29.36        n/a       n/a     self
bytebuffer: bytebuffer.append+parse hex           31.90      31.90      31.90        n/a       n/a     self
bytebuffer: bytebuffer.append static+discard        6.21       6.21       6.21        n/a       n/a     self
bytebuffer: ascii.fnv1a header name                4.40       4.40       4.40        n/a       n/a     self
huffman: huffman.decode                             280        280        280        n/a       n/a     self
huffman: huffman.encode                             345        345        345        n/a       n/a     self
qpack: qpack.decode                                 688        688        688        n/a       n/a     self
qpack: qpack.encode                                1005       1005       1005        n/a       n/a     self
h3frame: h3frames.parse.whole (per frame)          9.58       9.58       9.58        n/a       n/a     self
h3frame: h3frames.parse.chunked37 (per frame)       40.65      40.65      40.65        n/a       n/a     self

allocs/op: malloc_logger hook, available; retained: malloc_zone_statistics blocks_in_use delta per op
```
