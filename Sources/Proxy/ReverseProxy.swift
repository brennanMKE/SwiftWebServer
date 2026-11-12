// ReverseProxy middleware (#0121): forwards requests under a mount to an upstream
// through an `UpstreamClient`, rewriting headers both ways.
public import HTTPCore

public struct ReverseProxy: HTTPMiddleware {
    /// Mounts sorted longest path first, so the first match is the longest prefix.
    let mounts: [CompiledMount]
    let client: any UpstreamClient
    /// Upgraded connections: WebSocket and Upgrade passthrough (#0123).
    public var tunnel = ProxyTunnelConfiguration()

    public init(mounts: [ProxyMount], client: any UpstreamClient) {
        self.mounts = mounts
            .map(CompiledMount.init)
            .sorted { $0.prefix.count > $1.prefix.count }
        self.client = client
    }

    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        let mount: CompiledMount
        let decoded: String
        switch request.withSpan(of: request.path, { lookup(path: $0, request: request) }) {
        case .miss:
            return try await next.handle(request, context: context)
        case .hit(let index):
            // The raw path is already normalized: it is the decoded path.
            mount = mounts[index]
            decoded = request.string(of: request.path)
        case .needsNormalizing:
            guard let normalized = ReverseProxyPath.normalize(request.string(of: request.path)),
                  let match = match(path: normalized, host: Self.clientHost(request)) else {
                return try await next.handle(request, context: context)
            }
            mount = match.mount
            decoded = normalized
        }
        let clientHost = Self.clientHost(request)
        // #0123: upgrades go to the next healthy upstream in round-robin order.
        if let target = mount.balancer.peek().map({ mount.config.upstreams[$0] }),
           let upgraded = try await proxyUpgradeIfRequested(request, decodedPath: decoded, mount: mount, target: target,
                                                            clientHost: clientHost, context: context) { return upgraded }
        // #0122: upstream choice, timeouts, retries and health are in ReverseProxy+Forwarding.
        return try await forward(request, decodedPath: decoded, mount: mount,
                                 clientHost: clientHost, context: context)
    }

    // MARK: Matching

    enum Lookup: Equatable {
        case miss
        case hit(Int)
        /// The path has percent-escapes, dot segments or non-ASCII bytes: decode and normalize
        /// it first (the slow path).
        case needsNormalizing
    }

    /// Matches a raw request path on its bytes, without allocating: the first (longest) mount
    /// whose prefix ends on a segment boundary and whose hosts (if any) include the request's.
    /// A path that is not already in normal form is left to the slow path, so `/%61pi` and
    /// `/x/../api` match exactly as their normalized forms do.
    func lookup(path: Span<UInt8>, request: HTTPRequest) -> Lookup {
        guard ReverseProxyPath.isNormalized(path) else { return .needsNormalizing }
        for (i, mount) in mounts.enumerated() where mount.matches(path) {
            if mount.hostBytes.isEmpty || hostMatches(mount, request) { return .hit(i) }
        }
        return .miss
    }

    /// Whether the request's host (`:authority` or `Host`, port removed) is one of `mount`'s.
    func hostMatches(_ mount: CompiledMount, _ request: HTTPRequest) -> Bool {
        func check(_ host: Span<UInt8>) -> Bool {
            let name = host.extracting(0..<ReverseProxyPath.hostLengthWithoutPort(host))
            return mount.hostBytes.contains { candidate in
                candidate.withUnsafeBufferPointer { ReverseProxyHeaders.equalsCaseInsensitive(name, $0.span) }
            }
        }
        if request.authority.length > 0 { return request.withSpan(of: request.authority, check) }
        guard let host = request.headers.firstValue(for: .host) else { return false }
        return request.headers.withSpan(of: host, check)
    }

    func match(path: String, host: String?) -> (mount: CompiledMount, remainder: Substring)? {
        for mount in mounts {
            if !mount.hosts.isEmpty {
                guard let host, mount.hosts.contains(ReverseProxyHeaders.hostWithoutPort(host).lowercased()) else { continue }
            }
            if let remainder = mount.remainder(of: path) { return (mount, remainder) }
        }
        return nil
    }

    /// For `sws-bench`: whether the byte-level lookup matches a mount (no allocation).
    @_spi(Benchmark) public func benchLookup(_ request: HTTPRequest) -> Bool {
        if case .hit = request.withSpan(of: request.path, { lookup(path: $0, request: request) }) { return true }
        return false
    }

    /// For `sws-bench`: the upstream request for `request` under the first mount, if it matches.
    @_spi(Benchmark) public func benchUpstreamRequest(_ request: HTTPRequest, context: RequestContext) -> UpstreamRequest? {
        guard case .hit(let i) = request.withSpan(of: request.path, { lookup(path: $0, request: request) }),
              let target = mounts[i].config.upstreams.first else { return nil }
        return makeUpstreamRequest(request, decodedPath: request.string(of: request.path), mount: mounts[i],
                                   target: target, clientHost: Self.clientHost(request), context: context)
    }

    // MARK: Request

    func makeUpstreamRequest(_ request: HTTPRequest, decodedPath: String, mount: CompiledMount,
                             target: UpstreamTarget, clientHost: String?,
                             context: RequestContext) -> UpstreamRequest {
        var path = decodedPath
        if mount.config.stripPrefix, let remainder = mount.remainder(of: decodedPath) {
            path = remainder.isEmpty ? "/" : String(remainder)
        }
        if !target.basePath.isEmpty {
            var base = target.basePath
            while base.hasSuffix("/") { base.removeLast() }
            if !base.hasPrefix("/") { base = "/" + base }
            path = path == "/" && mount.config.stripPrefix ? base + "/" : base + path
        }
        var targetString = ReverseProxyPath.encode(path)
        if request.query.length > 0 {
            targetString += "?" + request.string(of: request.query)
        }
        let upstreamHost = ReverseProxyHeaders.authority(of: target.address)
        let host = mount.config.preserveHost ? (clientHost ?? upstreamHost) : upstreamHost
        let headers = ReverseProxyHeaders.requestHeaders(request.headers, mount: mount.config,
                                                         clientHost: clientHost, connection: context.connection)
        return UpstreamRequest(method: request.method, target: targetString, host: host, headers: headers)
    }

    static func clientHost(_ request: HTTPRequest) -> String? {
        if request.authority.length > 0 { return request.string(of: request.authority) }
        return request.headers.firstValueString(for: .host)
    }

    // MARK: Response

    func mapResponse(_ upstream: UpstreamResponse, mount: CompiledMount, target: UpstreamTarget,
                     clientHost: String?, secure: Bool) -> HTTPResponse {
        var headers = ReverseProxyHeaders.stripHopByHop(upstream.headers)
        if mount.config.rewriteLocation {
            headers = ReverseProxyLocation.rewrite(headers, mount: mount.config, target: target,
                                                   clientHost: clientHost, secure: secure)
        }
        if mount.config.rewriteCookiePath, headers.contains(.setCookie) {
            headers = ReverseProxyLocation.rewriteCookiePaths(headers, mount: mount.config, target: target)
        }
        let body = upstream.body
        let responseBody: HTTPResponseBody
        if body.knownLength == 0 {
            responseBody = .stream(length: 0) { _ in await body.discard() }
        } else {
            responseBody = .stream(length: body.knownLength) { writer in
                do {
                    while let chunk = try await body.next() {
                        try await writer.write(chunk)
                    }
                } catch {
                    await body.discard()
                    throw error
                }
            }
        }
        return HTTPResponse(status: upstream.status, headers: headers, body: responseBody)
    }
}

