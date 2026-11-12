import Foundation
public import Proxy

// The `proxy` key (#0124): reverse-proxy mounts. Parsed and validated here; the `ReverseProxy`
// component (#0121) serves them once it lands.

extension ServerSettings {
    /// One mount of the `proxy` key: the ``ProxyMount`` fields plus settings stored for later.
    public struct ProxySettings: Sendable, Equatable {
        /// Upstream timeouts (#0122). `nil` uses the ``UpstreamTimeouts`` default (no limit for
        /// `total`).
        public struct Timeouts: Sendable, Equatable {
            public var connect: Duration?
            public var response: Duration?
            public var idle: Duration?
            public var total: Duration?
            public init(connect: Duration? = nil, response: Duration? = nil, idle: Duration? = nil,
                        total: Duration? = nil) {
                self.connect = connect
                self.response = response
                self.idle = idle
                self.total = total
            }
        }

        public var path = "/"
        public var hosts: [String] = []
        public var upstreams: [UpstreamTarget] = []
        public var stripPrefix = false
        public var preserveHost = false
        public var forwardedHeaders: ProxyMount.ForwardedHeaders = .xForwarded
        public var rewriteLocation = true
        public var websocket = false
        public var timeouts = Timeouts()
        /// Extra attempts after a connect failure, idempotent methods only (#0122).
        public var retries = 1
        /// Passive and active upstream health (#0122).
        public var health = UpstreamHealthPolicy()

        public init() {}

        /// Timeouts, retries and health for the `ReverseProxy` component.
        public var policy: UpstreamPolicy {
            let defaults = UpstreamTimeouts()
            let limits = UpstreamTimeouts(connect: timeouts.connect ?? defaults.connect,
                                          response: timeouts.response ?? defaults.response,
                                          idle: timeouts.idle ?? defaults.idle,
                                          total: timeouts.total)
            return UpstreamPolicy(timeouts: limits, retries: retries, health: health,
                                  tunnelIdleTimeout: timeouts.idle)
        }

        /// The mount for the `ReverseProxy` component.
        public var mount: ProxyMount {
            var mount = ProxyMount(path: path, hosts: hosts, upstreams: upstreams, stripPrefix: stripPrefix,
                                   preserveHost: preserveHost, forwardedHeaders: forwardedHeaders,
                                   rewriteLocation: rewriteLocation, websocket: websocket)
            mount.policy = policy
            return mount
        }
    }

    /// The configured mounts, in file order.
    public var proxyMounts: [ProxyMount] { proxy.map(\.mount) }
}

extension Parser {
    /// `"proxy": [{"path": "/api", "upstream": "http://127.0.0.1:9000", "stripPrefix": false,
    /// "preserveHost": false, "forwardedHeaders": "x-forwarded", "rewriteLocation": true,
    /// "websocket": false, "timeouts": {"connect": 2, "response": 30, "idle": 60, "total": 120},
    /// "retries": 1, "health": {"failures": 3, "cooldown": 10, "path": "/health", "interval": 10}}]`;
    /// a single object is accepted too.
    mutating func proxy(_ value: Any, _ key: String) throws(ConfigFileError) -> [ServerSettings.ProxySettings] {
        let elements: [Any]
        if let array = value as? [Any] { elements = array } else { elements = [try dictionary(value, key, expectation: "must be an object or an array of objects")] }
        var result: [ServerSettings.ProxySettings] = []
        var seen: [(path: String, hosts: Set<String>, key: String)] = []
        for (offset, element) in elements.enumerated() {
            let path = value is [Any] ? "\(key)[\(offset)]" : key
            let object = try dictionary(element, path)
            var mount = ServerSettings.ProxySettings()
            if object["upstream"] != nil, object["upstreams"] != nil {
                throw fail(path, "needs \"upstream\" or \"upstreams\", not both")
            }
            if object["host"] != nil, object["hosts"] != nil {
                throw fail(path, "needs \"host\" or \"hosts\", not both")
            }
            for name in object.keys.sorted() {
                let field = "\(path).\(name)"
                let item = object[name]!
                switch name {
                case "path":
                    let prefix = try string(item, field)
                    guard prefix.hasPrefix("/") else { throw fail(field, "must start with \"/\"") }
                    mount.path = prefix
                case "host":
                    let host = try string(item, field)
                    guard !host.isEmpty else { throw fail(field, "must not be empty") }
                    mount.hosts = [host]
                case "hosts":
                    let hosts = try strings(item, field)
                    guard !hosts.contains(where: \.isEmpty) else { throw fail(field, "must not contain empty names") }
                    mount.hosts = hosts
                case "upstream":
                    mount.upstreams = [try upstream(item, field)]
                case "upstreams":
                    guard let array = item as? [Any], !array.isEmpty else {
                        throw fail(field, "must be a non-empty array of http://host:port or unix:/path")
                    }
                    for (index, entry) in array.enumerated() {
                        mount.upstreams.append(try upstream(entry, "\(field)[\(index)]"))
                    }
                case "stripPrefix": mount.stripPrefix = try bool(item, field)
                case "preserveHost": mount.preserveHost = try bool(item, field)
                case "forwardedHeaders":
                    let text = try string(item, field)
                    guard let mode = ProxyMount.ForwardedHeaders(rawValue: text) else {
                        throw fail(field, "must be one of \"x-forwarded\", \"forwarded\", \"both\", \"none\"")
                    }
                    mount.forwardedHeaders = mode
                case "rewriteLocation": mount.rewriteLocation = try bool(item, field)
                case "websocket": mount.websocket = try bool(item, field)
                case "timeouts":
                    let timeouts = try dictionary(item, field)
                    for timeoutName in timeouts.keys.sorted() {
                        let timeoutField = "\(field).\(timeoutName)"
                        let seconds = try seconds(timeouts[timeoutName]!, timeoutField)
                        switch timeoutName {
                        case "connect": mount.timeouts.connect = seconds
                        case "response": mount.timeouts.response = seconds
                        case "idle": mount.timeouts.idle = seconds
                        case "total": mount.timeouts.total = seconds
                        default: warn("unknown key \"\(timeoutField)\" ignored")
                        }
                    }
                case "retries": mount.retries = try integer(item, field, in: 0...10)
                case "health": mount.health = try health(item, field)
                default:
                    warn("unknown key \"\(field)\" ignored")
                }
            }
            guard !mount.upstreams.isEmpty else { throw fail(path, "needs \"upstream\" or \"upstreams\"") }
            // Duplicates: the same prefix twice for any host, or for overlapping host names. A
            // host-specific mount next to an any-host mount of the same prefix is allowed.
            let hosts = Set(mount.hosts.map { $0.lowercased() })
            if let earlier = seen.first(where: { $0.path == mount.path && ($0.hosts == hosts || !$0.hosts.isDisjoint(with: hosts)) }) {
                throw fail("\(path).path", "duplicates the mount at \(earlier.key) (\"\(mount.path)\")")
            }
            seen.append((mount.path, hosts, path))
            result.append(mount)
        }
        return result
    }

