// Shared API for the reverse proxy (M17). #0120 implements `UpstreamClient`;
// #0121 builds the `ReverseProxy` component against it; #0124 maps config onto
// `ProxyMount`. Keep these declarations stable; extend additively.
public import HTTPCore

/// Where an upstream app server listens.
public enum UpstreamAddress: Sendable, Hashable {
    case tcp(host: String, port: UInt16)
    case unix(path: String)
}

/// One upstream: an address plus an optional base path prepended to forwarded paths.
public struct UpstreamTarget: Sendable, Hashable {
    public var address: UpstreamAddress
    /// Prefix added in front of the forwarded path, e.g. "/app". Empty for none.
    public var basePath: String
    public init(address: UpstreamAddress, basePath: String = "") {
        self.address = address
        self.basePath = basePath
    }
}

/// A request to send upstream. Headers are already rewritten by the proxy
/// (hop-by-hop removed, forwarded headers added); the client adds framing.
public struct UpstreamRequest: Sendable {
    public var method: HTTPMethod
    /// Origin-form request target: path plus optional "?query".
    public var target: String
    /// Value for the `Host` header.
    public var host: String
    public var headers: HTTPFields
    public init(method: HTTPMethod, target: String, host: String, headers: HTTPFields) {
        self.method = method
        self.target = target
        self.host = host
        self.headers = headers
    }
}

/// The upstream's response head plus a streamed body. The body must be
/// consumed or `discard()`ed; the connection returns to the pool only after a
/// complete, well-framed body.
public struct UpstreamResponse: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPFields
    public var body: UpstreamResponseBody
    public init(status: HTTPStatus, headers: HTTPFields, body: UpstreamResponseBody) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Streamed upstream response body. `next()` returns nil at the end of the body.
public struct UpstreamResponseBody: Sendable {
    public let knownLength: Int?
    private let nextChunk: @Sendable () async throws -> ByteBuffer?
    private let discardRest: @Sendable () async -> Void
    public init(knownLength: Int?,
                next: @escaping @Sendable () async throws -> ByteBuffer?,
                discard: @escaping @Sendable () async -> Void) {
        self.knownLength = knownLength
        self.nextChunk = next
        self.discardRest = discard
    }
    public func next() async throws -> ByteBuffer? { try await nextChunk() }
    /// Abandon the rest of the body; the connection is closed, not pooled.
    public func discard() async { await discardRest() }
    public static let empty = UpstreamResponseBody(knownLength: 0, next: { nil }, discard: {})
}

public enum UpstreamError: Error, Sendable, Equatable {
    case connectFailed(String)
    case timeout
    case malformedResponse(String)
    case closedEarly
    case cancelled
}

/// Sends requests to upstreams. Implemented by the pooled HTTP/1.1 client (#0120).
public protocol UpstreamClient: Sendable {
    func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget) async throws -> UpstreamResponse
}

/// One proxied mount (#0121), as configured (#0124).
public struct ProxyMount: Sendable {
    public enum ForwardedHeaders: String, Sendable { case xForwarded = "x-forwarded", forwarded, both, none }
    /// Path prefix matched on segment boundaries, e.g. "/api". "/" mounts everything.
    public var path: String
    /// Optional host names this mount applies to (empty: any host).
    public var hosts: [String]
    public var upstreams: [UpstreamTarget]
    public var stripPrefix: Bool
    public var preserveHost: Bool
    public var forwardedHeaders: ForwardedHeaders
    public var rewriteLocation: Bool
    public var websocket: Bool
    public init(path: String, hosts: [String] = [], upstreams: [UpstreamTarget],
                stripPrefix: Bool = false, preserveHost: Bool = false,
                forwardedHeaders: ForwardedHeaders = .xForwarded,
                rewriteLocation: Bool = true, websocket: Bool = false) {
        self.path = path
        self.hosts = hosts
        self.upstreams = upstreams
        self.stripPrefix = stripPrefix
        self.preserveHost = preserveHost
        self.forwardedHeaders = forwardedHeaders
        self.rewriteLocation = rewriteLocation
        self.websocket = websocket
    }
}
