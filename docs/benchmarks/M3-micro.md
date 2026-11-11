# M3 micro benchmarks

- Date: 2026-11-11 15:28 PST
- Commit: 9a58ff3
- Machine: Apple M4 Pro, 12 cores
- Load average before / after: 8.19 34.09 37.53 / 8.57 33.74 37.39
- Tests: 781 passed (debug), 780 passed (release)

```
benchmark                                        min ns  median ns     p99 ns  allocs/op  retained    batch
harness.noop                                       0.74       0.74       1.08       0.00      0.00    48030
harness.allocateObject                            21.23      21.65      28.99       1.00      0.00     1680
fields.fill+clear 10-header request               67.54      95.58        122       0.00      0.00      517
fields.scan+hash+fill 10-header request             227        233        307       0.00      0.00      205
fields.lookupWellKnown                            10.86      11.00      14.59       0.00      0.00     4411
fields.lookupUnknown                              10.12      10.27      13.59       0.00      0.00     4705
fields.firstValue(host)                           12.84      12.89      17.95       0.00      0.00     3157
fields.containsMiss                                7.16       7.19      10.81       0.00      0.00     5633
fields.contentLength                              17.78      19.07      25.53       0.00      0.00     2580
fields.methodParseGET                             14.36      14.64      20.33       0.00      0.00     3278
fields.statusLine200                              12.84      13.04      17.57       0.00      0.00     3458
fields.response 5 static + removeAll              38.75      41.74      59.87       0.00      0.00     1143
parse.head 10-header browser request                129        133        195       0.00      0.00      370
parse.head minimal request                        27.60      28.82      38.53       0.00      0.00     1671
parse.head into HTTPRequestStorage                  141        147        195       0.00      0.00      327
serialize.200 5-header 9-byte body                71.03      78.82        119       0.00      0.00      498
serialize.200 10-header 9-byte body                 104        111        168       0.00      0.00      452
serialize.200 5-header chunked head               68.57      74.78        103       0.00      0.00      697
serialize.304 2-header                            28.81      34.70      60.54       0.00      0.00     1501
serialize.chunk 9-byte                            18.28      19.90      26.12       0.00      0.00     2033
date.clock_gettime                                15.57      15.93      21.85       0.00      0.00     2135
date.refresh same second                           8.89       9.19      12.16       0.00      0.00     4799
date.render                                       22.97      24.91      32.89       0.00      0.00     1524
bytebuffer: bytebuffer.append decimal              8.65       8.65       8.65        n/a       n/a     self
bytebuffer: bytebuffer.append+parse decimal       32.24      32.24      32.24        n/a       n/a     self
bytebuffer: bytebuffer.append+parse hex           35.50      35.50      35.50        n/a       n/a     self
bytebuffer: bytebuffer.append static+discard        6.57       6.57       6.57        n/a       n/a     self
bytebuffer: ascii.fnv1a header name                4.53       4.53       4.53        n/a       n/a     self
huffman: huffman.decode                             305        305        305        n/a       n/a     self
huffman: huffman.encode                             368        368        368        n/a       n/a     self
qpack: qpack.decode                                 731        731        731        n/a       n/a     self
qpack: qpack.encode                                1093       1093       1093        n/a       n/a     self
h3frame: h3frames.parse.whole (per frame)         10.85      10.85      10.85        n/a       n/a     self
h3frame: h3frames.parse.chunked37 (per frame)       42.91      42.91      42.91        n/a       n/a     self

allocs/op: malloc_logger hook, available; retained: malloc_zone_statistics blocks_in_use delta per op
```
