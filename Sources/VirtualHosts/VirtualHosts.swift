public import HTTPCore

/// One site of a ``VirtualHosts`` set: the names it answers and its own handler chain (#0092).
///
/// ```swift
/// VirtualHost("example.com", "www.example.com", handler: StaticFiles(root: "/srv/example"))
/// VirtualHost("*.example.org") {            // any subdomain of example.org
///     AccessLog()
///     StaticFiles(root: "/srv/org")
/// }
/// VirtualHost.default(handler: StaticFiles(root: "/srv/default"))
/// ```
///
/// Names are matched case-insensitively against the request's host with any port removed.
/// `*.example.com` matches every name ending in `.example.com` (one or more labels in front),
/// not `example.com` itself. Internationalized names are written in punycode (`xn--…`), the
/// form clients send; nothing is converted.
public struct VirtualHost: Sendable {
    /// The names as configured.
    public let names: [String]
    /// True for the host that answers requests no name matches.
    public let isDefault: Bool
    @usableFromInline
    let handler: @Sendable (HTTPRequest, RequestContext) async throws -> HTTPResponse
    /// The chain as built, for ``MiddlewareChainContainer`` inspection (not used per request).
    @usableFromInline
    let chain: any Sendable

    /// A host answering `names` with `handler` (any chain built with ``MiddlewareBuilder``).
    @inlinable
    public init<H: HTTPHandler>(_ names: [String], isDefault: Bool = false, handler: H) {
        self.names = names
        self.isDefault = isDefault
        self.chain = handler
        // The closure is compiled here with `H` known, so the chain inlines into it.
        self.handler = { request, context in try await handler.handle(request, context: context) }
    }

    /// A host answering `names` with `handler`.
    @inlinable
    public init<H: HTTPHandler>(_ names: String..., isDefault: Bool = false, handler: H) {
        self.init(names, isDefault: isDefault, handler: handler)
    }

    /// A host answering `names` with the chain built by `chain`.
    @inlinable
    public init<H: HTTPHandler>(_ names: String..., isDefault: Bool = false,
                                @MiddlewareBuilder chain: () -> H) {
        self.init(names, isDefault: isDefault, handler: chain())
    }

    /// The default host (optionally with names of its own): it answers requests whose host
    /// matches no name, and requests without one.
    @inlinable
    public static func `default`<H: HTTPHandler>(_ names: String..., handler: H) -> VirtualHost {
        VirtualHost(names, isDefault: true, handler: handler)
    }

    /// The default host with the chain built by `chain`.
    @inlinable
    public static func `default`<H: HTTPHandler>(_ names: String..., @MiddlewareBuilder chain: () -> H) -> VirtualHost {
        VirtualHost(names, isDefault: true, handler: chain())
    }
}

/// Collects ``VirtualHost``s: hosts, `if`, `if`/`else` and `for` loops.
@resultBuilder
public enum VirtualHostBuilder {
    public static func buildExpression(_ host: VirtualHost) -> [VirtualHost] { [host] }
    public static func buildExpression(_ hosts: [VirtualHost]) -> [VirtualHost] { hosts }
    public static func buildBlock(_ components: [VirtualHost]...) -> [VirtualHost] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [VirtualHost]?) -> [VirtualHost] { component ?? [] }
    public static func buildEither(first component: [VirtualHost]) -> [VirtualHost] { component }
    public static func buildEither(second component: [VirtualHost]) -> [VirtualHost] { component }
    public static func buildArray(_ components: [[VirtualHost]]) -> [VirtualHost] { components.flatMap { $0 } }
}

/// The virtual host a request was routed to, set in ``RequestContext`` for the host's chain
/// (an access log) when ``VirtualHosts`` records it.
public struct MatchedVirtualHost: Sendable, Equatable {
    /// Position of the host in the set, in the order given.
    public let index: Int
    /// The host's first configured name (`""` for a default host without names).
    public let name: String
    /// True when no name matched and the default host answered.
    public let isFallback: Bool
}

/// The ``RequestContext`` key of ``MatchedVirtualHost``.
public enum VirtualHostKey: RequestContextKey {
    public static var defaultValue: MatchedVirtualHost? { nil }
}

extension RequestContext {
    /// The virtual host the request was routed to, when ``VirtualHosts`` records it.
    public var virtualHost: MatchedVirtualHost? { self[VirtualHostKey.self] }
}

