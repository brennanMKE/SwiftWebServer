# Progress

Milestone status for docs/ROADMAP.md. Updated by the orchestrator at each milestone check (`scripts/milestone-check.sh MN`).

| Milestone | Status | Issues | Check |
|---|---|---|---|
| M0 Ground | done except #0072 (local CA needs the owner) | #0069 #0070 #0071 resolved | QUIC spike: conditional GO |
| M1 Bytes and HTTP/1.1 codec | **done** 2026-11-11 | #0073–#0076 resolved; perf follow-up #0112 | 567 debug / 566 release tests; [M1-micro](benchmarks/M1-micro.md) |
| M2 Transport and lifecycle | **done** 2026-11-11 | #0077–#0079 resolved | checked with M3 |
| M3 HTTP/1.1 connections | **done** 2026-11-11 | #0080–#0082 resolved; #0112 #0114 resolved; #0113 in progress | 781 debug / 780 release tests; [M3-micro](benchmarks/M3-micro.md); [server comparison](SERVER-COMPARISON.md) |
| M4 Components, StaticFiles, cut-over | **done** 2026-11-11 | #0083–#0086 resolved; Legacy deleted | 929 debug / 928 release tests; [M4-micro](benchmarks/M4-micro.md); [M4-cutover](benchmarks/M4-cutover.md) |
| M5 TLS and protocol registry | **done** | #0087–#0089 resolved; #0118 documented (no TLS half-close in NW) | HTTPS about 43k req/s keep-alive |
| M6 Small components | **done** | #0090–#0094 resolved | AccessLog, Compression, VirtualHosts, Auth, Router |
| M7 Pure codecs (h3) | done (early) | #0095–#0097 resolved | — |
| M8 QUIC transport | **done** | #0098 #0099 resolved | — |
| M9 HTTP/3 MVP | **done** | #0100–#0103 resolved | shipped binary serves h3 + Alt-Svc |
| M11 HTTP/2 codecs | done (early) | #0034 #0036 #0039–#0041 resolved | — |
| M10 HTTP/3 hardening | mostly done | #0104 #0107 resolved; #0105 (browser interop) needs local CA; #0106 QPACK dynamic table optional | close code never reaches wire (NW limitation) |
| M12 HTTP/2 connections | **done** | #0042–#0052 resolved | — |
| M13 HTTP/2 flow control and conformance | **done** | #0053–#0056, #0061, #0065, #0119 resolved; #0062 browser interop needs local CA | h2spec 146/146; h2load 375k req/s |
| M14 WebSockets | **done** | #0108 #0109 #0116 #0117 resolved | URLSession echo |
| M15 WebSockets extensions | **done** | #0067 #0110 #0111 resolved | WS over h1, h2, h3; permessage-deflate |

M1 numbers (load average about 27 during the run, so treat them as upper bounds): parse.head 10 headers 369 ns, serialize 5 headers 74 ns, 10 headers 106 ns, all with 0 allocations.

M3 numbers (load average about 8–34): parse.head 10 headers 133 ns (was 369 ns at M1, #0112), serialize 5 headers 79 ns, all with 0 allocations. Keep-alive hello world is about 63k req/s, within 4% of nginx (see SERVER-COMPARISON.md).

## End of day 2026-11-11

Final check at b6fc9a6: 1479 debug and 1478 release tests pass ([M-final-micro](benchmarks/M-final-micro.md)). Server comparison: [SERVER-COMPARISON.md](SERVER-COMPARISON.md).

Remaining:
- **M17 Reverse proxy** (#0120–#0124): filed 2026-11-11, not started. A static site at `/` plus path prefixes such as `/cgi-bin` proxied to localhost apps.
- #0072 local CA, #0062 and #0105 browser interop: need the owner to trust a local CA by hand.
- #0106 QPACK dynamic table (optional).
- Proposed M16 performance milestone (awaiting owner): CPU-per-request metric, same-thread executor resume, SO_REUSEPORT per-core listeners, writev, full-response cache, specialized protocol runners (#0083 boundary cost).
- Legacy issues 0001–0060 superseded by the new issues are still `open`; they need an owner pass to close them.