/// A mount compiled once at startup.
struct CompiledMount: Sendable {
    let config: ProxyMount
    /// The mount path without a trailing slash; empty for "/".
    let prefix: String
    let hosts: [String]
    /// `prefix` and `hosts` as bytes, for matching without strings.
    let prefixBytes: [UInt8]
    let hostBytes: [[UInt8]]
    /// Round-robin choice and health of `config.upstreams` (#0122).
    let balancer: UpstreamBalancer

    init(_ config: ProxyMount) {
        self.config = config
        self.balancer = UpstreamBalancer(count: config.upstreams.count, policy: config.policy.health)
        var prefix = config.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.isEmpty, !prefix.hasPrefix("/") { prefix = "/" + prefix }
        self.prefix = prefix
        self.hosts = config.hosts.map { $0.lowercased() }
        self.prefixBytes = Array(prefix.utf8)
        self.hostBytes = hosts.map { Array($0.utf8) }
    }

    /// Whether the normalized `path` is under this mount on a segment boundary.
    func matches(_ path: Span<UInt8>) -> Bool {
        let n = prefixBytes.count
        guard path.count >= n else { return false }
        for i in 0..<n where path[i] != prefixBytes[i] { return false }
        return path.count == n || path[n] == UInt8(ascii: "/")
    }

