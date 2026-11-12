#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Compression
public import HTTPCore

/// Serves files under a root directory (#0084, docs/ROADMAP.md §5.2).
///
/// - The request path is percent-decoded once, only when it contains `%`; NUL, `\`, an
///   encoded `/` and bad escapes answer `400`, and a `..` component answers `403` (#0015).
/// - The decoded path is canonicalized with `realpath`; a target outside the root answers
///   `403` under the default ``StaticFilesConfiguration/SymlinkPolicy/followWithinRoot`` (#0014).
/// - Blocked names and dotfiles answer `403` wherever they appear in the requested or the
///   canonical path, in any case (#0013).
/// - A directory without a trailing `/` gets `301` to add it; with one, its index file is
///   served (no listings).
/// - Only `GET` and `HEAD`: anything else gets `405` with `Allow: GET, HEAD` (#0022).
/// - `ETag` is strong, `"<size-hex>-<mtime-ns-hex>-<inode-hex>"`, and `Last-Modified` is the
///   mtime in whole seconds; file content is never hashed (#0025).
/// - One `Range: bytes=` range answers `206` with `Content-Range`, an unsatisfiable one `416`;
///   several ranges are ignored (`200`). `If-Range` with a different validator disables Range.
/// - Conditional requests follow RFC 9110 §13.2.2 (``ConditionalRequest``, #0085): `If-Match`,
///   `If-Unmodified-Since`, `If-None-Match`, `If-Modified-Since`, then `If-Range`. A `304`
///   carries `ETag`, `Last-Modified` and `Cache-Control` and no body; a failed `If-Match` or
///   `If-Unmodified-Since` answers `412`. Dates compare in whole seconds (#0017).
/// - With ``StaticFilesConfiguration/compression`` (#0091), `br` and `gzip` variants are
///   rendered once per cached file (or read from `.br`/`.gz` sidecars) and chosen per request
///   from `Accept-Encoding`; preconditions are then evaluated against the variant's suffixed
///   `ETag`.
///
/// ## Hot path
///
/// Resolved files are cached by raw request path (``StaticFilesConfiguration/maxCachedEntries``).
/// A hit hashes the path bytes, takes one shard lock and returns a stored response: small
/// files (≤ ``StaticFilesConfiguration/smallFileLimit``) as bytes in memory, larger ones as a
/// ``FileRegion`` over a descriptor the entry keeps open. No allocation, no system call, no
/// `String`. Every ``StaticFilesConfiguration/revalidationInterval`` an entry is re-checked
/// with `realpath` and `stat`, and rebuilt if the file changed.
///
/// As an ``HTTPMiddleware`` it falls through to `next` for methods other than `GET` and
/// `HEAD` and for paths it has no file for; refusals (`400`, `403`) are still answered here.
public struct StaticFiles: HTTPHandler, HTTPMiddleware {
    public enum InitError: Error, Equatable {
        /// The root could not be canonicalized (`errno`).
        case rootUnavailable(errno: Int32)
        /// The root is not a directory.
        case rootNotADirectory
    }

    final class Core: Sendable {
        let resolver: PathResolver
        let cache: FileCache?
        let defaultMIMEType: [UInt8]
        let customMIMETypes: [(ext: [UInt8], type: [UInt8])]
        let cacheControl: [UInt8]?
        let smallFileLimit: Int
        let precompression: Precompression?

        init(resolver: PathResolver, configuration: StaticFilesConfiguration) {
            self.resolver = resolver
            cache = configuration.maxCachedEntries > 0
                ? FileCache(maxEntries: configuration.maxCachedEntries,
                            revalidationInterval: configuration.revalidationInterval)
                : nil
            defaultMIMEType = Array(configuration.defaultMIMEType.utf8)
            customMIMETypes = configuration.mimeTypes.map { (Array($0.key.utf8).map(ASCII.lowercased), Array($0.value.utf8)) }
            cacheControl = configuration.effectiveCacheControl.map { Array($0.utf8) }
            smallFileLimit = configuration.smallFileLimit
            precompression = configuration.compression.map {
                Precompression($0, sidecars: configuration.precompressedSidecars)
            }
        }
    }

    let core: Core

    /// The canonical root every file is served from.
    public var root: String { String(decoding: core.resolver.root, as: UTF8.self) }

