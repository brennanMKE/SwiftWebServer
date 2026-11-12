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
        let rawPath = request.string(of: request.path)
        guard let decoded = ReverseProxyPath.normalize(rawPath) else {
            return try await next.handle(request, context: context)
        }
        let clientHost = Self.clientHost(request)
        guard let match = match(path: decoded, host: clientHost) else {
            return try await next.handle(request, context: context)
        }
        let mount = match.mount
        guard let target = mount.config.upstreams.first else {
            return HTTPResponse(status: .badGateway)
        }
        if let upgraded = try await proxyUpgradeIfRequested(request, decodedPath: decoded, mount: mount, target: target,
                                                            clientHost: clientHost, context: context) { return upgraded }
        let upstreamRequest = makeUpstreamRequest(request, decodedPath: decoded, mount: mount,
                                                  target: target, clientHost: clientHost, context: context)
        let response: UpstreamResponse
        do {
            response = try await client.send(upstreamRequest, body: request.body, to: target)
        } catch let error as UpstreamError {
            return HTTPResponse(status: error == .timeout ? .gatewayTimeout : .badGateway)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return HTTPResponse(status: .badGateway)
        }
        return mapResponse(response, mount: mount, target: target, clientHost: clientHost,
                           secure: context.connection.isSecure)
    }

    // MARK: Matching

    func match(path: String, host: String?) -> (mount: CompiledMount, remainder: Substring)? {
        for mount in mounts {
            if !mount.hosts.isEmpty {
                guard let host, mount.hosts.contains(ReverseProxyHeaders.hostWithoutPort(host).lowercased()) else { continue }
            }
            if let remainder = mount.remainder(of: path) { return (mount, remainder) }
        }
        return nil
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

    init(_ config: ProxyMount) {
        self.config = config
        var prefix = config.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.isEmpty, !prefix.hasPrefix("/") { prefix = "/" + prefix }
        self.prefix = prefix
        self.hosts = config.hosts.map { $0.lowercased() }
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
