/// A response status: a three-digit code plus a static reason phrase (RFC 9110 §15).
///
/// Registered codes have pre-rendered HTTP/1.1 status lines (`HTTP/1.1 200 OK\r\n`), so the
/// serializer writes a status line with one copy (docs/ROADMAP.md §7, "static status lines").
/// The reason phrase is read from that same literal, so code and phrase cannot disagree.
/// A custom phrase or an unregistered code is rendered digit by digit instead.
///
/// Two statuses are equal when their codes are equal; the reason phrase is informational
/// (RFC 9112 §4) and HTTP/2 and HTTP/3 do not carry it.
public struct HTTPStatus: Sendable {
    /// The status code, `100...999`.
    public let code: Int
    @usableFromInline let customReason: StaticString?

    /// A status with the registered reason phrase for `code` (empty if unregistered).
    @inlinable
    public init(code: Int) {
        precondition(code >= 100 && code <= 999, "HTTP status code \(code) must have three digits")
        self.code = code
        customReason = nil
    }

    /// A status with a custom reason phrase. The phrase must not contain CR or LF.
    @inlinable
    public init(code: Int, reasonPhrase: StaticString) {
        precondition(code >= 100 && code <= 999, "HTTP status code \(code) must have three digits")
        self.code = code
        customReason = reasonPhrase
    }

    /// The class of the status (RFC 9110 §15).
    public enum Kind: Sendable, Hashable {
        case informational, successful, redirection, clientError, serverError, nonStandard
    }

    /// The class of the status.
    @inlinable
    public var kind: Kind {
        switch code / 100 {
        case 1: .informational
        case 2: .successful
        case 3: .redirection
        case 4: .clientError
        case 5: .serverError
        default: .nonStandard
        }
    }

    /// True for 1xx, 204 and 304, which never carry content (RFC 9110 §6.4.1).
    @inlinable
    public var forbidsContent: Bool {
        code < 200 || code == 204 || code == 304
    }

    // MARK: Status lines

    /// The pre-rendered `HTTP/1.1 NNN Reason\r\n` line, or `nil` for a custom reason phrase
    /// or an unregistered code.
    @inlinable
    public var http1StatusLine: StaticString? {
        customReason == nil ? HTTPStatus.registeredStatusLine(code) : nil
    }

    /// Calls `body` with the reason phrase bytes (empty for an unregistered code).
    @inlinable
    public func withReasonPhrase<R>(_ body: (Span<UInt8>) -> R) -> R {
        if let customReason {
            return customReason.withUTF8Buffer { body($0.span) }
        }
        guard let line = HTTPStatus.registeredStatusLine(code) else {
            return body(Span<UInt8>())
        }
        // "HTTP/1.1 NNN " is 13 bytes and the line ends with CRLF.
        return line.withUTF8Buffer { bytes in
            body(bytes.span.extracting(13..<(bytes.count &- 2)))
        }
    }

    /// The reason phrase as a `String`. Allocates.
    public var reasonPhrase: String {
        withReasonPhrase { ASCII.string(from: $0) }
    }

    /// Appends the HTTP/1.1 status line, including its CRLF, to `buffer`.
    @inlinable
    public func appendHTTP1StatusLine(to buffer: inout ByteBuffer) {
        if let line = http1StatusLine {
            buffer.append(line)
            return
        }
        buffer.append("HTTP/1.1 ")
        buffer.append(decimal: code)
        buffer.append(UInt8(ascii: " "))
        withReasonPhrase { buffer.append(contentsOf: $0) }
        buffer.append("\r\n")
    }

    /// Appends the three code digits, as used by the HTTP/2 and HTTP/3 `:status` field.
    @inlinable
    public func appendCode(to buffer: inout ByteBuffer) {
        buffer.append(decimal: code)
    }

    // MARK: Registered codes

    public static let `continue` = HTTPStatus(code: 100)
    public static let switchingProtocols = HTTPStatus(code: 101)
    public static let earlyHints = HTTPStatus(code: 103)
    public static let ok = HTTPStatus(code: 200)
    public static let created = HTTPStatus(code: 201)
    public static let accepted = HTTPStatus(code: 202)
    public static let nonAuthoritativeInformation = HTTPStatus(code: 203)
    public static let noContent = HTTPStatus(code: 204)
    public static let resetContent = HTTPStatus(code: 205)
    public static let partialContent = HTTPStatus(code: 206)
    public static let multipleChoices = HTTPStatus(code: 300)
    public static let movedPermanently = HTTPStatus(code: 301)
    public static let found = HTTPStatus(code: 302)
    public static let seeOther = HTTPStatus(code: 303)
    public static let notModified = HTTPStatus(code: 304)
    public static let temporaryRedirect = HTTPStatus(code: 307)
    public static let permanentRedirect = HTTPStatus(code: 308)
    public static let badRequest = HTTPStatus(code: 400)
    public static let unauthorized = HTTPStatus(code: 401)
    public static let forbidden = HTTPStatus(code: 403)
    public static let notFound = HTTPStatus(code: 404)
    public static let methodNotAllowed = HTTPStatus(code: 405)
    public static let notAcceptable = HTTPStatus(code: 406)
    public static let proxyAuthenticationRequired = HTTPStatus(code: 407)
    public static let requestTimeout = HTTPStatus(code: 408)
    public static let conflict = HTTPStatus(code: 409)
    public static let gone = HTTPStatus(code: 410)
    public static let lengthRequired = HTTPStatus(code: 411)
    public static let preconditionFailed = HTTPStatus(code: 412)
    public static let contentTooLarge = HTTPStatus(code: 413)
    public static let uriTooLong = HTTPStatus(code: 414)
    public static let unsupportedMediaType = HTTPStatus(code: 415)
    public static let rangeNotSatisfiable = HTTPStatus(code: 416)
    public static let expectationFailed = HTTPStatus(code: 417)
    public static let misdirectedRequest = HTTPStatus(code: 421)
    public static let unprocessableContent = HTTPStatus(code: 422)
    public static let tooEarly = HTTPStatus(code: 425)
    public static let upgradeRequired = HTTPStatus(code: 426)
    public static let preconditionRequired = HTTPStatus(code: 428)
    public static let tooManyRequests = HTTPStatus(code: 429)
    public static let requestHeaderFieldsTooLarge = HTTPStatus(code: 431)
    public static let internalServerError = HTTPStatus(code: 500)
    public static let notImplemented = HTTPStatus(code: 501)
    public static let badGateway = HTTPStatus(code: 502)
    public static let serviceUnavailable = HTTPStatus(code: 503)
    public static let gatewayTimeout = HTTPStatus(code: 504)
    public static let httpVersionNotSupported = HTTPStatus(code: 505)