/// Routes each request to one of several sites by its host (#0092, docs/ROADMAP.md §5.2).
///
/// ```swift
/// let sites = try VirtualHosts {
///     VirtualHost("a.test", handler: StaticFiles(root: "/srv/a"))
///     VirtualHost("b.test", "*.b.test", handler: StaticFiles(root: "/srv/b"))
///     VirtualHost.default(handler: StaticFiles(root: "/srv/default"))
/// }
/// let server = Server(listeners: [listener], protocols: [HTTP1()]) {
///     AccessLog()
///     sites
/// }
/// ```
///
/// - The host is `:authority` (HTTP/2, HTTP/3, or an HTTP/1.1 absolute-form target) or else
///   the `Host` field, with a trailing `:port` and one trailing `.` removed, compared
///   case-insensitively. An exact name wins over a wildcard; among wildcards the longest
///   suffix wins.
/// - No match, or no host at all (HTTP/1.0 without `Host`), goes to the default host. Without
///   one the answer is `421 Misdirected Request` (``Unmatched/misdirected``) or, as a middleware
///   with ``Unmatched/next``, the next handler. HTTP/1.1 without `Host` never gets here: the
///   parser answers `400` (RFC 9112 §3.2).
/// - Building checks every name and rejects duplicates (``VirtualHostsError``).
///
/// ## Hot path
///
/// The names are compiled once into two hash tables keyed by the lowercased host bytes
/// (``HostTable``). A lookup is one pass over the host bytes plus one probe per dot when
/// wildcards exist: no allocation, no `String` (`sws-bench micro --filter VirtualHosts`,
/// docs/benchmarks/M6-vhosts-auth.md). The matched host's chain is called through one closure,
/// compiled with the chain's types known. ``recordsHost`` sets ``MatchedVirtualHost`` in the
/// context, which costs one small allocation per request; it is off by default.
public struct VirtualHosts: HTTPMiddleware, HTTPHandler {
    /// What a request matching no host gets when there is no default host.
    public enum Unmatched: Sendable {
        /// `421 Misdirected Request` (RFC 9110 §15.5.20).
        case misdirected
        /// The next handler (as a middleware); `404` as a handler.
        case next
    }

    let table: HostTable
    /// The hosts, in the order given.
    public let hosts: [VirtualHost]
    let defaultIndex: Int
    /// The matched host's name for ``MatchedVirtualHost``, per host.
    let primaryNames: [String]
    /// See ``Unmatched``.
    public let unmatched: Unmatched
    /// When true, the matched host is set as ``RequestContext/virtualHost`` (one allocation
    /// per request).
    public let recordsHost: Bool
    let misdirected: HTTPResponse

    /// Compiles `hosts`.
    public init(_ hosts: [VirtualHost], unmatched: Unmatched = .misdirected,
                recordsHost: Bool = false) throws(VirtualHostsError) {
        var patterns: [[HostPattern]] = []
        var defaultIndex = -1
        for (index, host) in hosts.enumerated() {
            var parsed: [HostPattern] = []
            for name in host.names { parsed.append(try HostPattern.parse(name)) }
            patterns.append(parsed)
            if host.isDefault {
                guard defaultIndex < 0 else { throw .multipleDefaults }
                defaultIndex = index
            }
        }
        table = try HostTable(patterns)
        self.hosts = hosts
        self.defaultIndex = defaultIndex
        self.primaryNames = hosts.map { $0.names.first ?? "" }
        self.unmatched = unmatched
        self.recordsHost = recordsHost
        self.misdirected = HTTPResponse(status: .misdirectedRequest)
    }

    /// Compiles the hosts built by `hosts`.
    public init(unmatched: Unmatched = .misdirected, recordsHost: Bool = false,
                @VirtualHostBuilder _ hosts: () -> [VirtualHost]) throws(VirtualHostsError) {
        try self.init(hosts(), unmatched: unmatched, recordsHost: recordsHost)
    }

    /// The default host's position, or `nil`.
    public var defaultHost: Int? { defaultIndex >= 0 ? defaultIndex : nil }

    // MARK: Matching

    /// The position of the host whose names match `authority` (a `Host` value or
    /// `:authority`, port allowed), or `nil`. The default host is not considered. Does not
    /// allocate.
    public func match(authority: Span<UInt8>) -> Int? {
        let index = table.lookup(authority: authority)
        return index >= 0 ? Int(index) : nil
    }

    /// The position of the host answering `request`: a matching name, else the default host,
    /// else `nil`. Does not allocate.
    @inline(__always)
    public func route(_ request: HTTPRequest) -> Int? {
        let index = lookup(request)
        if index >= 0 { return index }
        return defaultIndex >= 0 ? defaultIndex : nil
    }

    /// The matching host for `request` ignoring the default, or -1.
    @inline(__always)
    func lookup(_ request: HTTPRequest) -> Int {
        var view = request.authority
        if view.isEmpty {
            guard let host = request.headers.firstValue(for: .host) else { return -1 }
            view = host
        }
        let table = table
        return Int(request.withSpan(of: view) { table.lookup(authority: $0) })
    }

    // MARK: HTTPMiddleware and HTTPHandler

    /// Hands the request to its host's chain, the default host's, or ``unmatched``.
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        var index = lookup(request)
        var fallback = false
        if index < 0 {
            guard defaultIndex >= 0 else {
                switch unmatched {
                case .misdirected: return misdirected
                case .next: return try await next.handle(request, context: context)
                }
            }
            index = defaultIndex
            fallback = true
        }
        if recordsHost {
            var context = context
            context[VirtualHostKey.self] = MatchedVirtualHost(index: index, name: primaryNames[index], isFallback: fallback)
            return try await hosts[index].handler(request, context)
        }
        return try await hosts[index].handler(request, context)
    }

    /// Hands the request to its host's chain, the default host's, or ``unmatched`` (`404` for
    /// ``Unmatched/next``).
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await handle(request, context: context, next: NotFoundHandler())
    }
}

extension VirtualHosts: MiddlewareChainContainer {
    /// Every host's chain, so the server finds components (an access log, a start-time
    /// consumer) registered inside a host.
    public func forEachChainElement(_ body: (Any) -> Void) {
        for host in hosts { body(host.chain) }
    }
}
