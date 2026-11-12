# Progress

Milestone status for docs/ROADMAP.md. Updated by the orchestrator at each milestone check (`scripts/milestone-check.sh MN`).

| Milestone | Status | Issues | Check |
|---|---|---|---|
| M0 Ground | done except #0072 (local CA needs the owner) | #0069 #0070 #0071 resolved | QUIC spike: conditional GO |
| M1 Bytes and HTTP/1.1 codec | **done** 2026-11-11 | #0073–#0076 resolved; perf follow-up #0112 | 567 debug / 566 release tests; [M1-micro](benchmarks/M1-micro.md) |
| M2 Transport and lifecycle | **done** 2026-11-11 | #0077–#0079 resolved | checked with M3 |
| M3 HTTP/1.1 connections | **done** 2026-11-11 | #0080–#0082 resolved; #0112 #0114 resolved; #0113 in progress | 781 debug / 780 release tests; [M3-micro](benchmarks/M3-micro.md); [server comparison](SERVER-COMPARISON.md) |
| M4 Components, StaticFiles, cut-over | **done** 2026-11-11 | #0083–#0086 resolved; Legacy deleted | 929 debug / 928 release tests; [M4-micro](benchmarks/M4-micro.md); [M4-cutover](benchmarks/M4-cutover.md) |
| M5 TLS and protocol registry | in progress | #0087 #0088 resolved; #0089 next | HTTPS 44.6k req/s keep-alive |
| M6 Small components | in progress | #0090 in progress | — |
| M7 Pure codecs (h3) | done (early) | #0095–#0097 resolved | — |
| M8 QUIC transport | **done** | #0098 #0099 resolved | — |
| M9 HTTP/3 MVP | in progress | #0100–#0102 resolved; #0103 Alt-Svc next | curl --http3-only works |
| M11 HTTP/2 codecs | done (early) | #0034 #0036 #0039–#0041 resolved | — |
| M12 HTTP/2 connections | in progress | #0045 #0046 resolved; #0042–#0044 in progress | — |

M1 numbers (load average about 27 during the run, so treat them as upper bounds): parse.head 10 headers 369 ns, serialize 5 headers 74 ns, 10 headers 106 ns, all with 0 allocations.

M3 numbers (load average about 8–34): parse.head 10 headers 133 ns (was 369 ns at M1, #0112), serialize 5 headers 79 ns, all with 0 allocations. Keep-alive hello world is about 63k req/s, within 4% of nginx (see SERVER-COMPARISON.md).
