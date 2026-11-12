// Header rewriting for ReverseProxy (#0121).
import HTTPCore

enum ReverseProxyHeaders {
    static let hopByHop: Set<String> = [
        "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
        "proxy-connection", "proxy-authenticate", "proxy-authorization",
    ]

    /// Names the proxy sets itself; incoming copies are dropped (replaced, not appended).
    static let replaced: Set<String> = [
        "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host", "x-forwarded-prefix",
        "forwarded", "host",
    ]

    /// Lowercased tokens named by every `Connection` header in `fields`.
    static func connectionTokens(_ fields: some HTTPFieldCollection) -> Set<String> {
        var tokens: Set<String> = []
        for i in 0..<fields.count where fields.nameString(at: i).lowercased() == "connection" {
            for token in fields.valueString(at: i).split(separator: ",") {
                let trimmed = token.trimmingSpaces().lowercased()
                if !trimmed.isEmpty { tokens.insert(trimmed) }
            }
        }
        return tokens
    }

    static func isHopByHop(_ lowercasedName: String, connectionTokens: Set<String>) -> Bool {
        hopByHop.contains(lowercasedName) || lowercasedName.hasPrefix("proxy-")
            || connectionTokens.contains(lowercasedName)
    }

    /// Whether the field at `i` is hop-by-hop (RFC 9110 §7.6.1): a fixed hop-by-hop name, any
    /// `Proxy-*`, or a name listed in `Connection`. On bytes, without building strings.
    static func isHopByHop(at i: Int, index: HTTPFieldIndex, arena: ByteBuffer, hasConnection: Bool) -> Bool {
        let name = index.names[i]
        switch name {
        case .connection, .keepAlive, .te, .trailer, .transferEncoding, .upgrade,
             .proxyConnection, .proxyAuthenticate, .proxyAuthorization:
            return true
        default:
            break
        }
        if name == .unknown, arena.withSpan(of: index.nameViews[i], { startsWithCaseInsensitive($0, "proxy-") }) {
            return true
        }
        guard hasConnection else { return false }
        return name == .unknown
            ? arena.withSpan(of: index.nameViews[i]) { isNamedByConnection($0, index: index, arena: arena) }
            : name.canonicalName.withUTF8Buffer { isNamedByConnection($0.span, index: index, arena: arena) }
    }

    /// Whether some `Connection` field lists `name` (any case).
    static func isNamedByConnection(_ name: Span<UInt8>, index: HTTPFieldIndex, arena: ByteBuffer) -> Bool {
        var position = 0
        while let c = index.firstIndex(of: .connection, from: position) {
            let found = arena.withSpan(of: index.valueViews[c]) { value in
                var start = 0
                while start <= value.count {
                    var end = start
                    while end < value.count, value[end] != 0x2C { end += 1 }
                    var s = start
                    var e = end
                    while s < e, value[s] == 0x20 || value[s] == 0x09 { s += 1 }
                    while e > s, value[e - 1] == 0x20 || value[e - 1] == 0x09 { e -= 1 }
                    if equalsCaseInsensitive(value.extracting(s..<e), name) { return true }
                    start = end + 1
                }
                return false
            }
            if found { return true }
            position = c + 1
        }
        return false
    }

    static func equalsCaseInsensitive(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where ASCII.lowercased(a[i]) != ASCII.lowercased(b[i]) { return false }
        return true
    }

    static func startsWithCaseInsensitive(_ bytes: Span<UInt8>, _ prefix: StaticString) -> Bool {
        prefix.withUTF8Buffer { p in
            guard bytes.count >= p.count else { return false }
            for i in 0..<p.count where ASCII.lowercased(bytes[i]) != p[i] { return false }
            return true
        }
    }

    /// `fields` without hop-by-hop fields, copied by bytes.
    static func stripHopByHop(_ fields: HTTPFields) -> HTTPFields {
        fields.withFieldStorage { index, arena in
            let hasConnection = index.contains(.connection)
            var out = HTTPFields(minimumCapacity: index.count, arenaCapacity: arena.readableBytes)
            for i in 0..<index.count where !isHopByHop(at: i, index: index, arena: arena, hasConnection: hasConnection) {
                out.append(i, of: fields)
            }
            return out
        }
    }

