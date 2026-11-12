#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public import HTTPCore

/// Middleware that gives `4xx` and `5xx` responses without content an HTML body (#0085, #0018).
///
/// The page is an explicit layer, not something every response gets: it only fills a body the
/// handler left empty. It never touches
///
/// - statuses outside `400...599` (so never `1xx`, `204` or `304`, which carry no content),
/// - responses to `HEAD` (they carry no content; the handler's fields pass through),
/// - responses whose body is not ``HTTPResponseBody/empty``, or that state a `Content-Length`
///   (the handler chose the content).
///
/// The handler's fields are kept (`Allow` on a `405`, `Content-Range` on a `416`) and the page
/// sets `Content-Type`. By default the body is a small generated page, `<h1>404 Not Found</h1>`;
/// ``init(root:pages:defaultPages:)`` replaces it per status with a file under a root
/// directory, read once at startup.
///
/// ```swift
/// let pages = try ErrorPages(root: "Root/Public", pages: [404: "errors/404.html"])
/// ```
public struct ErrorPages: HTTPMiddleware {
    public enum InitError: Error, Equatable {
        /// The root could not be canonicalized (`errno`).
        case rootUnavailable(errno: Int32)
        /// A status outside `400...599`.
        case invalidStatus(Int)
        /// The page file for `status` could not be resolved or read (`errno`).
        case pageUnavailable(status: Int, errno: Int32)
        /// The page file for `status` resolves outside the root.
        case pageOutsideRoot(status: Int)
    }

    /// A rendered page: its body and `Content-Type`.
    struct Page: Sendable {
        let body: ByteBuffer
        let contentType: [UInt8]
    }

    final class Pages: Sendable {
        let custom: [Int: Page]
        let generateDefaults: Bool

        init(custom: [Int: Page], generateDefaults: Bool) {
            self.custom = custom
            self.generateDefaults = generateDefaults
        }
    }

    let pages: Pages

    /// Generated default pages only.
    public init() {
        pages = Pages(custom: [:], generateDefaults: true)
    }

    /// Pages from files: `pages` maps a status code (`400...599`) to a path relative to `root`.
    /// Each file is resolved with `realpath`, must stay inside `root`, and is read now; its
    /// `Content-Type` comes from its extension (``MIMETypes``); HTML and unknown extensions get
    /// `text/html; charset=utf-8`. Statuses without a file get the generated page when `defaultPages` is true and
    /// keep their empty body otherwise.
    public init(root: String, pages: [Int: String], defaultPages: Bool = true) throws(InitError) {
        try self.init(roots: [root], pages: pages, defaultPages: defaultPages)
    }

    /// Pages from files looked up in several roots, first match wins (#0129): a virtual host's
    /// own root, then the server's. A root that does not exist is skipped (all missing throws
    /// ``InitError/rootUnavailable(errno:)``); a file found in a root must stay inside it. With
    /// `requireAll` false, a status whose file is in no root keeps the generated page (or the
    /// empty body) instead of throwing ``InitError/pageUnavailable(status:errno:)``.
    public init(roots: [String], pages: [Int: String], defaultPages: Bool = true,
                requireAll: Bool = true) throws(InitError) {
        var realRoots: [[UInt8]] = []
        var rootErrno: Int32 = ENOENT
        for root in roots {
            if let real = PathResolver.realPath(Array(root.utf8)) { realRoots.append(real) } else { rootErrno = errno }
        }
        guard !realRoots.isEmpty else { throw .rootUnavailable(errno: rootErrno) }
        var custom: [Int: Page] = [:]
        for (code, relative) in pages {
            guard (400...599).contains(code) else { throw .invalidStatus(code) }
            var found: (path: [UInt8], root: [UInt8])?
            var pageErrno: Int32 = ENOENT
            for realRoot in realRoots {
                var path = realRoot
                path.append(UInt8(ascii: "/"))
                path.append(contentsOf: Array(relative.utf8))
                if let real = PathResolver.realPath(path) {
                    found = (real, realRoot)
                    break
                }
                pageErrno = errno
            }
            guard let (real, realRoot) = found else {
                if requireAll { throw .pageUnavailable(status: code, errno: pageErrno) }
                continue
            }
            guard real.count > realRoot.count + 1, real.starts(with: realRoot),
                  real[realRoot.count] == UInt8(ascii: "/") || realRoot == [UInt8(ascii: "/")] else {
                throw .pageOutsideRoot(status: code)
            }
            custom[code] = try Self.readPage(real, status: code)
        }
        self.pages = Pages(custom: custom, generateDefaults: defaultPages)
    }

