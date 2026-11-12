public import HTTPCore

/// The HTTP version of a request line. Only HTTP/1.0 and HTTP/1.1 are accepted; any other
/// well-formed `HTTP/x.y` is answered with 505 (RFC 9112 §2.3).
public enum HTTP1Version: Sendable, Hashable {
    case http1_0
    case http1_1
}

/// The four request-target forms of RFC 9112 §3.2.
public enum HTTP1RequestTargetForm: Sendable, Hashable {
    /// `/path?query`, the usual form.
    case origin
    /// `scheme://authority/path?query`, sent to proxies; servers must accept it.
    case absolute
    /// `host:port`, only for `CONNECT`.
    case authority
    /// `*`, only for server-wide `OPTIONS`.
    case asterisk
}

/// How the body of a request is delimited (RFC 9112 §6.3). The parser decides; reading the
/// body is #0081.
public enum HTTP1RequestFraming: Sendable, Hashable {
    /// No `Content-Length` and no `Transfer-Encoding`: the request has no body.
    case none
    /// A `Content-Length` body of exactly this many bytes (possibly zero).
    case contentLength(UInt64)
    /// `Transfer-Encoding: chunked`.
    case chunked
}

/// A parsed request head. Every range is an absolute ``ByteView`` into the buffer the head
/// was parsed from, so it stays valid until that buffer discards the head's bytes.
public struct HTTP1RequestHead: Sendable, Hashable {
    public var method: HTTPMethod
    public var version: HTTP1Version
    public var targetForm: HTTP1RequestTargetForm
    /// The whole request target as received.
    public var target: ByteView
    /// The scheme of an absolute-form target, without `://`; empty otherwise.
    public var scheme: ByteView
    /// The authority of an absolute-form or authority-form target; empty otherwise (the
    /// `host` field carries it).
    public var authority: ByteView
    /// The path, still percent-encoded. `*` for asterisk-form, empty for authority-form and
    /// for an absolute-form target without a path (which means `/`).
    public var path: ByteView
    /// The query without the `?`; empty when absent.
    public var query: ByteView
    /// True when the target has a `%` before its first `?`, so the path may need decoding
    /// (#0084 decodes only when this is set). For absolute-form this also covers the
    /// authority, so it is conservative.
    public var pathHasPercent: Bool
    /// True when the query contains a `%`.
    public var queryHasPercent: Bool
    /// The body framing decision.
    public var framing: HTTP1RequestFraming
    /// Number of bytes the head occupied, from the first byte (including any leading empty
    /// lines) through the CRLF that ends the field section.
    public var length: Int

    @inlinable
    public init(
        method: HTTPMethod = .get,
        version: HTTP1Version = .http1_1,
        targetForm: HTTP1RequestTargetForm = .origin,
        target: ByteView = .empty,
        scheme: ByteView = .empty,
        authority: ByteView = .empty,
        path: ByteView = .empty,
        query: ByteView = .empty,
        pathHasPercent: Bool = false,
        queryHasPercent: Bool = false,
        framing: HTTP1RequestFraming = .none,
        length: Int = 0
    ) {
        self.method = method
        self.version = version
        self.targetForm = targetForm
        self.target = target
        self.scheme = scheme
        self.authority = authority
        self.path = path
        self.query = query
        self.pathHasPercent = pathHasPercent
        self.queryHasPercent = queryHasPercent
        self.framing = framing
        self.length = length
    }

    /// The request a handler sees, borrowing `storage` (whose buffer this head was parsed
    /// from and whose field index holds its fields, see ``HTTP1Parser/parseHead(into:)``).
    @inlinable
    public func request(in storage: HTTPRequestStorage) -> HTTPRequest {
        HTTPRequest(method: method, scheme: scheme, authority: authority, path: path,
                    query: query, headers: storage.fieldsView,
                    version: version == .http1_1 ? .http1_1 : .http1_0)
    }
}

/// Configurable parser limits (docs/ROADMAP.md §7: fixed capacities from limits).
public struct HTTP1ParserLimits: Sendable, Hashable {
    /// Longest request line, excluding its CRLF. Longer lines get 414.
    public var maxRequestLineLength: Int
    /// Most field lines in one head. More get 431.
    public var maxHeaderCount: Int
    /// Most bytes in one head, from its first byte through the final CRLF. More get 431.
    public var maxHeadBytes: Int

    public static let defaultMaxRequestLineLength = 8 * 1024
    public static let defaultMaxHeaderCount = 100
    public static let defaultMaxHeadBytes = 16 * 1024

    @inlinable
    public init(
        maxRequestLineLength: Int = HTTP1ParserLimits.defaultMaxRequestLineLength,
        maxHeaderCount: Int = HTTP1ParserLimits.defaultMaxHeaderCount,
        maxHeadBytes: Int = HTTP1ParserLimits.defaultMaxHeadBytes
    ) {
        precondition(maxRequestLineLength > 0 && maxHeaderCount >= 0 && maxHeadBytes > 0,
                     "HTTP1ParserLimits must be positive")
        self.maxRequestLineLength = maxRequestLineLength
        self.maxHeaderCount = maxHeaderCount
        self.maxHeadBytes = maxHeadBytes
    }
}

/// Why a head was rejected. Every case maps to the response ``status``; the connection
/// answers with it and closes.
public enum HTTP1ParseError: Error, Sendable, Hashable {
    // 400 Bad Request
    case invalidMethod
    case invalidRequestTarget
    case invalidVersion
    /// A LF not preceded by CR (RFC 9112 §2.2: we do not accept bare LF).
    case bareLineFeed
    /// A CR not followed by LF.
    case bareCarriageReturn
    case invalidFieldName
    /// Whitespace between a field name and `:` (RFC 9112 §5.1).
    case whitespaceBeforeColon
    /// A field line starting with SP or HTAB (RFC 9112 §5.2).
    case obsoleteLineFolding
    /// A field value byte outside `field-vchar` / SP / HTAB, such as NUL, DEL or a bare CR.
    case invalidFieldValue
    case missingHost
    case multipleHost
    /// Both `Transfer-Encoding` and `Content-Length` (RFC 9112 §6.1).
    case transferEncodingWithContentLength
    /// `Transfer-Encoding` whose final coding is not `chunked`, or that repeats `chunked`, or
    /// in an HTTP/1.0 request (RFC 9112 §6.1, §6.3).
    case invalidTransferEncoding
    case invalidContentLength
    /// Two different `Content-Length` values (#0021).
    case conflictingContentLength
    // 414
    case requestLineTooLong
    // 431
    case headTooLarge
    case tooManyFields
    // 501
    case methodTooLong
    /// A transfer coding other than `chunked` (RFC 9112 §6.1).
    case unsupportedTransferCoding
    // 505
    case unsupportedVersion

    /// The response status for this error.
    @inlinable
    public var status: HTTPStatus {
        switch self {
        case .requestLineTooLong: .uriTooLong
        case .headTooLarge, .tooManyFields: .requestHeaderFieldsTooLarge
        case .methodTooLong, .unsupportedTransferCoding: .notImplemented
        case .unsupportedVersion: .httpVersionNotSupported
        default: .badRequest
        }
    }
}

/// The result of ``HTTP1Parser/parseHead(_:)``.
public enum HTTP1ParseResult: Sendable, Hashable {
    /// The head is not complete yet; call again after receiving more bytes.
    case needMoreBytes
    /// A head was parsed: read ``HTTP1Parser/head`` and ``HTTP1Parser/fields``.
    case complete
    /// The head is invalid; answer with ``HTTP1ParseError/status`` and close.
    case error(HTTP1ParseError)
}
