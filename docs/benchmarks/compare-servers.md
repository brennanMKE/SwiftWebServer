# HTTP server comparison

- Date: 2026-11-11 14:45 PST, commit 6bd196a
- Machine: Apple M4 Pro, 12 cores; load average before / after: 9.91 10.09 9.00 / 9.23 15.37 13.07
- Versions: nginx/1.31.8; Apache/2.4.67 (Unix) (event MPM); Caddy v2.11.1; lighttpd/1.4.85; h2o 2.2.6; oha 1.16.0
- Each run: 10s, 626-byte body, loopback; all servers stay up but are measured one at a time. nginx: worker_processes auto, sendfile, open_file_cache, access log off. Apache: event MPM defaults, unlimited keep-alive requests, sendfile, no access log. Caddy: file_server, admin off, no access log. lighttpd: defaults (single process), keep-alive requests raised. h2o: one thread per core. Legacy SwiftWebServer closes every connection, so it appears in close mode only.
- Caveat: the new server answers from memory until StaticFiles (#0084); nginx and Apache read the file (page cache).

| Server | Connections | Concurrency | req/s | p50 ms | p99 ms | p99.9 ms | 200s | errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| new-server | keepalive | 16 | 63,416 | 0.244 | 0.624 | 0.779 | 634,330 | 15 |
| nginx | keepalive | 16 | 65,615 | 0.233 | 0.422 | 0.732 | 656,348 | 13 |
| apache | keepalive | 16 | 43,003 | 0.310 | 1.596 | 6.400 | 430,100 | 12 |
| caddy | keepalive | 16 | 34,997 | 0.345 | 2.347 | 9.361 | 350,050 | 15 |
| lighttpd | keepalive | 16 | 75,909 | 0.188 | 0.621 | 1.682 | 759,299 | 12 |
| h2o | keepalive | 16 | 72,606 | 0.209 | 0.404 | 0.749 | 726,155 | 16 |
| new-server | keepalive | 64 | 61,685 | 1.039 | 1.438 | 2.374 | 616,922 | 62 |
| nginx | keepalive | 64 | 64,604 | 0.981 | 1.903 | 6.624 | 646,171 | 63 |
| apache | keepalive | 64 | 46,199 | 0.410 | 23.091 | 60.004 | 461,984 | 90 |
| caddy | keepalive | 64 | 37,351 | 1.207 | 10.511 | 21.160 | 373,553 | 63 |
| lighttpd | keepalive | 64 | 79,312 | 0.763 | 1.985 | 4.154 | 793,174 | 63 |
| h2o | keepalive | 64 | 71,837 | 0.854 | 2.413 | 20.751 | 718,563 | 62 |
| new-server | close | 16 | 2,266 | 6.394 | 14.634 | 25.336 | 22,647 | 16 |
| nginx | close | 16 | 21,344 | 0.589 | 3.064 | 12.951 | 213,479 | 15 |
| apache | close | 16 | 7,384 | 0.822 | 3.763 | 10.558 | 71,118 | 2808 |
| caddy | close | 16 | 5,329 | 0.819 | 7.118 | 24.307 | 49,813 | 3523 |
| lighttpd | close | 16 | 10,845 | 0.685 | 1.349 | 17.918 | 105,418 | 3138 |
| h2o | close | 16 | 9,498 | 0.907 | 1.777 | 27.294 | 92,779 | 2361 |
| legacy | close | 16 | 2,518 | 6.785 | 18.451 | 385.682 | 16,373 | 8818 |
