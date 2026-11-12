# SwiftWebServer guide

How SwiftWebServer is put together, how to pick the parts you need, and how to run it on a Mac
for static and dynamic websites.

| Guide | Read it for |
|---|---|
| [Overview and architecture](overview.md) | Core vs optional components, HTTP/1.1, HTTP/2 and HTTP/3, the transports, the handler chain and its order |
| [Choosing components](choosing-components.md) | Every target and product, what it depends on and when to include it; building your own server as a Swift package |
| [Running on a Mac](running-on-a-mac.md) | Release builds, the complete `http-config.json` reference, TLS certificates, public binding, the firewall prompt, ports 80/443, LaunchAgents, logs, shutdown |
| [Static websites](static-sites.md) | StaticFiles, error pages, compression, caching and conditional requests, Range, virtual hosts, authentication |
| [Dynamic websites](dynamic-sites.md) | In-process Swift with Router and WebSockets; reverse proxy to local apps (Go example, Laya decision server); Apache `mod_proxy` mapping; production checklist |
| [Performance notes](performance.md) | What the benchmarks say, with links to the records |

Quick start, from the repository root:

```bash
swift build -c release -j 2 --product SwiftWebServer
.build/release/SwiftWebServer --config Root/http-config.json   # serves Root/Public
curl http://127.0.0.1:8080/
```

Other references: [ROADMAP.md](../ROADMAP.md) (the design, authoritative),
[MIDDLEWARE.md](../MIDDLEWARE.md) (the middleware builder in depth),
[SERVER-COMPARISON.md](../SERVER-COMPARISON.md) and [benchmarks/](../benchmarks/README.md).
