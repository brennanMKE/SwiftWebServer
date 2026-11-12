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

    static func stripHopByHop(_ fields: HTTPFields) -> HTTPFields {
        let tokens = connectionTokens(fields)
        var out = HTTPFields()
        for i in 0..<fields.count {
            let name = fields.nameString(at: i)
            if isHopByHop(name.lowercased(), connectionTokens: tokens) { continue }
            out.append(name: name, value: fields.valueString(at: i))
        }
        return out
    }

    static func requestHeaders(_ fields: HTTPFieldsView, mount: ProxyMount, clientHost: String?,
                               connection: ConnectionInfo) -> HTTPFields {
        let tokens = connectionTokens(fields)
        var out = HTTPFields()
        for i in 0..<fields.count {
            let name = fields.nameString(at: i)
            let lower = name.lowercased()
            if isHopByHop(lower, connectionTokens: tokens) || replaced.contains(lower) { continue }
            if lower.hasPrefix(":") { continue }
            out.append(name: name, value: fields.valueString(at: i))
        }
        let peer = connection.remoteAddress?.host
        let proto = connection.isSecure ? "https" : "http"
        switch mount.forwardedHeaders {
        case .xForwarded:
            appendXForwarded(&out, peer: peer, proto: proto, host: clientHost, prefix: mount.path)
        case .forwarded:
            appendForwarded(&out, peer: peer, proto: proto, host: clientHost)
        case .both:
            appendXForwarded(&out, peer: peer, proto: proto, host: clientHost, prefix: mount.path)
            appendForwarded(&out, peer: peer, proto: proto, host: clientHost)
        case .none:
            break
        }
        return out
    }

    static func appendXForwarded(_ out: inout HTTPFields, peer: String?, proto: String,
                                 host: String?, prefix: String) {
        if let peer { out.append(name: "X-Forwarded-For", value: peer) }
        out.append(name: "X-Forwarded-Proto", value: proto)
        if let host { out.append(name: "X-Forwarded-Host", value: host) }
        out.append(name: "X-Forwarded-Prefix", value: prefix)
    }

    /// RFC 7239 `Forwarded`.
    static func appendForwarded(_ out: inout HTTPFields, peer: String?, proto: String, host: String?) {
        var parts: [String] = []
        if let peer {
            parts.append(peer.contains(":") ? "for=\"[\(peer)]\"" : "for=\(peer)")
        }
        parts.append("proto=\(proto)")
        if let host { parts.append("host=\"\(host)\"") }
        out.append(name: "Forwarded", value: parts.joined(separator: ";"))
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
}
