# Performance notes

A summary of what has been measured, with links to the records. All runs are on the owner's
Apple M4 Pro (12 cores) over loopback, with the load client on the same machine and often
other builds running, so treat the numbers as relative, not absolute. Each record lists its
load average and method; the rules for recording are in
[benchmarks/README.md](../benchmarks/README.md).

| Topic | Result | Record |
|---|---|---|
| Static files, keep-alive HTTP/1.1 | About 93k req/s at 16 connections and 97k at 64; second to lighttpd, 14–20% ahead of nginx, ahead of h2o, Apache and Caddy | [SERVER-COMPARISON](../SERVER-COMPARISON.md), [compare-servers-final](../benchmarks/compare-servers-final.md) |
| New connections | About 21.9k/s on the BSD socket listener vs nginx's 18.0k; Network.framework TCP manages about 2.3k/s, which is why cleartext uses BSD sockets | [M3-accept](../benchmarks/M3-accept.md) |
| HTTPS | About 44.6k req/s keep-alive (TLS 1.3 on Network.framework), about a third below cleartext over NW | [M5-tls](../benchmarks/M5-tls.md), [M5-listeners](../benchmarks/M5-listeners.md) |
| HTTP/2 | 374,655 req/s with h2load `-c 16 -m 10` (in-memory body) vs nginx h2c's 135,367; h2spec 146/146 | [M13-h2](../benchmarks/M13-h2.md) |
| Large files | `sendfile(2)`: about 9 GB/s for a cached 512 MiB file; a 1 GiB download keeps RSS flat near 8 MiB | [SERVER-COMPARISON](../SERVER-COMPARISON.md#staticfiles-results-0084) |
| Per-request CPU | Head parse of 10 headers about 133 ns, serialize under 100 ns, zero allocations; a static-file cache hit about 75 ns | [M-final-micro](../benchmarks/M-final-micro.md), [M3-micro](../benchmarks/M3-micro.md) |
| Components | An unregistered component costs nothing; a disabled `if` component about 2 ns; access log and metrics tens of ns; router matching allocation-free | [M4.1-components](../benchmarks/M4.1-components.md), [M6-accesslog](../benchmarks/M6-accesslog.md), [M6-router](../benchmarks/M6-router.md), [M6-vhosts-auth](../benchmarks/M6-vhosts-auth.md) |
| Compression | Level 4 gzip compresses HTML to about Brotli's size at about half level 6's CPU; static variants are compressed once | [M6-compression](../benchmarks/M6-compression.md) |
| Reverse proxy | Adds about 18 µs per request over a warm pool; on par with Apache `mod_proxy` one request at a time (11.6k vs 11.1k req/s), 10–20% behind Apache and nginx under concurrency | [M17-proxy](../benchmarks/M17-proxy.md) |
| WebSockets | permessage-deflate ratio and CPU per message | [M15-websockets](../benchmarks/M15-websockets.md) |
| HTTP/3 | Priorities and the QPACK dynamic table measured; throughput is bounded by Network.framework's per-stream cost (about 590 allocations and 0.4–0.8 ms per stream) | [M10-priorities](../benchmarks/M10-priorities.md), [M10-qpack-dynamic](../benchmarks/M10-qpack-dynamic.md), [QUIC spike](../spikes/quic-spike.md) |

## What this means for configuration

- Keep the default `"transport": "bsd"` for cleartext.
- Leave `http2.cleartext` off unless you need h2c: it makes every cleartext connection sniff
  its first bytes.
- Enable `compression`: static variants are built once, so the per-request cost is a lookup.
- Turn on only the components you use; an unused key costs nothing, a used one costs tens of
  nanoseconds.
- For proxied apps, raise `pool.maxIdle` to your concurrency. The proxy's known cost is the
  per-read timeout race (about 17 allocations and 8–10 µs per request); a kqueue-armed
  deadline is the planned fix.

## Measuring yourself

```bash
swift build -c release -j 2 --product sws-bench
.build/release/sws-bench micro --filter StaticFiles       # ns and allocations per operation
scripts/guarded.sh -t 2400 -- scripts/bench-compare.sh 10 /tmp/compare.md   # vs nginx etc. (needs them installed)
scripts/guarded.sh -t 600 -- scripts/bench-proxy.sh 5 1 16 64               # proxy vs Apache and nginx
```

Record the load average with every result, and run on an idle machine before quoting numbers.
