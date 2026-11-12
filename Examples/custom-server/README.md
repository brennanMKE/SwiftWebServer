# custom-server: compose only the components you need

A separate Swift package that depends on SwiftWebServer's library products by path and builds
a server with `StaticFiles`, a `Router` JSON API, a `WebSocketUpgrade` echo, `Compression` and
`AccessLog`, over HTTP/1.1 on loopback. It is not part of the main package's build.

```bash
cd Examples/custom-server
swift build -j 2
.build/debug/MySite ../../Root/Public 8080      # ROOT [PORT]
curl http://127.0.0.1:8080/api/hello/swift       # {"hello": "swift"}
curl -X POST --data ping http://127.0.0.1:8080/api/echo
curl http://127.0.0.1:8080/                      # Root/Public/index.html
# Ctrl-C drains open connections and exits 0
```

The code is explained in [docs/guide/choosing-components.md](../../docs/guide/choosing-components.md#a-custom-server-package).
