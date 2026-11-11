# M1 micro benchmarks

- Date: 2026-11-11 13:55 PST
- Commit: 0d07493
- Machine: Apple M4 Pro, 12 cores
- Load average before / after: 28.58 22.66 28.17 / 26.62 22.35 28.03
- Tests: 567 passed (debug), 566 passed (release)

```
benchmark                                        min ns  median ns     p99 ns  allocs/op  retained    batch
harness.noop                                       0.75       0.76       0.81       0.00      0.00    60024
harness.allocateObject                            21.76      21.93      29.18       1.00      0.00     1465
fields.fill+clear 10-header request                 169        203        204       0.00      0.00      243
fields.scan+hash+fill 10-header request             326        332        351       0.00      0.00      148
fields.lookupWellKnown                            12.59      12.78      13.51       0.00      0.00     3669
fields.lookupUnknown                               8.40       8.52       9.13       0.00      0.00     5797
fields.firstValue(host)                           17.57      18.39      20.02       0.00      0.00     2597
fields.containsMiss                                7.16       7.27       7.81       0.00      0.00     6522
fields.contentLength                              34.99      35.86      39.08       0.00      0.00      998
fields.methodParseGET                             14.99      15.29      16.12       0.00      0.00     3243
fields.statusLine200                              13.49      13.51      14.36       0.00      0.00     3157
fields.response 5 static + removeAll              59.05      61.39      67.24       0.00      0.00      810
parse.head 10-header browser request                368        369        405       0.00      0.00      131
parse.head minimal request                        66.66      66.95      73.46       0.00      0.00      717
parse.head into HTTPRequestStorage                  391        392        429       0.00      0.00      123
serialize.200 5-header 9-byte body                68.06      73.83      86.29       0.00      0.00      570
serialize.200 10-header 9-byte body                 102        106        111       0.00      0.00      471
serialize.200 5-header chunked head               63.69      78.66      83.71       0.00      0.00      611
serialize.304 2-header                            29.93      30.74      32.11       0.00      0.00     1583
serialize.chunk 9-byte                            19.08      22.17      23.65       0.00      0.00     1898
date.clock_gettime                                15.43      15.50      16.92       0.00      0.00     3022
date.refresh same second                           9.16       9.18      10.23       0.00      0.00     4938
date.render                                       23.91      25.78      34.36       0.00      0.00     1528
bytebuffer: bytebuffer.append decimal              8.73       8.73       8.73        n/a       n/a     self
bytebuffer: bytebuffer.append+parse decimal       30.21      30.21      30.21        n/a       n/a     self
bytebuffer: bytebuffer.append+parse hex           31.91      31.91      31.91        n/a       n/a     self
bytebuffer: bytebuffer.append static+discard        6.62       6.62       6.62        n/a       n/a     self
bytebuffer: ascii.fnv1a header name                4.48       4.48       4.48        n/a       n/a     self
huffman: huffman.decode                             287        287        287        n/a       n/a     self
huffman: huffman.encode                             345        345        345        n/a       n/a     self
qpack: qpack.decode                                 698        698        698        n/a       n/a     self
qpack: qpack.encode                                1004       1004       1004        n/a       n/a     self
h3frame: h3frames.parse.whole (per frame)         10.50      10.50      10.50        n/a       n/a     self
h3frame: h3frames.parse.chunked37 (per frame)       41.54      41.54      41.54        n/a       n/a     self

allocs/op: malloc_logger hook, available; retained: malloc_zone_statistics blocks_in_use delta per op
```
