#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import HTTPCore
import Proxy
import StaticFiles
import VirtualHosts

// The `hosts` key (#0092): several sites on one listener, each with its own root.

extension ServerSettings {
    /// One site of the `hosts` key.
    public struct HostSettings: Sendable, Equatable {
        /// Host names (`example.com`, `*.example.com`); matched without the port,
        /// case-insensitively. Punycode for internationalized names.
        public var names: [String]
        /// The site's root, relative to ``ServerSettings/baseDirectory``.
        public var root: String
        /// The site that answers unknown hosts and requests without one. At most one.
        public var isDefault: Bool
        /// Reverse-proxy mounts for this site only (#0124), in the same form as the top-level
        /// `proxy` key. They are tried before the server-level mounts for this site's requests.
        public var proxy: [ProxySettings]

        public init(names: [String], root: String, isDefault: Bool = false, proxy: [ProxySettings] = []) {
            self.names = names
            self.root = root
            self.isDefault = isDefault
            self.proxy = proxy
        }
    }

    /// The `VirtualHosts` for ``hosts``: each site is `StaticFiles` over its own root with the
    /// shared file settings. Unknown hosts get the default site or `421`.
    ///
    /// A site with `proxy` mounts (#0124) runs its own `ReverseProxy` first, then `serverProxy`
    /// (the top-level mounts, when given), then its files: the site's mounts take precedence
    /// over the server's for that site.
    func makeVirtualHosts(serverProxy: ReverseProxy? = nil,
                          client: UpstreamHTTP1Client? = nil) throws(ConfigFileError) -> VirtualHosts {
        var sites: [VirtualHost] = []
        for (offset, host) in hosts.enumerated() {
            let root = Self.resolve(host.root, against: baseDirectory)
            let key = "hosts[\(offset)].root"
            let files: StaticFiles
            do {
                files = try StaticFiles(root: root, configuration: staticFilesConfiguration)
            } catch {
                switch error {
                case .rootUnavailable(let code):
                    throw ConfigFileError(key: key, "cannot serve \(key) \(root): \(String(cString: strerror(code)))")
                case .rootNotADirectory:
                    throw ConfigFileError(key: key, "cannot serve \(key) \(root): not a directory")
                }
            }
            let siteProxy = host.proxy.isEmpty ? nil
                : ReverseProxy(mounts: host.proxy.map(\.mount), client: client ?? UpstreamHTTP1Client())
            // The server-level proxy is registered once, at the top of the chain
            // (`ProxyMountsLifecycle`); inside each site it only forwards.
            let shared = serverProxy.map(NestedReverseProxy.init)
            let sitePages = try siteErrorPages(root: root, offset: offset)
            if siteProxy == nil, shared == nil, sitePages == nil {
                sites.append(VirtualHost(host.names, isDefault: host.isDefault, handler: files))
            } else {
                sites.append(VirtualHost(host.names, isDefault: host.isDefault, handler: MiddlewareBuilder.build {
                    if let sitePages { sitePages }
                    if let siteProxy { siteProxy }
                    if let shared { shared }
                    ServerSettings.handler(files)
                }))
            }
        }
        do {
            return try VirtualHosts(sites)
        } catch {
            throw ConfigFileError(key: "hosts", "\"hosts\": \(error)")
        }
    }

    /// A site's `errorPages` files (#0129): each is looked up in the site's root first, then in
    /// the top-level ``root`` (which need not exist). `nil` unless `errorPages` names files.
    func siteErrorPages(root: String, offset: Int) throws(ConfigFileError) -> ErrorPages? {
        guard case .files(let map) = errorPages else { return nil }
        let roots = [root, resolvedRoot]
        do {
            return try ErrorPages(roots: roots, pages: map)
        } catch {
            switch error {
            case .pageUnavailable(let status, let code):
                throw ConfigFileError(key: "errorPages.\(status)",
                                      "\"errorPages.\(status)\": cannot read \(map[status] ?? "") under hosts[\(offset)].root \(root) or root \(resolvedRoot): \(String(cString: strerror(code)))")
            case .pageOutsideRoot(let status):
                throw ConfigFileError(key: "errorPages.\(status)",
                                      "\"errorPages.\(status)\": \(map[status] ?? "") is outside the root of hosts[\(offset)]")
            default:
                // The site root itself was already opened by `StaticFiles`.
                throw Self.describe(error, root: root, pages: map)
            }
        }
    }
}

extension Parser {
    /// `"hosts": [{"names": ["a.test", "*.a.test"], "root": "sites/a", "default": true,
    /// "proxy": [{"path": "/api", "upstream": "http://127.0.0.1:9000"}]}]`;
    /// `"name": "a.test"` is accepted for a single name.
    mutating func hosts(_ value: Any, _ key: String) throws(ConfigFileError) -> [ServerSettings.HostSettings] {
        guard let array = value as? [Any] else { throw fail(key, "must be an array of {\"names\", \"root\"} objects") }
        var result: [ServerSettings.HostSettings] = []
        for (offset, element) in array.enumerated() {
            let path = "\(key)[\(offset)]"
            let object = try dictionary(element, path)
            var names: [String] = []
            var root: String?
            var isDefault = false
            var proxy: [ServerSettings.ProxySettings] = []
            for name in object.keys.sorted() {
                let field = "\(path).\(name)"
                let item = object[name]!
                switch name {
                case "names": names += try strings(item, field)
                case "name": names.append(try string(item, field))
                case "root":
                    let text = try string(item, field)
                    guard !text.isEmpty else { throw fail(field, "must not be empty") }
                    root = text
                case "default": isDefault = try bool(item, field)
                case "proxy": proxy = try self.proxy(item, field)
                default: warn("unknown key \"\(field)\" ignored")
                }
            }
            guard let root else { throw fail("\(path).root", "must be set to the site's directory") }
            guard !names.isEmpty || isDefault else { throw fail("\(path).names", "must list at least one host name (or set \"default\": true)") }
            result.append(ServerSettings.HostSettings(names: names, root: root, isDefault: isDefault, proxy: proxy))
        }
        if result.filter(\.isDefault).count > 1 { throw fail(key, "may have only one \"default\": true site") }
        // Check the names now, so a bad one fails the file like any other bad value.
        do {
            _ = try VirtualHosts(result.map { VirtualHost($0.names, isDefault: $0.isDefault, handler: NotFoundHandler()) })
        } catch {
            throw fail(key, "is invalid: \(error)")
        }
        return result
    }
}

/// The top-level `ReverseProxy` when sites also have mounts: it forwards nothing itself
/// (each site runs it after its own mounts, through ``NestedReverseProxy``), but it is the one
/// place the server finds it, so its health checks and idle sweep run once.
struct ProxyMountsLifecycle: HTTPMiddleware, MiddlewareChainContainer {
    let proxy: ReverseProxy

    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
    }

    func forEachChainElement(_ body: (Any) -> Void) { body(proxy) }
}

/// The server-level `ReverseProxy` inside a site's chain: forwards like it, but is neither a
/// component nor a container, so the server does not run it once per site.
struct NestedReverseProxy: HTTPMiddleware {
    let proxy: ReverseProxy

    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await proxy.handle(request, context: context, next: next)
    }
}