    /// `{"failures": 3, "cooldown": 10, "path": "/health", "interval": 10}` (#0122): passive
    /// tracking marks an upstream down for `cooldown` seconds after `failures` consecutive
    /// failures (`0` turns it off); with `path`, an active `GET` every `interval` seconds.
    mutating func health(_ value: Any, _ key: String) throws(ConfigFileError) -> UpstreamHealthPolicy {
        let object = try dictionary(value, key)
        var policy = UpstreamHealthPolicy()
        for name in object.keys.sorted() {
            let field = "\(key).\(name)"
            let item = object[name]!
            switch name {
            case "failures": policy.maxFailures = try integer(item, field, in: 0...1000)
            case "cooldown":
                policy.cooldown = try seconds(item, field, zeroMeansOff: false) ?? .zero
            case "path":
                let path = try string(item, field)
                guard path.hasPrefix("/") else { throw fail(field, "must start with \"/\"") }
                policy.checkPath = path
            case "interval":
                guard let interval = try seconds(item, field) else { throw fail(field, "must be a positive number of seconds") }
                policy.checkInterval = interval
            default: warn("unknown key \"\(field)\" ignored")
            }
        }
        return policy
    }

    /// `http://HOST:PORT[/base]` or `unix:/path/to.sock`.
    func upstream(_ value: Any, _ key: String) throws(ConfigFileError) -> UpstreamTarget {
        let text = try string(value, key)
        let expectation = "must be http://host:port or unix:/path"
        if text.lowercased().hasPrefix("https://") {
            throw fail(key, "uses https, which is not supported for upstreams yet; use http://host:port or unix:/path")
        }
        if text.hasPrefix("unix:") {
            let path = String(text.dropFirst("unix:".count))
            guard path.hasPrefix("/"), path.count > 1 else { throw fail(key, expectation) }
            return UpstreamTarget(address: .unix(path: path))
        }
        guard text.lowercased().hasPrefix("http://") else { throw fail(key, expectation) }
        let rest = text.dropFirst("http://".count)
        let authority: Substring
        var base = ""
        if let slash = rest.firstIndex(of: "/") {
            authority = rest[..<slash]
            base = String(rest[slash...])
            while base.hasSuffix("/") { base.removeLast() }
        } else {
            authority = rest
        }
        guard !base.contains("?"), !base.contains("#"), !authority.contains("@") else { throw fail(key, expectation) }
        let host: Substring
        let portText: Substring
        if authority.hasPrefix("[") {
            // IPv6 literal: [::1]:9000
            guard let close = authority.firstIndex(of: "]") else { throw fail(key, expectation) }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            guard after.hasPrefix(":") else { throw fail(key, expectation) }
            portText = after.dropFirst()
        } else {
            guard let colon = authority.lastIndex(of: ":") else { throw fail(key, expectation) }
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        }
        guard !host.isEmpty, !host.contains(":") || authority.hasPrefix("["),
              let port = UInt16(portText), port > 0 else {
            throw fail(key, expectation)
        }
        return UpstreamTarget(address: .tcp(host: String(host), port: port), basePath: base)
    }
}