    static func readPage(_ path: [UInt8], status: Int) throws(InitError) -> Page {
        let fd = PathResolver.withCString(path) { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw .pageUnavailable(status: status, errno: errno) }
        let file = OwnedFileDescriptor(takingOwnershipOf: fd)
        var info = stat()
        guard fstat(file.rawValue, &info) == 0 else { throw .pageUnavailable(status: status, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .pageUnavailable(status: status, errno: EISDIR) }
        var body = ByteBuffer(capacity: Int(info.st_size))
        guard CachedFile.readAll(file.rawValue, size: Int(info.st_size), into: &body) >= 0 else {
            throw .pageUnavailable(status: status, errno: errno)
        }
        let contentType: [UInt8] = path.withUnsafeBufferPointer { buffer in
            let span = buffer.span
            let ext = span.extracting(MIMETypes.extensionRange(of: span))
            guard let known = MIMETypes.lookup(extension: ext), known.description != "text/html" else {
                return Array(Self.html.utf8)
            }
            return known.withUTF8Buffer { Array($0) }
        }
        return Page(body: body, contentType: contentType)
    }

    // MARK: HTTPMiddleware

    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        let method = request.method
        return apply(to: try await next.handle(request, context: context), method: method)
    }

    /// `response` with its error page when the rules above call for one, else unchanged.
    public func apply(to response: HTTPResponse, method: HTTPMethod) -> HTTPResponse {
        let code = response.status.code
        guard code >= 400, code <= 599, method != .head, case .empty = response.body,
              !response.headers.contains(.contentLength) else { return response }
        let page: Page
        if let custom = pages.custom[code] {
            page = custom
        } else if pages.generateDefaults {
            page = Self.defaultPage(for: response.status)
        } else {
            return response
        }
        var result = response
        result.headers.removeAll(.contentType)
        page.contentType.withUnsafeBufferPointer { result.headers.append(.contentType, value: $0.span) }
        result.body = .bytes(page.body)
        return result
    }

    // MARK: Default pages

    static let html = "text/html; charset=utf-8"

    /// The generated page for each registered `4xx` and `5xx` status, rendered once.
    static let defaults: [Int: Page] = {
        var pages: [Int: Page] = [:]
        for code in HTTPStatus.registeredCodes where (400...599).contains(code) {
            pages[code] = Page(body: renderDefault(HTTPStatus(code: code)), contentType: Array(html.utf8))
        }
        return pages
    }()

    static func defaultPage(for status: HTTPStatus) -> Page {
        if let page = defaults[status.code] { return page }
        return Page(body: renderDefault(status), contentType: Array(html.utf8))
    }

    /// The generated page for `status`, such as
    /// `<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>`.
    /// The reason phrase is a static, registered string (no request data), so nothing is escaped.
    public static func defaultBody(for status: HTTPStatus) -> ByteBuffer {
        defaultPage(for: status).body
    }

    static func renderDefault(_ status: HTTPStatus) -> ByteBuffer {
        var title = ByteBuffer(capacity: 48)
        title.append(decimal: status.code)
        status.withReasonPhrase { phrase in
            if phrase.count > 0 {
                title.append(UInt8(ascii: " "))
                title.append(contentsOf: phrase)
            }
        }
        var body = ByteBuffer(capacity: 128 + 2 * title.readableBytes)
        body.append("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>")
        body.append(title)
        body.append("</title></head>\n<body><h1>")
        body.append(title)
        body.append("</h1></body></html>\n")
        return body
    }
}
