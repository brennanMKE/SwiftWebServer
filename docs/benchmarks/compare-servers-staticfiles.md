# HTTP server comparison

- Date: 2026-11-11 15:56 PST, commit 2e512a7
- Machine: Apple M4 Pro, 12 cores; load average before / after: 4.72 11.69 18.12 / 27.56 17.19 17.77
- Versions: nginx/1.31.8; Apache/2.4.67 (Unix) (event MPM); Caddy v2.11.1; lighttpd/1.4.85; h2o 2.2.6; oha 1.16.0
- Each run: 10s, 626-byte body, loopback; all servers stay up but are measured one at a time. nginx: worker_processes auto, sendfile, open_file_cache, access log off. Apache: event MPM defaults, unlimited keep-alive requests, sendfile, no access log. Caddy: file_server, admin off, no access log. lighttpd: defaults (single process), keep-alive requests raised. h2o: one thread per core. Legacy SwiftWebServer closes every connection, so it appears in close mode only.
- New server: `sws-bench serve --root` (StaticFiles #0084, default BSD socket transport) serving the same file from disk; small files are cached in memory with pre-rendered headers and revalidated with stat at most once per second.

| Server | Connections | Concurrency | req/s | p50 ms | p99 ms | p99.9 ms | 200s | errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| new-server | keepalive | 16 | 89,439 | 0.171 | 0.607 | 0.697 | 894,624 | 16 |
| nginx | keepalive | 16 | 79,804 | 0.194 | 0.271 | 0.469 | 798,172 | 16 |
| apache | keepalive | 16 | 53,313 | 0.280 | 0.614 | 1.171 | 533,242 | 14 |
| caddy | keepalive | 16 | 42,140 | 0.338 | 1.134 | 2.490 | 421,465 | 16 |
| lighttpd | keepalive | 16 | 107,091 | 0.146 | 0.245 | 0.325 | 1,071,096 | 15 |
| h2o | keepalive | 16 | 71,811 | 0.204 | 0.534 | 2.400 | 718,272 | 13 |
| new-server | keepalive | 64 | 90,236 | 0.691 | 1.066 | 2.603 | 902,681 | 61 |
| nginx | keepalive | 64 | 74,377 | 0.844 | 1.465 | 4.027 | 743,879 | 60 |
| apache | keepalive | 64 | 49,191 | 0.346 | 24.245 | 83.087 | 491,933 | 89 |
| caddy | keepalive | 64 | 42,907 | 1.094 | 7.545 | 14.880 | 429,100 | 63 |
| lighttpd | keepalive | 64 | 115,349 | 0.539 | 1.020 | 1.627 | 1,153,706 | 59 |
| h2o | keepalive | 64 | 87,367 | 0.728 | 0.921 | 1.731 | 873,822 | 62 |
| new-server | close | 16 | 8,464 | 0.657 | 1.303 | 8.424 | 79,577 | 5082 |
| nginx | close | 16 | 19,385 | 0.777 | 1.003 | 4.752 | 193,869 | 16 |
| apache | close | 16 | 5,452 | 0.870 | 2.416 | 26.564 | 48,456 | 6082 |
| caddy | close | 16 | 3,854 | 0.770 | 1.855 | 21.546 | 31,216 | 7340 |
| lighttpd | close | 16 | 12,411 | 0.617 | 1.439 | 22.816 | 120,634 | 3524 |
| h2o | close | 16 | 10,324 | 0.568 | 4.223 | 24.422 | 101,391 | 1976 |
| legacy | close | 16 | 1,156 | 12.750 | 32.854 | 79.004 | 11,546 | 16 |
