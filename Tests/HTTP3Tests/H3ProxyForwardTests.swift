import HTTP1
import HTTP3
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Proxy
import Testing

// #0121: requests arriving over HTTP/3 are forwarded upstream as HTTP/1.1 and the answer goes
// back over HTTP/3.

/// Echoes what the upstream received: the request line, every field, then the body.
private struct UpstreamEchoHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var text = "\(request.method) \(request.string(of: request.path))"
        if !request.query.isEmpty { text += "?" + request.string(of: request.query) }
        text += " HTTP/\(request.version.major).\(request.version.minor)\n"
        let h = request.headers
        for i in 0..<h.count { text += "\(h.nameString(at: i).lowercased()): \(h.valueString(at: i))\n" }
        var body: [UInt8] = []
        for try await chunk in request.body { chunk.withUnsafeReadableBytes { body.append(contentsOf: $0) } }
        text += "\n" + String(decoding: body, as: UTF8.self)
        var headers = HTTPFields()
        headers.append(name: "X-Upstream", value: "h1")
        headers.append(name: "Keep-Alive", value: "timeout=5")
        return HTTPResponse(status: .ok, headers: headers, body: .bytes(ByteBuffer(bytes: Array(text.utf8))))
    }
}

private func withProxiedEchoUpstream(
    _ body: @Sendable (MiddlewareChain<ReverseProxy, PathHandler>) async throws -> Void
) async throws {
    let listener = try TCPListener(configuration: TCPListener.Configuration(
        host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
    let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                        listeners: [listener], protocols: [HTTP1()]) {
        UpstreamEchoHandler()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await server.run() }
        defer { server.requestShutdown() }
        let port = try #require(try await server.waitUntilRunning().first?.port)
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [ProxyMount(
            path: "/api", upstreams: [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port))],
            stripPrefix: true)], client: client)
        try await body(MiddlewareChain(middleware: proxy, next: PathHandler()))
        await client.shutdown()
        server.requestShutdown()
        try await group.waitForAll()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct H3ProxyForwardTests {
    @Test func getIsForwardedAsHTTP11() async throws {
        try await withProxiedEchoUpstream { chain in
            try await withH3Server(handler: chain) { client, _ in
                let h3 = H3TestClient(transport: client)
                let response = try await h3.send(H3Wire.request(path: "/api/echo?x=1", authority: "app.example",
                                                                extra: [("x-client", "1")]))
                #expect(response.status == "200")
                #expect(response.header("x-upstream") == "h1")
                #expect(response.header("keep-alive") == nil)
                let seen = response.bodyString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                #expect(seen.first == "GET /echo?x=1 HTTP/1.1")
                #expect(seen.contains { $0.hasPrefix("host: 127.0.0.1:") })
                #expect(seen.contains("x-client: 1"))
                #expect(seen.contains("x-forwarded-host: app.example"))
                #expect(seen.contains("x-forwarded-prefix: /api"))
                #expect(seen.contains { $0.hasPrefix("x-forwarded-proto: ") })
                #expect(!seen.contains { $0.hasPrefix(":") })
            }
        }
    }

    @Test func postBodyIsForwarded() async throws {
        try await withProxiedEchoUpstream { chain in
            try await withH3Server(handler: chain) { client, _ in
                let h3 = H3TestClient(transport: client)
                let response = try await h3.send(H3Wire.request(method: "POST", path: "/api/submit",
                                                                extra: [("content-length", "11")]),
                                                 body: Array("hello there".utf8))
                #expect(response.status == "200")
                let seen = response.bodyString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                #expect(seen.first == "POST /submit HTTP/1.1")
                #expect(seen.contains("content-length: 11"))
                #expect(seen.last == "hello there")
            }
        }
    }
}
