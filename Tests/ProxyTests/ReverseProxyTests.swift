import HTTPCore
@testable import Proxy
import Synchronization
import Testing

/// Records each request and answers with a scripted response or error.
final class FakeUpstreamClient: UpstreamClient {
    struct Sent: Sendable {
        let request: UpstreamRequest
        let target: UpstreamTarget
    }

    let sent = Mutex<[Sent]>([])
    let result: @Sendable () throws -> UpstreamResponse

    init(_ result: @escaping @Sendable () throws -> UpstreamResponse = {
        UpstreamResponse(status: .ok, headers: HTTPFields(), body: .empty)
    }) {
        self.result = result
    }

    func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget) async throws -> UpstreamResponse {
        sent.withLock { $0.append(Sent(request: request, target: target)) }
        return try result()
    }

    var last: UpstreamRequest? { sent.withLock { $0.last?.request } }
    var count: Int { sent.withLock { $0.count } }
}

/// A request built the way a connection builds one.
struct ProxyTestRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(_ path: String, query: String = "", headers: [(String, String)] = []) {
        let storage = HTTPRequestStorage(bufferCapacity: 2048, fieldCapacity: 16)
        self.storage = storage
        func add(_ string: String) -> ByteView {
            let bytes = Array(string.utf8)
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: bytes)
            return ByteView(offset: start, length: bytes.count)
        }
        let pathView = add(path)
        let queryView = add(query)
        for (name, value) in headers {
            let nameView = add(name)
            let valueView = add(value)
            let hash = storage.buffer.withSpan(of: nameView) { ASCII.fnv1aLowercased($0) }
            storage.appendField(nameView: nameView, hash: hash, valueView: valueView)
        }
        request = HTTPRequest(method: .get, path: pathView, query: queryView, headers: storage.fieldsView)
    }
}

struct StaticHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .ok, headers: HTTPFields(), body: .bytes(ByteBuffer("static")))
    }
}

final class Collector: HTTPBodyWriter, Sendable {
    let chunks = Mutex<[[UInt8]]>([])
    func write(_ bytes: ByteBuffer) async throws {
        let copy = bytes.withUnsafeReadableBytes { Array($0) }
        chunks.withLock { $0.append(copy) }
    }
}

let upstream = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000))
let peerContext = RequestContext(connection: ConnectionInfo(
    remoteAddress: TransportAddress(host: "203.0.113.7", port: 5555), isSecure: true))

func send(_ proxy: ReverseProxy, _ path: String, query: String = "",
          headers: [(String, String)] = [("Host", "example.com")]) async throws -> HTTPResponse {
    let request = ProxyTestRequest(path, query: query, headers: headers)
    return try await proxy.handle(request.request, context: peerContext, next: StaticHandler())
}

func header(_ fields: HTTPFields, _ name: String) -> [String] {
    (0..<fields.count).filter { fields.nameString(at: $0).lowercased() == name.lowercased() }
        .map { fields.valueString(at: $0) }
}

@Suite struct ReverseProxyMatchingTests {
    @Test func segmentBoundaryAndFallThrough() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream])], client: client)
        _ = try await send(proxy, "/api")
        _ = try await send(proxy, "/api/x")
        #expect(client.count == 2)
        let miss = try await send(proxy, "/apix")
        #expect(client.count == 2)
        #expect(miss.body.knownLength == 6)
        _ = try await send(proxy, "/index.html")
        #expect(client.count == 2)
    }

    @Test func decodedAndTraversalPaths() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream])], client: client)
        _ = try await send(proxy, "/%61pi/users")
        #expect(client.last?.target == "/api/users")
        _ = try await send(proxy, "/api/../x")
        #expect(client.count == 1)
        _ = try await send(proxy, "/x/../api/y")
        #expect(client.count == 2)
        #expect(client.last?.target == "/api/y")
    }

    @Test func longestPrefixWins() async throws {
        let other = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9001))
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream]),
                                          ProxyMount(path: "/api/v2", upstreams: [other])], client: client)
        _ = try await send(proxy, "/api/v2/x")
        #expect(client.sent.withLock { $0.last?.target } == other)
        _ = try await send(proxy, "/api/v2x")
        #expect(client.sent.withLock { $0.last?.target } == upstream)
    }

    @Test func stripKeepBasePathAndQuery() async throws {
        let client = FakeUpstreamClient()
        let based = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000), basePath: "/app")
        let strip = ReverseProxy(mounts: [ProxyMount(path: "/cgi-bin", upstreams: [upstream], stripPrefix: true)], client: client)
        _ = try await send(strip, "/cgi-bin/foo", query: "x=1&y=%20")
        #expect(client.last?.target == "/foo?x=1&y=%20")
        _ = try await send(strip, "/cgi-bin")
        #expect(client.last?.target == "/")
        let keep = ReverseProxy(mounts: [ProxyMount(path: "/cgi-bin", upstreams: [based])], client: client)
        _ = try await send(keep, "/cgi-bin/foo", query: "q=a")
        #expect(client.last?.target == "/app/cgi-bin/foo?q=a")
        let stripBased = ReverseProxy(mounts: [ProxyMount(path: "/cgi-bin", upstreams: [based], stripPrefix: true)], client: client)
        _ = try await send(stripBased, "/cgi-bin/foo")
        #expect(client.last?.target == "/app/foo")
    }
}