    /// The upstream request's fields: the client's without hop-by-hop fields, pseudo-headers,
    /// `Host`, `Expect` (the downstream protocol already answered it; see
    /// `UpstreamHTTP1Client`) and forwarded fields, then the forwarded fields the mount asks for.
    /// From a peer in `mount.trustedProxies` the incoming forwarded chain is kept and extended.
    static func requestHeaders(_ fields: HTTPFieldsView, mount: ProxyMount, clientHost: String?,
                               connection: ConnectionInfo) -> HTTPFields {
        let peer = connection.remoteAddress?.host
        let trusted = mount.trustedProxies.containsAddress(peer)
        var out = fields.withFieldStorage { index, arena in
            let hasConnection = index.contains(.connection)
            var out = HTTPFields(minimumCapacity: index.count + 4, arenaCapacity: arena.readableBytes + 128)
            for i in 0..<index.count {
                let name = index.names[i]
                switch name {
                case .host, .expect, .forwarded, .xForwardedFor, .xForwardedHost, .xForwardedProto: continue
                default: if name.isPseudoHeader { continue }
                }
                if name == .unknown,
                   arena.withSpan(of: index.nameViews[i], { ASCII.equalsCaseInsensitive($0, "x-forwarded-prefix") }) {
                    continue
                }
                if isHopByHop(at: i, index: index, arena: arena, hasConnection: hasConnection) { continue }
                out.append(i, of: fields)
            }
            return out
        }
        let proto: StaticString = connection.isSecure ? "https" : "http"
        switch mount.forwardedHeaders {
        case .xForwarded:
            appendXForwarded(&out, incoming: fields, trusted: trusted, peer: peer, proto: proto, host: clientHost, prefix: mount.path)
        case .forwarded:
            appendForwarded(&out, incoming: fields, trusted: trusted, peer: peer, proto: proto, host: clientHost)
        case .both:
            appendXForwarded(&out, incoming: fields, trusted: trusted, peer: peer, proto: proto, host: clientHost, prefix: mount.path)
            appendForwarded(&out, incoming: fields, trusted: trusted, peer: peer, proto: proto, host: clientHost)
        case .none:
            break
        }
        return out
    }

    static func appendXForwarded(_ out: inout HTTPFields, incoming: HTTPFieldsView, trusted: Bool, peer: String?,
                                 proto: StaticString, host: String?, prefix: String) {
        if trusted && incoming.contains(.xForwardedFor) {
            var chain = ByteBuffer()
            incoming.combinedValue(for: .xForwardedFor, into: &chain)
            if let peer {
                chain.append(", ")
                chain.append(contentsOf: peer.utf8)
            }
            chain.withReadableSpan { out.append(.xForwardedFor, value: $0) }
        } else if let peer {
            out.append(.xForwardedFor, string: peer)
        }
        if trusted, let i = incoming.firstIndex(named: "x-forwarded-proto") {
            out.append(i, of: incoming)
        } else {
            out.append(.xForwardedProto, proto)
        }
        if trusted, let i = incoming.firstIndex(named: "x-forwarded-host") {
            out.append(i, of: incoming)
        } else if let host {
            out.append(.xForwardedHost, string: host)
        }
        out.append(name: "X-Forwarded-Prefix", value: prefix)
    }

    /// RFC 7239 `Forwarded`: one element per proxy, appended to a trusted peer's list.
    static func appendForwarded(_ out: inout HTTPFields, incoming: HTTPFieldsView, trusted: Bool, peer: String?,
                                proto: StaticString, host: String?) {
        var value = ByteBuffer()
        if trusted, incoming.combinedValue(for: .forwarded, into: &value) > 0 {
            value.append(", ")
        }
        if let peer {
            value.append("for=")
            if peer.contains(":") {
                value.append("\"[")
                value.append(contentsOf: peer.utf8)
                value.append("]\"")
            } else {
                value.append(contentsOf: peer.utf8)
            }
            value.append(";")
        }
        value.append("proto=")
        value.append(proto)
        if let host {
            value.append(";host=\"")
            value.append(contentsOf: host.utf8)
            value.append("\"")
        }
        value.withReadableSpan { out.append(.forwarded, value: $0) }
    }

    /// `host[:port]` for a `Host` header naming the upstream.
    static func authority(of address: UpstreamAddress) -> String {
        switch address {
        case .tcp(let host, let port):
            let h = host.contains(":") ? "[\(host)]" : host
            return port == 80 ? h : "\(h):\(port)"
        case .unix:
            return "localhost"
        }
    }

    static func hostWithoutPort(_ host: String) -> String {
        if host.hasPrefix("[") {
            if let end = host.firstIndex(of: "]") { return String(host[...end]) }
            return host
        }
        if let colon = host.lastIndex(of: ":") { return String(host[..<colon]) }
        return host
    }
}

