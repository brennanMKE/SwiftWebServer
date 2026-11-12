#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public import HTTP1
public import HTTPCore
public import HTTPServer
public import StaticFiles
import Compression
import VirtualHosts
import Auth
import Proxy
import AccessLog

// Settings to the server's configuration values and middleware chain (docs/ROADMAP.md §5.2).
// Components are registered with the middleware builder only when enabled, so a disabled
// feature is not in the compiled chain at all.

extension ServerSettings {
    /// Connection limit and drain grace period for `Server`.
    public var serverConfiguration: ServerConfiguration {
        ServerConfiguration(maxConnections: maxConnections, drainTimeout: drainTimeout)
    }

    /// Body limit and timeouts for `HTTP1`.
    public var http1Configuration: HTTP1Configuration {
        HTTP1Configuration(
            maxBodySize: maxBodySize,
            timeouts: HTTP1Timeouts(header: timeouts.header, idle: timeouts.idle, body: timeouts.body,
                                    send: timeouts.send, linger: timeouts.linger))
    }

    /// Index files, block list, MIME types and caching for `StaticFiles`.
    public var staticFilesConfiguration: StaticFilesConfiguration {
        var configuration = StaticFilesConfiguration()
        configuration.indexFiles = index
        configuration.blockedNames = blockList
        configuration.blockDotfiles = blockDotfiles
        configuration.defaultMIMEType = defaultMimeType
        configuration.mimeTypes = mimeTypes
        configuration.maxAge = maxAge
        if let compression, compression.precompress || compression.sidecars {
            var precompression = compression.configuration
            // Sidecars only: nothing is compressed by the cache itself.
            if !compression.precompress { precompression.minimumSize = .max }
            configuration.compression = precompression
            configuration.precompressedSidecars = compression.sidecars
        }
        return configuration
    }

    /// The request handler: `ErrorPages` (unless turned off) in front of `StaticFiles` serving
    /// ``resolvedRoot``. `StaticFiles` evaluates conditional requests itself
    /// (`ConditionalRequest`, RFC 9110 order). Throws when the root or an error page file
    /// cannot be used, with a message naming it.
    ///
    /// With ``hosts`` set, `VirtualHosts` takes the place of the single `StaticFiles` (#0092)
    /// and ``root`` is not opened. With ``auth`` set, an `Authenticator` (#0093) sits between
    /// `ErrorPages` and the files; `environment` supplies `secretEnv`/`usersEnv` values.
    ///
    /// The `proxy` mounts (#0124) sit after auth and before the files. With `hosts[].proxy`,
    /// each site runs its own mounts first, then the server-level ones, then its files.
    public func makeHandler(environment: [String: String] = [:]) throws(ConfigFileError) -> some HTTPHandler {
        let authenticator = try makeAuthenticator(environment: environment)
        let (accessLog, metricsEndpoint) = try makeAccessLog()
        let root = resolvedRoot
        // `StaticFiles` is both a handler and a middleware; as the last element it must be the
        // handler, so it goes in through `EitherHandler`.
        // #0124: one upstream client (and pool) for every mount, server-level and per site.
        let mounts = proxyMounts
        let siteMounts = hosts.contains { !$0.proxy.isEmpty }
        let client = mounts.isEmpty && !siteMounts ? nil : UpstreamHTTP1Client(configuration: upstreamClientConfiguration)
        let serverProxy = mounts.isEmpty ? nil : client.map { ReverseProxy(mounts: mounts, client: $0) }
        let terminal: EitherHandler<VirtualHosts, StaticFiles>
        if hosts.isEmpty {
            do {
                terminal = .second(try StaticFiles(root: root, configuration: staticFilesConfiguration))
            } catch {
                switch error {
                case .rootUnavailable(let code):
                    throw ConfigFileError(key: "root", "cannot serve root \(root): \(String(cString: strerror(code)))")
                case .rootNotADirectory:
                    throw ConfigFileError(key: "root", "cannot serve root \(root): not a directory")
                }
            }
        } else {
            // With per-site mounts, the server-level mounts run inside each site after the site's.
            terminal = .first(try makeVirtualHosts(serverProxy: siteMounts ? serverProxy : nil, client: client))
        }
        let pages: ErrorPages?
        switch errorPages {
        case .off:
            pages = nil
        case .generated:
            pages = ErrorPages()
        case .files(let map) where !hosts.isEmpty:
            // #0129: each site renders its own pages (ConfigFile+Hosts); this outer layer covers
            // what no site answers (`421`, auth) from the top-level root when it has the files,
            // generated pages otherwise. That root need not exist.
            pages = (try? ErrorPages(roots: [root], pages: map, requireAll: false)) ?? ErrorPages()
        case .files(let map):
            do {
                pages = try ErrorPages(root: root, pages: map)
            } catch {
                throw Self.describe(error, root: root, pages: map)
            }
        }
        // #0091: outermost, so generated error pages are compressed too.
        let compressor = compression.map { Compression(configuration: $0.configuration) }
        let reverseProxy = siteMounts ? nil : serverProxy
        let lifecycle = siteMounts ? serverProxy.map(ProxyMountsLifecycle.init) : nil
        return MiddlewareBuilder.build {
            // #0125: outermost, so it records final statuses (error pages, auth, proxy).
            if let accessLog { accessLog }
            if let metricsEndpoint { metricsEndpoint }
            if let compressor { compressor }
            if let pages { pages }
            if let authenticator { authenticator }
            // #0124: after auth, before the static files terminal.
            if let reverseProxy { reverseProxy }
            if let lifecycle { lifecycle }
            terminal
        }
    }

    static func handler(_ handler: some HTTPHandler) -> some HTTPHandler { handler }

    /// The shared upstream client's settings. The client caps every mount's `pool.maxIdle` at
    /// its own per-target limit (default 16), so that limit is raised to the largest
    /// configured `maxIdle`; otherwise a larger setting would be silently ignored.
    var upstreamClientConfiguration: UpstreamHTTP1Client.Configuration {
        let configured = (proxy + hosts.flatMap(\.proxy)).map(\.pool.maxIdle).max() ?? 0
        return UpstreamHTTP1Client.Configuration(maxIdlePerTarget: max(configured, UpstreamPoolPolicy().maxIdle))
    }

    static func describe(_ error: ErrorPages.InitError, root: String, pages: [Int: String]) -> ConfigFileError {
        switch error {
        case .rootUnavailable(let code):
            return ConfigFileError(key: "root", "cannot serve root \(root): \(String(cString: strerror(code)))")
        case .invalidStatus(let status):
            return ConfigFileError(key: "errorPages.\(status)", "\"errorPages.\(status)\" is not a status code from 400 to 599")
        case .pageUnavailable(let status, let code):
            return ConfigFileError(key: "errorPages.\(status)",
                                   "\"errorPages.\(status)\": cannot read \(pages[status] ?? "") under \(root): \(String(cString: strerror(code)))")
        case .pageOutsideRoot(let status):
            return ConfigFileError(key: "errorPages.\(status)",
                                   "\"errorPages.\(status)\": \(pages[status] ?? "") is outside the root \(root)")
        }
    }
}