@Suite struct ReverseProxyHeaderTests {
    @Test func hopByHopRemovedAndForwardedReplaced() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream])], client: client)
        _ = try await send(proxy, "/api/x", headers: [
            ("Host", "example.com"), ("Connection", "keep-alive, X-Secret"), ("X-Secret", "1"),
            ("Keep-Alive", "timeout=5"), ("TE", "trailers"), ("Trailer", "X"), ("Transfer-Encoding", "chunked"),
            ("Upgrade", "h2c"), ("Proxy-Authorization", "x"), ("Proxy-Foo", "y"),
            ("X-Forwarded-For", "6.6.6.6"), ("X-Forwarded-Proto", "http"), ("X-Forwarded-Host", "evil"),
            ("X-Forwarded-Prefix", "/evil"), ("Accept", "*/*"),
        ])
        let request = try #require(client.last)
        let h = request.headers
        for name in ["Connection", "X-Secret", "Keep-Alive", "TE", "Trailer", "Transfer-Encoding",
                     "Upgrade", "Proxy-Authorization", "Proxy-Foo", "Forwarded", "Host"] {
            #expect(header(h, name).isEmpty, "\(name) should be removed")
        }
        #expect(header(h, "Accept") == ["*/*"])
        #expect(header(h, "X-Forwarded-For") == ["203.0.113.7"])
        #expect(header(h, "X-Forwarded-Proto") == ["https"])
        #expect(header(h, "X-Forwarded-Host") == ["example.com"])
        #expect(header(h, "X-Forwarded-Prefix") == ["/api"])
        #expect(request.host == "127.0.0.1:9000")
    }

    @Test func preserveHostAndForwardedOption() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream], preserveHost: true,
                                                     forwardedHeaders: .forwarded)], client: client)
        _ = try await send(proxy, "/api", headers: [("Host", "example.com"), ("Forwarded", "for=6.6.6.6")])
        let request = try #require(client.last)
        #expect(request.host == "example.com")
        #expect(header(request.headers, "Forwarded") == ["for=203.0.113.7;proto=https;host=\"example.com\""])
        #expect(header(request.headers, "X-Forwarded-For").isEmpty)

        let both = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream], forwardedHeaders: .both)], client: client)
        _ = try await send(both, "/api")
        #expect(header(client.last!.headers, "Forwarded").count == 1)
        #expect(header(client.last!.headers, "X-Forwarded-For").count == 1)

        let none = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream], forwardedHeaders: .none)], client: client)
        _ = try await send(none, "/api", headers: [("Host", "example.com"), ("X-Forwarded-For", "6.6.6.6")])
        #expect(header(client.last!.headers, "X-Forwarded-For").isEmpty)
        #expect(header(client.last!.headers, "Forwarded").isEmpty)
    }
}

@Suite struct ReverseProxyResponseTests {
    @Test func errorsMapTo502And504() async throws {
        let refused = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [upstream])],
                                   client: FakeUpstreamClient { throw UpstreamError.connectFailed("refused") })
        #expect(try await send(refused, "/x").status == .badGateway)
        let slow = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [upstream])],
                                client: FakeUpstreamClient { throw UpstreamError.timeout })
        #expect(try await send(slow, "/x").status == .gatewayTimeout)
    }

    @Test func responseHopByHopStrippedAndLocationRewritten() async throws {
        let client = FakeUpstreamClient {
            var h = HTTPFields()
            h.append(name: "Connection", value: "close, X-Hop")
            h.append(name: "X-Hop", value: "1")
            h.append(name: "Keep-Alive", value: "timeout=5")
            h.append(name: "Transfer-Encoding", value: "chunked")
            h.append(name: "Location", value: "http://127.0.0.1:9000/login?next=1")
            h.append(name: "Content-Location", value: "http://other.example/x")
            h.append(name: "Content-Type", value: "text/plain")
            return UpstreamResponse(status: HTTPStatus(code: 302), headers: h, body: .empty)
        }
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream], stripPrefix: true)], client: client)
        let response = try await send(proxy, "/api/a")
        #expect(response.status.code == 302)
        for name in ["Connection", "X-Hop", "Keep-Alive", "Transfer-Encoding"] {
            #expect(header(response.headers, name).isEmpty)
        }
        #expect(header(response.headers, "Location") == ["https://example.com/api/login?next=1"])
        #expect(header(response.headers, "Content-Location") == ["http://other.example/x"])
        #expect(header(response.headers, "Content-Type") == ["text/plain"])

        let off = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream], rewriteLocation: false)], client: client)
        #expect(header(try await send(off, "/api/a").headers, "Location") == ["http://127.0.0.1:9000/login?next=1"])
    }

    @Test func streamsMultiChunkBody() async throws {
        let client = FakeUpstreamClient {
            let chunks = Mutex(["one", "two", "three"])
            let body = UpstreamResponseBody(knownLength: nil, next: {
                chunks.withLock { $0.isEmpty ? nil : ByteBuffer(bytes: $0.removeFirst().utf8) }
            }, discard: {})
            return UpstreamResponse(status: .ok, headers: HTTPFields(), body: body)
        }
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [upstream])], client: client)
        let response = try await send(proxy, "/stream")
        guard case .stream(let length, let writer) = response.body else {
            Issue.record("expected a stream body")
            return
        }
        #expect(length == nil)
        let collector = Collector()
        try await writer(collector)
        let chunks = collector.chunks.withLock { $0 }
        #expect(chunks.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
    }
}