    /// The part of `path` after the prefix when `path` is under this mount on a
    /// segment boundary ("" or starting with "/"); nil otherwise.
    func remainder(of path: String) -> Substring? {
        let utf8 = path.utf8
        let prefixUTF8 = prefix.utf8
        guard utf8.count >= prefixUTF8.count, utf8.starts(with: prefixUTF8) else { return nil }
        let rest = path.utf8.dropFirst(prefixUTF8.count)
        if let first = rest.first, first != UInt8(ascii: "/") { return nil }
        return Substring(rest)
    }
}

enum ReverseProxyPath {
    /// Whether `path` is already what ``normalize(_:)`` would return: absolute, ASCII, with no
    /// percent-escape, NUL or dot segment. Such a path can be matched as it is.
    static func isNormalized(_ path: Span<UInt8>) -> Bool {
        guard !path.isEmpty, path[0] == UInt8(ascii: "/") else { return false }
        var segmentStart = 1
        var dots = 0
        for i in 1..<path.count {
            let b = path[i]
            if b == UInt8(ascii: "/") {
                if dots > 0 && dots == i - segmentStart { return false }
                segmentStart = i + 1
                dots = 0
            } else if b == UInt8(ascii: ".") {
                dots += 1
                if dots > 2 { dots = Int.min / 2 }
            } else if b == UInt8(ascii: "%") || b == 0 || b >= 0x80 {
                return false
            }
        }
        return !(dots > 0 && dots == path.count - segmentStart)
    }

    /// The length of `host` without a `:port` (an IPv6 literal keeps its brackets).
    static func hostLengthWithoutPort(_ host: Span<UInt8>) -> Int {
        if !host.isEmpty, host[0] == UInt8(ascii: "[") {
            for i in 0..<host.count where host[i] == UInt8(ascii: "]") { return i + 1 }
            return host.count
        }
        var i = host.count
        while i > 0 {
            i -= 1
            if host[i] == UInt8(ascii: ":") { return i }
        }
        return host.count
    }

    /// Percent-decodes `path` and resolves dot segments. Returns nil for a path
    /// that is malformed, not absolute, contains NUL, or climbs above the root.
    static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(path.utf8.count)
        var iterator = Array(path.utf8)[...]
        while let byte = iterator.popFirst() {
            if byte == UInt8(ascii: "%") {
                guard iterator.count >= 2,
                      let high = hexValue(iterator.removeFirst()),
                      let low = hexValue(iterator.removeFirst()) else { return nil }
                let decoded = high << 4 | low
                if decoded == 0 { return nil }
                bytes.append(decoded)
            } else {
                bytes.append(byte)
            }
        }
        guard let decoded = String(validating: bytes, as: UTF8.self) else { return nil }
        var segments: [Substring] = []
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        for (i, part) in parts.enumerated() {
            switch part {
            case ".":
                if i == parts.count - 1 { segments.append("") }
            case "..":
                if segments.isEmpty { return nil }
                segments.removeLast()
                if i == parts.count - 1 { segments.append("") }
            default:
                segments.append(part)
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Re-encodes a decoded path for an origin-form request target.
    static func encode(_ path: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            if isAllowed(byte) {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0xF)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "-._~!$&'()*+,;=:@/".utf8.contains(byte)
        }
    }
}
