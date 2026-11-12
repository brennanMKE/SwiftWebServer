#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public import HTTP1
public import HTTPCore
public import HTTPServer
public import StaticFiles

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
        return configuration
    }

    /// The request handler: `ErrorPages` (unless turned off) in front of `StaticFiles` serving
    /// ``resolvedRoot``. `StaticFiles` evaluates conditional requests itself
    /// (`ConditionalRequest`, RFC 9110 order). Throws when the root or an error page file
    /// cannot be used, with a message naming it.
    public func makeHandler() throws(ConfigFileError) -> some HTTPHandler {
        let root = resolvedRoot
        let files: StaticFiles
        do {
            files = try StaticFiles(root: root, configuration: staticFilesConfiguration)
        } catch {
            switch error {
            case .rootUnavailable(let code):
                throw ConfigFileError(key: "root", "cannot serve root \(root): \(String(cString: strerror(code)))")
            case .rootNotADirectory:
                throw ConfigFileError(key: "root", "cannot serve root \(root): not a directory")
            }
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
        // `StaticFiles` is both a handler and a middleware; as the last element it must be the
        // handler, so it goes in as an opaque `some HTTPHandler`.
        let terminal = Self.handler(files)
        return MiddlewareBuilder.build {
            if let pages { pages }
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
