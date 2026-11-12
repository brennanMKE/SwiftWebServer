public import HTTPCore
import Synchronization

/// Advertises HTTP/3 with `Alt-Svc: h3=":<port>"; ma=<seconds>` (RFC 7838 §3, RFC 9114
/// §3.1.1) on responses to requests that came over TLS: HTTP/1.1 or HTTP/2 on a TLS listener
/// (#0103, docs/ROADMAP.md §6).
///
/// Cleartext responses never carry it (a client must not use an alternative learned over an
/// unauthenticated connection for an `https` origin), and neither do HTTP/3 responses
/// themselves. Register it only when an HTTP/3 listener runs:
///
/// ```swift
/// let altSvc = AltSvc(port: 8443, maxAge: 86_400)
/// Server(listeners: …, protocols: [HTTP1()]) {
///     altSvc
///     StaticFiles(root: root)
/// }
/// ```
///
/// The header value is rendered once. When the UDP port is only known once the listener is
/// bound (port 0), create it with ``init(maxAge:)`` and call ``advertise(port:)`` once; until
/// then no header is added. Per response: one atomic load, a test of the connection's TLS
/// flag and ALPN token, and a copy of the rendered bytes into the response head.
public struct AltSvc: HTTPMiddleware {
    /// The rendered value, published once.
    final class Rendered: Sendable {
        let bytes: [UInt8]

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }
    }

    final class Storage: Sendable {
        let rendered = AtomicLazyReference<Rendered>()
    }

    /// How long clients may use the alternative, in seconds (`ma`).
    public let maxAge: Int
    let storage = Storage()

    /// Advertises HTTP/3 on UDP `port` for `maxAge` seconds (RFC 7838 default: 86 400).
    public init(port: UInt16, maxAge: Int = 86_400) {
        self.init(maxAge: maxAge)
        advertise(port: port)
    }

    /// Advertises nothing until ``advertise(port:)`` is called.
    public init(maxAge: Int = 86_400) {
        precondition(maxAge >= 0, "maxAge must not be negative")
        self.maxAge = maxAge
    }

    /// Sets the advertised UDP port. The first call wins; later calls are ignored.
    public func advertise(port: UInt16) {
        _ = storage.rendered.storeIfNil(Rendered(Array(Self.value(port: port, maxAge: maxAge).utf8)))
    }

    /// The header value, such as `h3=":8443"; ma=86400`, or `nil` before ``advertise(port:)``.
    public var value: String? {
        storage.rendered.load().map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    /// `h3=":<port>"; ma=<maxAge>`.
    public static func value(port: UInt16, maxAge: Int) -> String {
        "h3=\":\(port)\"; ma=\(maxAge)"
    }

    /// True when a response on `connection` should carry the header: TLS, but not HTTP/3.
    @inlinable
    public static func applies(to connection: ConnectionInfo) -> Bool {
        connection.isSecure && connection.negotiatedALPN != "h3"
    }

    public func handle<Next: HTTPHandler>(
        _ request: HTTPRequest, context: RequestContext, next: Next
    ) async throws -> HTTPResponse {
        var response = try await next.handle(request, context: context)
        if Self.applies(to: context.connection), let rendered = storage.rendered.load() {
            rendered.bytes.withUnsafeBufferPointer { response.headers.append(.altSvc, value: $0.span) }
        }
        return response
    }
}