    /// Every code with a pre-rendered status line, ascending.
    public static let registeredCodes: [Int] = (100...999).filter { registeredStatusLine($0) != nil }

    /// The pre-rendered HTTP/1.1 status line for a registered code.
    @inlinable
    public static func registeredStatusLine(_ code: Int) -> StaticString? {
        switch code {
        case 100: "HTTP/1.1 100 Continue\r\n"
        case 101: "HTTP/1.1 101 Switching Protocols\r\n"
        case 103: "HTTP/1.1 103 Early Hints\r\n"
        case 200: "HTTP/1.1 200 OK\r\n"
        case 201: "HTTP/1.1 201 Created\r\n"
        case 202: "HTTP/1.1 202 Accepted\r\n"
        case 203: "HTTP/1.1 203 Non-Authoritative Information\r\n"
        case 204: "HTTP/1.1 204 No Content\r\n"
        case 205: "HTTP/1.1 205 Reset Content\r\n"
        case 206: "HTTP/1.1 206 Partial Content\r\n"
        case 300: "HTTP/1.1 300 Multiple Choices\r\n"
        case 301: "HTTP/1.1 301 Moved Permanently\r\n"
        case 302: "HTTP/1.1 302 Found\r\n"
        case 303: "HTTP/1.1 303 See Other\r\n"
        case 304: "HTTP/1.1 304 Not Modified\r\n"
        case 307: "HTTP/1.1 307 Temporary Redirect\r\n"
        case 308: "HTTP/1.1 308 Permanent Redirect\r\n"
        case 400: "HTTP/1.1 400 Bad Request\r\n"
        case 401: "HTTP/1.1 401 Unauthorized\r\n"
        case 403: "HTTP/1.1 403 Forbidden\r\n"
        case 404: "HTTP/1.1 404 Not Found\r\n"
        case 405: "HTTP/1.1 405 Method Not Allowed\r\n"
        case 406: "HTTP/1.1 406 Not Acceptable\r\n"
        case 407: "HTTP/1.1 407 Proxy Authentication Required\r\n"
        case 408: "HTTP/1.1 408 Request Timeout\r\n"
        case 409: "HTTP/1.1 409 Conflict\r\n"
        case 410: "HTTP/1.1 410 Gone\r\n"
        case 411: "HTTP/1.1 411 Length Required\r\n"
        case 412: "HTTP/1.1 412 Precondition Failed\r\n"
        case 413: "HTTP/1.1 413 Content Too Large\r\n"
        case 414: "HTTP/1.1 414 URI Too Long\r\n"
        case 415: "HTTP/1.1 415 Unsupported Media Type\r\n"
        case 416: "HTTP/1.1 416 Range Not Satisfiable\r\n"
        case 417: "HTTP/1.1 417 Expectation Failed\r\n"
        case 421: "HTTP/1.1 421 Misdirected Request\r\n"
        case 422: "HTTP/1.1 422 Unprocessable Content\r\n"
        case 425: "HTTP/1.1 425 Too Early\r\n"
        case 426: "HTTP/1.1 426 Upgrade Required\r\n"
        case 428: "HTTP/1.1 428 Precondition Required\r\n"
        case 429: "HTTP/1.1 429 Too Many Requests\r\n"
        case 431: "HTTP/1.1 431 Request Header Fields Too Large\r\n"
        case 500: "HTTP/1.1 500 Internal Server Error\r\n"
        case 501: "HTTP/1.1 501 Not Implemented\r\n"
        case 502: "HTTP/1.1 502 Bad Gateway\r\n"
        case 503: "HTTP/1.1 503 Service Unavailable\r\n"
        case 504: "HTTP/1.1 504 Gateway Timeout\r\n"
        case 505: "HTTP/1.1 505 HTTP Version Not Supported\r\n"
        default: nil
        }
    }
}

extension HTTPStatus: Equatable, Hashable {
    @inlinable
    public static func == (lhs: HTTPStatus, rhs: HTTPStatus) -> Bool { lhs.code == rhs.code }

    @inlinable
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }
}

extension HTTPStatus: CustomStringConvertible {
    public var description: String { "\(code) \(reasonPhrase)" }
}
