# HTTP server comparison

- Date: 2026-11-11 19:22 PST, commit b6fc9a6
- Machine: Apple M4 Pro, 12 cores; load average before / after: 6.92 6.30 6.84 / 5.62 7.32 7.41
- Versions: nginx/1.31.8; Apache/2.4.67 (Unix) (event MPM); Caddy v2.11.1; lighttpd/1.4.85; h2o 2.2.6; oha 1.16.0
- Each run: 10s, 626-byte body, loopback; all servers stay up but are measured one at a time. nginx: worker_processes auto, sendfile, open_file_cache, access log off. Apache: event MPM defaults, unlimited keep-alive requests, sendfile, no access log. Caddy: file_server, admin off, no access log. lighttpd: defaults (single process), keep-alive requests raised. h2o: one thread per core.
- New server: `sws-bench serve --root` (StaticFiles #0084, default BSD socket transport) serving the same file from disk; small files are cached in memory with pre-rendered headers and revalidated with stat at most once per second.

| Server | Connections | Concurrency | req/s | p50 ms | p99 ms | p99.9 ms | 200s | errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| new-server | keepalive | 16 | 93,132 | 0.164 | 0.600 | 0.691 | 931,522 | 15 |
| nginx | keepalive | 16 | 81,572 | 0.208 | 0.260 | 0.456 | 815,840 | 16 |
| apache | keepalive | 16 | 52,247 | 0.281 | 0.757 | 1.894 | 522,552 | 15 |
| caddy | keepalive | 16 | 37,605 | 0.344 | 1.837 | 8.104 | 376,138 | 15 |
| lighttpd | keepalive | 16 | 103,737 | 0.148 | 0.284 | 0.924 | 1,037,519 | 13 |
| h2o | keepalive | 16 | 87,251 | 0.179 | 0.269 | 0.369 | 872,629 | 16 |
| new-server | keepalive | 64 | 97,265 | 0.641 | 0.994 | 1.196 | 972,800 | 62 |
| nginx | keepalive | 64 | 81,023 | 0.775 | 1.026 | 1.986 | 810,332 | 63 |
| apache | keepalive | 64 | 55,318 | 0.476 | 12.266 | 22.862 | 553,166 | 82 |
| caddy | keepalive | 64 | 45,487 | 1.027 | 7.193 | 14.171 | 454,894 | 64 |
| lighttpd | keepalive | 64 | 122,251 | 0.504 | 0.982 | 1.271 | 1,222,755 | 63 |
| h2o | keepalive | 64 | 87,459 | 0.727 | 0.847 | 1.771 | 874,663 | 64 |
| new-server | close | 16 | 8,264 | 0.646 | 1.210 | 13.104 | 77,251 | 5434 |
| nginx | close | 16 | 18,880 | 0.787 | 1.347 | 5.516 | 188,814 | 16 |
| apache | close | 16 | 5,434 | 0.878 | 1.880 | 5.625 | 48,845 | 5521 |
| caddy | close | 16 | 4,803 | 0.822 | 2.700 | 45.866 | 41,968 | 6104 |
| lighttpd | close | 16 | 12,353 | 0.577 | 0.897 | 6.035 | 119,582 | 4006 |
| h2o | close | 16 | 11,943 | 0.757 | 2.864 | 18.205 | 117,685 | 1816 |
