# M-final micro benchmarks

- Date: 2026-11-11 19:16 PST
- Commit: b6fc9a6
- Machine: Apple M4 Pro, 12 cores
- Load average before / after: 7.27 6.36 6.86 / 6.92 6.30 6.84
- Tests: 1479 passed (debug), 1478 passed (release)

```
benchmark                                        min ns  median ns     p99 ns  allocs/op  retained    batch
harness.noop                                       0.83       0.97       1.44       0.00      0.00    40000
harness.allocateObject                            26.19      29.95      41.72       1.00      0.00      996
fields.fill+clear 10-header request               77.64        117        135       0.00      0.00      432
fields.scan+hash+fill 10-header request             239        248        282       0.00      0.00      187
fields.lookupWellKnown                            10.00      10.02      10.67       0.00      0.00     4301
fields.lookupUnknown                              10.25      10.50      11.03       0.00      0.00     4781
fields.firstValue(host)                           12.36      12.52      13.22       0.00      0.00     3871
fields.containsMiss                                7.16       7.20       9.33       0.00      0.00     6629
fields.contentLength                              17.29      17.39      23.94       0.00      0.00     2684
fields.methodParseGET                             14.56      14.59      16.35       0.00      0.00     3287
fields.statusLine200                              13.96      14.00      14.93       0.00      0.00     3324
fields.response 5 static + removeAll              39.65      39.82      44.33       0.00      0.00     1221
parse.head 10-header browser request                130        130        145       0.00      0.00      374
parse.head minimal request                        27.20      27.27      29.17       0.00      0.00     1780
parse.head into HTTPRequestStorage                  142        143        151       0.00      0.00      345
serialize.200 5-header 9-byte body                70.01      74.90      78.51       0.00      0.00      682
serialize.200 10-header 9-byte body                 102        110        117       0.00      0.00      466
serialize.200 5-header chunked head               67.55      71.53      81.37       0.00      0.00      697
serialize.304 2-header                            29.97      32.56      45.73       0.00      0.00     1500
serialize.chunk 9-byte                            18.16      23.40      33.11       0.00      0.00     2083
date.clock_gettime                                15.35      15.59      22.07       0.00      0.00     3149
date.refresh same second                           8.89       8.91      10.30       0.00      0.00     5529
date.render                                       22.70      24.57      33.32       0.00      0.00     1595
StaticFiles.hit 626-byte index.html               75.50      80.75      85.94       0.00      0.00       16
StaticFiles.hit directory index                   66.05      68.28      82.35       0.00      0.00      487
StaticFiles.hit 1 MiB file region                 79.18      80.98      85.16       0.00      0.00      461
StaticFiles.hit percent-encoded path              93.14      97.26        105       0.00      0.00      395
StaticFiles.range 0-99 of 626 bytes                 234        238        288       7.00      0.02      181
StaticFiles.304 If-None-Match                       152        164        180       0.00      0.00      301
StaticFiles.304 If-None-Match list                  204        207        240       0.00      0.00      240
StaticFiles.304 If-Modified-Since                   100        103        115       0.00      0.00      476
StaticFiles.304 If-None-Match 1 MiB file            146        152        181       0.00      0.00      297
StaticFiles.200 If-None-Match stale                 120        121        134       0.00      0.00      409
Compression.hit 50 KiB html, no precompression       77.39      81.86      87.79       0.00      0.00       28
Compression.hit 50 KiB html, precompressed, identity       75.43      81.38      87.29       0.00      0.00       21
Compression.hit 50 KiB html, precompressed, browser header (smallest variant)         105        106        116       0.00      0.00      464
Compression.hit 50 KiB html, precompressed, br variantWebSocket.deflate JSON message, level 1, context takeover: 1000 messages, 123698 → 31747 bytes, ratio 0.257
WebSocket.deflate JSON message, level 6 (default), context takeover: 1000 messages, 123698 → 23374 bytes, ratio 0.189
WebSocket.deflate JSON message, level 9, context takeover: 1000 messages, 123698 → 22375 bytes, ratio 0.181
WebSocket.deflate JSON message, level 6, no context takeover: 1000 messages, 123698 → 106517 bytes, ratio 0.861
WebSocket.deflate JSON message, level 6, window 2^10, context takeover: 1000 messages, 123698 → 35769 bytes, ratio 0.289
       90.00      90.99        101       0.00      0.00      550
Compression.hit 50 KiB html, precompressed, gzip variant       96.64        100        117       0.00      0.00      501
Compression.304 50 KiB html, br variant             179        192        210       0.00      0.00      245
Compression.negotiate "gzip, deflate, br, zstd"       39.02      39.11      45.88       0.00      0.00      930
Compression.negotiate "br;q=1.0, gzip;q=0.8, *;q=0.1"       44.80      45.33      49.72       0.00      0.00     1025
Compression.dynamic br 50 KiB html               129041     129541     139583      16.00      0.00        1
Compression.dynamic gzip level 4 50 KiB html      205250     207104     243811       8.00      0.00        1
Compression.dynamic gzip level 1 50 KiB html       84500      85333      92492       8.00      0.00        1
Compression.dynamic gzip level 6 50 KiB html      798000     817042     957247       8.00      0.00        1
Compression.dynamic deflate level 4 50 KiB html      176250     177458     208358       8.00      0.00        1
Compression.skip image/png                        63.09      64.46      71.98       0.00      0.00      638
Compression.skip identity (no coding accepted)         169        172        188       4.00      0.00      275
Router.match static hit                           34.62      35.34      41.34       0.00      0.00     1377
Router.match param hit                            41.67      42.27      48.54       0.00      0.00     1165
Router.match param hit + decimal(id)              56.10      56.50      67.91       0.00      0.00      635
Router.match HEAD via GET                         45.19      46.31      54.60       0.00      0.00     1077
Router.match miss (fall through)                  16.55      16.58      18.64       0.00      0.00     2797
Router.match miss under prefix                    27.57      27.73      33.00       0.00      0.00     1764
Router.match 405                                  74.87      75.52      89.61       0.00      0.00      645
VirtualHosts.route exact                          30.62      30.69      36.90       0.00      0.00     1135
VirtualHosts.route exact + port, mixed case       36.67      37.87      45.17       0.00      0.00     1310
VirtualHosts.route wildcard                       39.51      41.08      49.54       0.00      0.00     1200
VirtualHosts.route unknown -> default             24.21      24.34      31.50       0.00      0.00     1996
Auth outside every policy (pass-through)          36.54      37.84      45.01       0.00      0.00     1251
Auth Bearer JWT HS256 verify                        790        800        937       0.00      0.00       59
Auth Bearer static token                            205        214        262       0.00      0.00      229
Auth Basic (verified-value cache hit)               327        334        391       0.00      0.00      150
Auth Basic PBKDF2 1,000 iterations (no cache)      133625     145500     176822       0.00      0.00        1
Auth missing credentials (401)                    33.83      35.61      38.84       0.00      0.00     1355
Auth JWTVerifier.verify only                        738        753        834       0.00      0.00       66
WebSocket.deflate JSON message, level 1, context takeover        1535       1764       3306       0.00      0.00       12
WebSocket.deflate JSON message, level 6 (default), context takeover        2116       2528       4500       0.00      0.00        9
WebSocket.deflate JSON message, level 9, context takeover        3729       6214      10270       0.00      0.00        4
WebSocket.deflate JSON message, level 6, no context takeover        4802       5208       6096       0.00      0.00        4
WebSocket.deflate JSON message, level 6, window 2^10, context takeover        2035       3719       4501       0.00      0.00        6
WebSocket.inflate JSON message, context takeover         182        206        344       0.00      0.00       16
WebSocket.inflate JSON message, no context takeover         333        631       1173       0.00      0.00        7
bytebuffer: bytebuffer.append decimal              8.75       8.75       8.75        n/a       n/a     self
bytebuffer: bytebuffer.append+parse decimal       29.47      29.47      29.47        n/a       n/a     self
bytebuffer: bytebuffer.append+parse hex           29.97      29.97      29.97        n/a       n/a     self
bytebuffer: bytebuffer.append static+discard        6.35       6.35       6.35        n/a       n/a     self
bytebuffer: ascii.fnv1a header name                4.45       4.45       4.45        n/a       n/a     self
huffman: huffman.decode                             281        281        281        n/a       n/a     self
huffman: huffman.encode                             342        342        342        n/a       n/a     self
qpack: qpack.decode                                 680        680        680        n/a       n/a     self
qpack: qpack.encode                                 986        986        986        n/a       n/a     self
h3frame: h3frames.parse.whole (per frame)         12.85      12.85      12.85        n/a       n/a     self
h3frame: h3frames.parse.chunked37 (per frame)       42.97      42.97      42.97        n/a       n/a     self

allocs/op: malloc_logger hook, available; retained: malloc_zone_statistics blocks_in_use delta per op
```