    /// Serves the directory `root` (canonicalized now, so later changes to links in the
    /// root's own path do not move it).
    public init(root: String, configuration: StaticFilesConfiguration = StaticFilesConfiguration()) throws(InitError) {
        guard let real = PathResolver.realPath(Array(root.utf8)) else { throw .rootUnavailable(errno: errno) }
        var info = stat()
        guard PathResolver.withCString(real, { stat($0, &info) }) == 0 else { throw .rootUnavailable(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .rootNotADirectory }
        core = Core(resolver: PathResolver(root: real, configuration: configuration), configuration: configuration)
    }

    // MARK: HTTPHandler and HTTPMiddleware

    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        respond(to: request) ?? Self.notFound
    }

    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        guard request.method == .get || request.method == .head else {
            return try await next.handle(request, context: context)
        }
        if let response = respond(to: request) { return response }
        return try await next.handle(request, context: context)
    }

    /// The response for `request`, or `nil` when there is no file for its path (`404`).
    /// Synchronous; `handle` adds nothing but the `404`.
    public func respond(to request: HTTPRequest) -> HTTPResponse? {
        let isGet: Bool
        switch request.method {
        case .get: isGet = true
        case .head: isGet = false
        default: return Self.methodNotAllowed
        }
        let entry: CachedFile
        switch cachedOrResolved(request) {
        case .file(let file): entry = file
        case .response(let response): return response
        case .notFound: return nil
        }
        // Precompressed variants (#0091): negotiated per request, rendered once; equal weights
        // get the smallest variant. A Range request is answered from the unencoded file.
        if !entry.variants.isEmpty, request.headers.contains(.acceptEncoding),
           !(isGet && request.headers.contains(.range)),
           let variant = entry.selectVariant(AcceptEncoding.weights(request.headers)) {
            if ConditionalRequest.hasPreconditions(request.headers) {
                switch ConditionalRequest.evaluate(method: request.method, fields: request.headers,
                                                   etag: variant.etag, lastModified: entry.lastModifiedSeconds) {
                case .proceed: break
                case .notModified: return variant.notModified
                case .preconditionFailed: return Self.preconditionFailed
                }
            }
            return variant.response
        }
        if ConditionalRequest.hasPreconditions(request.headers) {
            switch ConditionalRequest.evaluate(method: request.method, fields: request.headers,
                                               etag: entry.etag, lastModified: entry.lastModifiedSeconds) {
            case .proceed: break
            case .notModified: return entry.notModified
            case .preconditionFailed: return Self.preconditionFailed
            }
        }
        guard isGet, let range = request.headers.firstValue(for: .range) else { return entry.response }
        if !ConditionalRequest.ifRangeAllowsRange(fields: request.headers, etag: entry.etag,
                                                  lastModified: entry.lastModifiedSeconds) {
            return entry.response
        }
        switch request.withSpan(of: range, { RangeRequest.parse($0, size: entry.size) }) {
        case .full: return entry.response
        case .partial(let offset, let length): return entry.partial(offset: offset, length: length)
        case .unsatisfiable: return entry.unsatisfiable()
        }
    }

    enum Outcome {
        case file(CachedFile)
        case response(HTTPResponse)
        case notFound
    }

    func cachedOrResolved(_ request: HTTPRequest) -> Outcome {
        let core = core
        guard let cache = core.cache else {
            return request.withSpan(of: request.path) { raw in
                request.withSpan(of: request.query) { query in resolve(raw, query: query, stale: nil) }
            }
        }
        let now = FileCache.now()
        let hash = request.withSpan(of: request.path) { FileCache.hash($0) }
        var stale: CachedFile?
        switch cache.lookup(hash, now: now) {
        case .hit(let file):
            if request.withSpan(of: request.path, { file.hasKey($0) }) { return .file(file) }
        case .stale(let file):
            if request.withSpan(of: request.path, { file.hasKey($0) }) { stale = file }
        case .miss:
            break
        }
        let outcome = request.withSpan(of: request.path) { raw in
            request.withSpan(of: request.query) { query in resolve(raw, query: query, stale: stale) }
        }
        switch outcome {
        case .file(let file):
            if file !== stale { cache.insert(hash, file, now: now) }
        case .response, .notFound:
            if stale != nil { cache.remove(hash) }
        }
        return outcome
    }

    /// The cold path: resolve, then reuse `stale` if the file is unchanged or open it anew.
    func resolve(_ raw: Span<UInt8>, query: Span<UInt8>, stale: CachedFile?) -> Outcome {
        switch core.resolver.resolve(path: raw, query: query) {
        case .file(let path, let name, let identity):
            if let stale, stale.identity == identity { return .file(stale) }
            var key = [UInt8]()
            key.reserveCapacity(raw.count)
            for i in 0..<raw.count { key.append(raw[i]) }
            let contentType = mimeType(forName: name)
            do {
                let file = try contentType.withUnsafeBufferPointer { type throws(CachedFile.OpenError) in
                    try CachedFile(key: key, path: path, contentType: type.span,
                                   cacheControl: core.cacheControl, smallFileLimit: core.smallFileLimit,
                                   precompression: core.precompression)
                }
                return .file(file)
            } catch .forbidden {
                return .response(Self.forbidden)
            } catch {
                return .notFound
            }
        case .redirect(let location):
            var headers = HTTPFields(minimumCapacity: 1, arenaCapacity: location.count)
            location.withUnsafeBufferPointer { headers.append(.location, value: $0.span) }
            return .response(HTTPResponse(status: .movedPermanently, headers: headers))
        case .notFound:
            return .notFound
        case .forbidden:
            return .response(Self.forbidden)
        case .badRequest:
            return .response(Self.badRequest)
        }
    }

    /// The `Content-Type` for a file named `name`: configured types, then ``MIMETypes``,
    /// then the configured default.
    func mimeType(forName name: [UInt8]) -> [UInt8] {
        name.withUnsafeBufferPointer { buffer in
            let span = buffer.span
            let ext = span.extracting(MIMETypes.extensionRange(of: span))
            for custom in core.customMIMETypes where custom.ext.count == ext.count {
                var same = true
                for i in 0..<ext.count where ASCII.lowercased(ext[i]) != custom.ext[i] { same = false; break }
                if same { return custom.type }
            }
            if let known = MIMETypes.lookup(extension: ext) {
                return known.withUTF8Buffer { Array($0) }
            }
            return core.defaultMIMEType
        }
    }

    /// Number of cached entries (for tests and diagnostics).
    public var cachedEntryCount: Int { core.cache?.count ?? 0 }

    // MARK: Fixed responses

    static let methodNotAllowed: HTTPResponse = {
        var headers = HTTPFields()
        headers.append(.allow, "GET, HEAD")
        return HTTPResponse(status: .methodNotAllowed, headers: headers)
    }()
    static let notFound = HTTPResponse(status: .notFound)
    static let forbidden = HTTPResponse(status: .forbidden)
    static let badRequest = HTTPResponse(status: .badRequest)
    static let preconditionFailed = HTTPResponse(status: .preconditionFailed)
}
