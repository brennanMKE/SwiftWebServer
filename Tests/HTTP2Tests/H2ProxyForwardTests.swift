import HTTP1
@testable import HTTP2
import HTTPCore
import HTTPServer
import NetworkTransport
import Proxy
import Testing

// #0121: requests arriving over HTTP/2 are forwarded upstream as HTTP/1.1 (pseudo-headers
// mapped to the request line and Host) and the answer goes back over HTTP/2.

/// Echoes what the upstream received: the request line, every field, then the body.
struct UpstreamEchoHandler: HTTPHandler {
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

/// Runs an HTTP/1.1 echo upstream on 127.0.0.1:0 and calls `body` with a proxy chain for `/api`.
func withProxiedEchoUpstream(
    _ body: @Sendable (MiddlewareChain<ReverseProxy, HelloHandler>) async throws -> Void
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
        try await body(MiddlewareChain(middleware: proxy, next: HelloHandler()))
        await client.shutdown()
        server.requestShutdown()
        try await group.waitForAll()
    }
}

private func lines(_ body: [UInt8]) -> [String] {
    String(decoding: body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

@Suite(.timeLimit(.minutes(1)))
struct H2ProxyForwardTests {
    @Test func getIsForwardedAsHTTP11() async throws {
        try await withProxiedEchoUpstream { chain in
            let info = ConnectionInfo(remoteAddress: TransportAddress(host: "198.51.100.9", port: 4444), isSecure: true)
            try await withH2Connection(handler: chain, info: info) { h2 in
                try await h2.handshake()
                let block = h2.requests.block([(":method", "GET"), (":scheme", "https"), (":authority", "app.example"),
                                               (":path", "/api/echo?x=1&y=%20"), ("x-client", "1"), ("te", "trailers")])
                try await h2.send(F.headers(1, block: block))
                let (head, body, _) = try await h2.response(on: 1)
                #expect(head.first { $0.0 == ":status" }?.1 == "200")
                #expect(head.first { $0.0 == "x-upstream" }?.1 == "h1")
                // Hop-by-hop fields of the upstream answer are not relayed.
                #expect(!head.contains { $0.0 == "keep-alive" })
                let seen = lines(body)
                #expect(seen.first == "GET /echo?x=1&y=%20 HTTP/1.1")
                #expect(seen.contains { $0.hasPrefix("host: 127.0.0.1:") })
                #expect(seen.contains("x-client: 1"))
                #expect(seen.contains("x-forwarded-for: 198.51.100.9"))
                #expect(seen.contains("x-forwarded-proto: https"))
                #expect(seen.contains("x-forwarded-host: app.example"))
                #expect(seen.contains("x-forwarded-prefix: /api"))
                #expect(!seen.contains { $0.hasPrefix(":") || $0.hasPrefix("te:") })
            }
        }
    }

    @Test func postBodyIsStreamedUpstream() async throws {
        try await withProxiedEchoUpstream { chain in
            try await withH2Connection(handler: chain) { h2 in
                try await h2.handshake()
                let block = h2.requests.block([(":method", "POST"), (":scheme", "http"), (":authority", "localhost"),
                                               (":path", "/api/submit")])
                try await h2.send(F.headers(1, block: block, endStream: false))
                try await h2.send(F.data(1, Array("hello ".utf8), endStream: false))
                try await h2.send(F.data(1, Array("upstream".utf8), endStream: true))
                let (head, body, _) = try await h2.response(on: 1)
                #expect(head.first { $0.0 == ":status" }?.1 == "200")
                let seen = lines(body)
                #expect(seen.first == "POST /submit HTTP/1.1")
                // Unknown length downstream: chunked upstream.
                #expect(seen.contains("transfer-encoding: chunked"))
                #expect(seen.last == "hello upstream")
            }
        }
    }

    @Test func pathsOutsideTheMountAreNotProxied() async throws {
        try await withProxiedEchoUpstream { chain in
            try await withH2Connection(handler: chain) { h2 in
                try await h2.handshake()
                try await h2.send(F.headers(1, block: h2.requests.get("/apix")))
                let (_, body, _) = try await h2.response(on: 1)
                #expect(String(decoding: body, as: UTF8.self) == "hello /apix")
            }
        }
    }
}