extension Substring {
    func trimmingSpaces() -> String {
        var s = self[...]
        while let f = s.first, f == " " || f == "\t" { s.removeFirst() }
        while let l = s.last, l == " " || l == "\t" { s.removeLast() }
        return String(s)
    }
}

enum ReverseProxyLocation {
    /// Rewrites absolute `Location`/`Content-Location` pointing at the upstream
    /// to the client-facing host, adding back a stripped prefix (ProxyPassReverse).
    static func rewrite(_ fields: HTTPFields, mount: ProxyMount, target: UpstreamTarget,
                        clientHost: String?, secure: Bool) -> HTTPFields {
        var out = HTTPFields()
        for i in 0..<fields.count {
            let name = fields.nameString(at: i)
            let lower = name.lowercased()
            let value = fields.valueString(at: i)
            if lower == "location" || lower == "content-location",
               let rewritten = rewriteValue(value, mount: mount, target: target,
                                            clientHost: clientHost, secure: secure) {
                out.append(name: name, value: rewritten)
            } else {
                out.append(name: name, value: value)
            }
        }
        return out
    }

    static func rewriteValue(_ value: String, mount: ProxyMount, target: UpstreamTarget,
                             clientHost: String?, secure: Bool) -> String? {
        let upstreamAuthority = ReverseProxyHeaders.authority(of: target.address)
        var authorities = [upstreamAuthority.lowercased()]
        if case .tcp(let host, let port) = target.address {
            authorities.append("\(host):\(port)".lowercased())
        }
        var upstreamPath: Substring?
        for scheme in ["http://", "https://"] where value.lowercased().hasPrefix(scheme) {
            let rest = value.dropFirst(scheme.count)
            let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
            let authority = rest[..<authorityEnd].lowercased()
            guard authorities.contains(authority) else { return nil }
            let path = rest[authorityEnd...]
            upstreamPath = path.isEmpty ? "/" : path
        }
        guard var path = upstreamPath else { return nil }
        var base = target.basePath
        while base.hasSuffix("/") { base.removeLast() }
        if !base.isEmpty {
            if !base.hasPrefix("/") { base = "/" + base }
            guard path.hasPrefix(base) else { return nil }
            path = path.dropFirst(base.count)
            if path.isEmpty || !(path.first == "/" || path.first == "?") {
                if !path.isEmpty { return nil }
                path = "/"
            }
        }
        var clientPath = String(path)
        if mount.stripPrefix {
            var prefix = mount.path
            while prefix.hasSuffix("/") { prefix.removeLast() }
            clientPath = prefix + clientPath
        }
        guard let clientHost else { return clientPath }
        return (secure ? "https://" : "http://") + clientHost + clientPath
    }

    /// The client-side path for an upstream path (`ProxyPassReverseCookiePath`): the target's
    /// base path removed, and with `stripPrefix` the mount prefix added back. Nil when the
    /// path is outside the base path.
    static func clientPath(forUpstreamPath path: Substring, mount: ProxyMount, target: UpstreamTarget) -> String? {
        var base = target.basePath
        while base.hasSuffix("/") { base.removeLast() }
        if !base.isEmpty, !base.hasPrefix("/") { base = "/" + base }
        var rest = path
        if !base.isEmpty {
            guard rest.hasPrefix(base) else { return nil }
            rest = rest.dropFirst(base.count)
            guard rest.isEmpty || rest.first == "/" else { return nil }
        }
        var prefix = mount.stripPrefix ? mount.path : ""
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if rest.isEmpty || rest == "/" { return prefix.isEmpty ? "/" : prefix }
        return prefix + rest
    }

    /// Rewrites the `Path` attribute of every `Set-Cookie` into the client's path space. Only
    /// does anything when paths differ (a stripped prefix or an upstream base path).
    static func rewriteCookiePaths(_ fields: HTTPFields, mount: ProxyMount, target: UpstreamTarget) -> HTTPFields {
        guard mount.stripPrefix || !target.basePath.isEmpty else { return fields }
        var out = HTTPFields()
        for i in 0..<fields.count {
            guard fields[i].name == .setCookie else {
                out.append(i, of: fields)
                continue
            }
            let value = fields.valueString(at: i)
            var attributes = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            for j in attributes.indices.dropFirst() {
                let attribute = attributes[j].drop(while: { $0 == " " })
                guard attribute.lowercased().hasPrefix("path=") else { continue }
                let path = attribute.dropFirst(5)
                if let mapped = clientPath(forUpstreamPath: path, mount: mount, target: target) {
                    attributes[j] = " Path=" + mapped
                }
            }
            out.append(.setCookie, string: attributes.joined(separator: ";"))
        }
        return out
    }
}
