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
    public func makeHandler(environment: [String: String] = [:]) throws(ConfigFileError) -> some HTTPHandler {
        let authenticator = try makeAuthenticator(environment: environment)
        let root = resolvedRoot
        // `StaticFiles` is both a handler and a middleware; as the last element it must be the
        // handler, so it goes in through `EitherHandler`.
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
            terminal = .first(try makeVirtualHosts())
        }
        let pages: ErrorPages?
        switch errorPages {
        case .off:
            pages = nil
        case .generated:
            pages = ErrorPages()
        case .files(let map):
            do {
                pages = try ErrorPages(root: root, pages: map)
            } catch {
                throw Self.describe(error, root: root, pages: map)
            }
        }
        // #0091: outermost, so generated error pages are compressed too.
        let compressor = compression.map { Compression(configuration: $0.configuration) }
        let mounts = proxyMounts
        let reverseProxy = mounts.isEmpty ? nil : ReverseProxy(mounts: mounts, client: UpstreamHTTP1Client())
        return MiddlewareBuilder.build {
            if let compressor { compressor }
            if let pages { pages }
            if let authenticator { authenticator }
            // #0124: after auth, before the static files terminal.
            if let reverseProxy { reverseProxy }
            terminal
        }
    }

    static func handler(_ handler: some HTTPHandler) -> some HTTPHandler { handler }

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
