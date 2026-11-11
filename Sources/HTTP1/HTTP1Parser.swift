public import HTTPCore

/// Incremental HTTP/1.1 request-head parser: a value-type byte state machine
/// (docs/ROADMAP.md §5.3, §5.4).
///
/// ```swift
/// while case .complete = parser.parseHead(&buffer) {
///     handle(parser.head, parser.fields)
/// }
/// ```
///
/// ## Incremental parsing
///
/// `parseHead` scans from where the previous call stopped; bytes are never rescanned, and
/// the result is identical however the head is split across calls. The buffer's
/// `readerIndex` does not move until the head is complete, and the caller must not move it
/// or call `discardReadBytes()` while a head is in progress. On ``HTTP1ParseResult/complete``
/// the reader index moves past the head, so pipelined heads parse with repeated calls.
///
/// ## Cost
///
/// One pass over the bytes, no allocation once ``fields`` has grown to fit, no `String`.
/// Header names are hashed (FNV-1a over lowercased bytes) in the same loop that finds `:`
/// and resolved through ``HTTPFieldName/lookup(hash:name:)``; token bytes are checked
/// against ``ASCII/tokenTable`` (256 bits, one per byte value).
///
/// ## Rules
///
/// - Errors are reported at the first offending byte. A limit error is reported at the first
///   byte past the limit: the request-line byte at offset ``HTTP1ParserLimits/maxRequestLineLength``
///   (unless it is CR or LF), the field line after ``HTTP1ParserLimits/maxHeaderCount`` fields,
///   and the byte at offset ``HTTP1ParserLimits/maxHeadBytes``.
/// - Leading empty lines (CRLF) before the request line are skipped (RFC 9112 §2.2).
/// - Lines end in CRLF; bare LF and bare CR are rejected. Obsolete line folding and
///   whitespace before `:` are rejected (RFC 9112 §5.1, §5.2).
/// - Method: 1 to 24 `tchar` bytes (longer: 501). Target: bytes 0x21–0x7E, in one of the
///   four forms of RFC 9112 §3.2 (authority-form only for CONNECT, which requires it;
///   asterisk-form only for OPTIONS). Version: `HTTP/1.0` or `HTTP/1.1`; another
///   `HTTP/d.d` gets 505.
/// - Field values may contain VCHAR, obs-text, SP and HTAB; leading and trailing SP/HTAB
///   are trimmed.
/// - After the head: HTTP/1.1 needs exactly one `Host` (any version: at most one), then
///   framing per RFC 9112 §6.3 (see ``HTTP1BodyFraming``).
///
/// The test-support `ReferenceHTTP1Parser` implements the same rules independently; the
/// differential test in `HTTP1Tests` checks that both agree.
public struct HTTP1Parser: Sendable {
    /// The limits. Changing them while a head is in progress applies to the rest of it.
    public var limits: HTTP1ParserLimits
    /// The last complete head. Valid after ``HTTP1ParseResult/complete`` until the next call.
    public private(set) var head: HTTP1RequestHead
    /// The fields of the last complete head, in order, pointing into the buffer. Cleared
    /// (keeping capacity) when the next head starts.
    public private(set) var fields: HTTPFieldIndex

    enum State: UInt8 {
        case start, leadingLF, method, target, version, requestLineLF
        case lineStart, name, valueOWS, value, fieldLF, finalLF
    }

    var state: State = .start
    /// Absolute buffer index of the head's first byte.
    var headStart = 0
    // Offsets below are relative to headStart.
    var position = 0
    var lineStart = 0
    var tokenStart = 0
    var nameStart = 0
    var nameEnd = 0
    var valueStart = 0
    var queryStart = -1
    var hash: UInt32 = ASCII.FNV1a.offsetBasis
    var fieldName: HTTPFieldName = .unknown
    var hostCount = 0

    public init(limits: HTTP1ParserLimits = HTTP1ParserLimits(), fieldCapacity: Int = 32) {
        self.limits = limits
        head = HTTP1RequestHead()
        fields = HTTPFieldIndex(minimumCapacity: fieldCapacity)
    }

    /// True when part of a head has been scanned but it is not complete.
    public var isInProgress: Bool { state != .start || position != 0 }

    /// Abandons any head in progress.
    public mutating func reset() {
        state = .start
        position = 0
    }

    /// Swaps the parsed field index with `other`, so a connection can hand the fields to its
    /// ``HTTPRequestStorage`` without copying. The parser clears whatever index it holds when
    /// the next head starts.
    public mutating func exchangeFields(with other: inout HTTPFieldIndex) {
        swap(&fields, &other)
    }

    /// Parses into `storage`: its buffer is the receive buffer, and on
    /// ``HTTP1ParseResult/complete`` its field index receives the fields (call
    /// ``HTTPRequestStorage/endRequest()`` after each request, as usual). Use
    /// ``HTTP1RequestHead/request(in:)`` to build the handler's request.
    public mutating func parseHead(into storage: HTTPRequestStorage) -> HTTP1ParseResult {
        let result = parseHead(&storage.buffer)
        if case .complete = result {
            exchangeFields(with: &storage.fields)
        }
        return result
    }

    /// Parses as much of a request head as `buffer` holds.
    public mutating func parseHead(_ buffer: inout ByteBuffer) -> HTTP1ParseResult {
        if state == .start && position == 0 {
            headStart = buffer.readerIndex
            fields.removeAll(keepingCapacity: true)
            hostCount = 0
            queryStart = -1
            head = HTTP1RequestHead()
        } else {
            precondition(buffer.readerIndex == headStart,
                         "HTTP1Parser: the buffer's readerIndex moved while a head was in progress")
        }
        let available = buffer.readableBytes
        let scanResult: HTTP1ParseResult = buffer.withReadableSpan { bytes in
            scan(bytes)
        }
        switch scanResult {
        case .needMoreBytes:
            if available > limits.maxHeadBytes {
                reset()
                return .error(.headTooLarge)
            }
            return .needMoreBytes
        case .error:
            reset()
            return scanResult
        case .complete:
            let length = position
            reset()
            if let error = finishHead(buffer) {
                return .error(error)
            }
            head.length = length
            buffer.moveReaderIndex(forwardBy: length)
            return .complete
        }
    }

    // MARK: Scanning

    /// Scans bytes from `position` up to the head limit. Returns `.complete` with `position`
    /// just past the final LF.
    mutating func scan(_ bytes: Span<UInt8>) -> HTTP1ParseResult {
        let end = Swift.min(bytes.count, limits.maxHeadBytes)
        var i = position
        var state = self.state
        defer {
            position = i
            self.state = state
        }
        let cr: UInt8 = 0x0D
        let lf: UInt8 = 0x0A
        let sp: UInt8 = 0x20
        let ht: UInt8 = 0x09
        let colon = UInt8(ascii: ":")
        let maxLine = limits.maxRequestLineLength

        while i < end {
            switch state {
            case .start:
                if bytes[i] == cr {
                    state = .leadingLF
                    i &+= 1
                } else {
                    lineStart = i
                    tokenStart = i
                    state = .method
                }

            case .leadingLF:
                guard bytes[i] == lf else { return .error(.bareCarriageReturn) }
                i &+= 1
                state = .start

            case .method:
                while i < end {
                    let b = bytes[i]
                    if i &- lineStart >= maxLine && b != cr && b != lf { return .error(.requestLineTooLong) }
                    if b == sp {
                        guard i > tokenStart,
                              let method = HTTPMethod(bytes.extracting(tokenStart..<i))
                        else { return .error(.invalidMethod) }
                        head.method = method
                        i &+= 1
                        tokenStart = i
                        state = .target
                        break
                    }
                    guard ASCII.isTokenCharacter(b) else { return .error(.invalidMethod) }
                    if i &- tokenStart >= HTTPMethod.Token.maximumLength { return .error(.methodTooLong) }
                    i &+= 1
                }

            case .target:
                while i < end {
                    let b = bytes[i]
                    if i &- lineStart >= maxLine && b != cr && b != lf { return .error(.requestLineTooLong) }
                    if b == sp {
                        guard i > tokenStart else { return .error(.invalidRequestTarget) }
                        if let error = classifyTarget(bytes, end: i) { return .error(error) }
                        i &+= 1
                        tokenStart = i
                        state = .version
                        break
                    }
                    guard b &- 0x21 < 0x5E else { return .error(.invalidRequestTarget) }
                    if b == UInt8(ascii: "%") {
                        if queryStart < 0 { head.pathHasPercent = true } else { head.queryHasPercent = true }
                    } else if b == UInt8(ascii: "?") && queryStart < 0 {
                        queryStart = i
                    }
                    i &+= 1
                }

            case .version:
                while i < end {
                    let b = bytes[i]
                    if i &- lineStart >= maxLine && b != cr && b != lf { return .error(.requestLineTooLong) }
                    if b == cr {
                        if let error = classifyVersion(bytes.extracting(tokenStart..<i)) { return .error(error) }
                        i &+= 1
                        state = .requestLineLF
                        break
                    }
                    if b == lf { return .error(.bareLineFeed) }
                    guard b &- 0x21 < 0x5E else { return .error(.invalidVersion) }
                    i &+= 1
                }

            case .requestLineLF:
                guard bytes[i] == lf else { return .error(.bareCarriageReturn) }
                i &+= 1
                state = .lineStart

            case .lineStart:
                let b = bytes[i]
                if b == cr {
                    i &+= 1
                    state = .finalLF
                } else if b == lf {
                    return .error(.bareLineFeed)
                } else if b == sp || b == ht {
                    return .error(.obsoleteLineFolding)
                } else if fields.count >= limits.maxHeaderCount {
                    return .error(.tooManyFields)
                } else {
                    tokenStart = i
                    hash = ASCII.FNV1a.offsetBasis
                    state = .name
                }

            case .name:
                // Scan and hash in one pass (docs/ROADMAP.md §7).
                // `:` is not a tchar, so one test per byte finds both the end and errors.
                var h = hash
                while i < end {
                    let b = bytes[i]
                    guard ASCII.isTokenCharacter(b) else { break }
                    h = (h ^ UInt32(ASCII.lowercased(b))) &* ASCII.FNV1a.prime
                    i &+= 1
                }
                hash = h
                guard i < end else { break }
                let b = bytes[i]
                guard b == colon else {
                    return .error(b == sp || b == ht ? .whitespaceBeforeColon : .invalidFieldName)
                }
                guard i > tokenStart else { return .error(.invalidFieldName) }
                fieldName = HTTPFieldName.lookup(hash: h, name: bytes.extracting(tokenStart..<i))
                if fieldName == .host { hostCount &+= 1 }
                nameStart = tokenStart
                nameEnd = i
                i &+= 1
                state = .valueOWS

            case .valueOWS:
                while i < end, bytes[i] == sp || bytes[i] == ht { i &+= 1 }
                guard i < end else { break }
                valueStart = i
                state = .value

            case .value:
                // Eight bytes at a time while none is a control byte or DEL (SWAR), then
                // byte by byte. A word with any such byte (CR, HTAB, NUL, ...) falls through.
                let raw = bytes.bytes
                while i &+ 8 <= end {
                    let w = UInt64(littleEndian: raw.unsafeLoadUnaligned(fromByteOffset: i, as: UInt64.self))
                    let del = w ^ Self.repeated(0x7F)
                    let flags = ((w &- Self.repeated(0x20)) | (del &- Self.repeated(0x01))) & ~w & Self.repeated(0x80)
                    if flags != 0 { break }
                    i &+= 8
                }
                while i < end {
                    let b = bytes[i]
                    if (b >= sp && b != 0x7F) || b == ht {
                        i &+= 1
                    } else if b == cr {
                        break
                    } else {
                        return .error(b == lf ? .bareLineFeed : .invalidFieldValue)
                    }
                }
                guard i < end else { break }
                // Trim trailing OWS; leading OWS was skipped, so this stops at valueStart.
                var valueEnd = i
                while valueEnd > valueStart && (bytes[valueEnd &- 1] == sp || bytes[valueEnd &- 1] == ht) {
                    valueEnd &-= 1
                }
                let base = headStart
                fields.append(fieldName,
                              nameView: ByteView(offset: base &+ nameStart, length: nameEnd &- nameStart),
                              valueView: ByteView(offset: base &+ valueStart, length: valueEnd &- valueStart))
                i &+= 1
                state = .fieldLF

            case .fieldLF:
                guard bytes[i] == lf else { return .error(.bareCarriageReturn) }
                i &+= 1
                state = .lineStart

            case .finalLF:
                guard bytes[i] == lf else { return .error(.bareCarriageReturn) }
                i &+= 1
                state = .start
                return .complete
            }
        }
        return .needMoreBytes
    }

    /// `byte` in every byte of a word.
    @inline(__always)
    static func repeated(_ byte: UInt8) -> UInt64 { 0x0101_0101_0101_0101 &* UInt64(byte) }

    /// Validates the version token at the CR that ends the request line.
    mutating func classifyVersion(_ token: Span<UInt8>) -> HTTP1ParseError? {
        guard token.count == 8,
              token[0] == UInt8(ascii: "H"), token[1] == UInt8(ascii: "T"),
              token[2] == UInt8(ascii: "T"), token[3] == UInt8(ascii: "P"),
              token[4] == UInt8(ascii: "/"), ASCII.isDigit(token[5]),
              token[6] == UInt8(ascii: "."), ASCII.isDigit(token[7])
        else { return .invalidVersion }
        guard token[5] == UInt8(ascii: "1") else { return .unsupportedVersion }
        switch token[7] {
        case UInt8(ascii: "1"):
            head.version = .http1_1
            return nil
        case UInt8(ascii: "0"):
            head.version = .http1_0
            return nil
        default: return .unsupportedVersion
        }
    }

    /// Classifies the request target `tokenStart..<end` (relative) and records its parts.
    mutating func classifyTarget(_ bytes: Span<UInt8>, end: Int) -> HTTP1ParseError? {
        let start = tokenStart
        let base = headStart
        func view(_ lo: Int, _ hi: Int) -> ByteView { ByteView(offset: base &+ lo, length: hi &- lo) }
        head.target = view(start, end)
        let first = bytes[start]

        if head.method == .connect {
            // authority-form: host ":" port, nothing else (RFC 9112 §3.2.3).
            var lastColon = -1
            for i in start..<end {
                let b = bytes[i]
                if b == UInt8(ascii: "/") || b == UInt8(ascii: "?") || b == UInt8(ascii: "@") || b == UInt8(ascii: "#") {
                    return .invalidRequestTarget
                }
                if b == UInt8(ascii: ":") { lastColon = i }
            }
            let portLength = end &- lastColon &- 1
            guard lastColon > start, portLength >= 1, portLength <= 5 else { return .invalidRequestTarget }
            for i in (lastColon &+ 1)..<end where !ASCII.isDigit(bytes[i]) { return .invalidRequestTarget }
            head.targetForm = .authority
            head.authority = view(start, end)
            return nil
        }

        if first == UInt8(ascii: "/") {
            head.targetForm = .origin
            splitPathAndQuery(from: start, end: end)
            return nil
        }

        if first == UInt8(ascii: "*") {
            guard end &- start == 1, head.method == .options else { return .invalidRequestTarget }
            head.targetForm = .asterisk
            head.path = view(start, end)
            return nil
        }

        // absolute-form: scheme "://" authority [path] ["?" query] (RFC 9112 §3.2.2).
        guard ASCII.isAlpha(first) else { return .invalidRequestTarget }
        var i = start &+ 1
        while i < end, ASCII.isSchemeCharacter(bytes[i]) { i &+= 1 }
        let schemeEnd = i
        guard end &- i >= 3, bytes[i] == UInt8(ascii: ":"),
              bytes[i &+ 1] == UInt8(ascii: "/"), bytes[i &+ 2] == UInt8(ascii: "/")
        else { return .invalidRequestTarget }
        i &+= 3
        let authorityStart = i
        while i < end, bytes[i] != UInt8(ascii: "/"), bytes[i] != UInt8(ascii: "?") {
            if bytes[i] == UInt8(ascii: "@") { return .invalidRequestTarget }
            i &+= 1
        }
        guard i > authorityStart else { return .invalidRequestTarget }
        head.targetForm = .absolute
        head.scheme = view(start, schemeEnd)
        head.authority = view(authorityStart, i)
        splitPathAndQuery(from: i, end: end)
        return nil
    }

    /// Sets path and query for `start..<end`, split at the first `?` (``queryStart``).
    mutating func splitPathAndQuery(from start: Int, end: Int) {
        let base = headStart
        if queryStart >= start {
            head.path = ByteView(offset: base &+ start, length: queryStart &- start)
            head.query = ByteView(offset: base &+ queryStart &+ 1, length: end &- queryStart &- 1)
        } else {
            head.path = ByteView(offset: base &+ start, length: end &- start)
            head.query = .empty
        }
    }

    // MARK: After the head

    /// Version, `Host` and framing checks (RFC 9112 §3.2, §6.1, §6.3).
    mutating func finishHead(_ buffer: ByteBuffer) -> HTTP1ParseError? {
        if hostCount > 1 { return .multipleHost }
        if hostCount == 0 && head.version == .http1_1 { return .missingHost }

        let hasTransferEncoding = fields.contains(.transferEncoding)
        let hasContentLength = fields.contains(.contentLength)
        if !hasTransferEncoding && !hasContentLength {
            head.framing = .none
            return nil
        }
        // Digit loop for the common case: one Content-Length field holding one number.
        if !hasTransferEncoding, let first = fields.firstIndex(of: .contentLength),
           fields.firstIndex(of: .contentLength, from: first &+ 1) == nil,
           let length = fields[first].valueView.decimalValue(in: buffer) {
            head.framing = .contentLength(length)
            return nil
        }
        let parsed = ParsedFields(index: fields, buffer: buffer)
        if hasTransferEncoding {
            if fields.contains(.contentLength) { return .transferEncodingWithContentLength }
            if head.version == .http1_0 { return .invalidTransferEncoding }
            // Codings e1, ..., en: en must be chunked and chunked must not repeat (400);
            // any other coding is one we do not implement (501).
            var elements = 0
            var chunkedCount = 0
            var lastIsChunked = false
            parsed.forEachListElement(of: .transferEncoding) { element in
                elements &+= 1
                lastIsChunked = element.equalsCaseInsensitive("chunked", in: buffer)
                if lastIsChunked { chunkedCount &+= 1 }
            }
            guard lastIsChunked, chunkedCount == 1 else { return .invalidTransferEncoding }
            if elements > 1 { return .unsupportedTransferCoding }
            head.framing = .chunked
            return nil
        }
        switch parsed.contentLength() {
        case .absent: head.framing = .none
        case .value(let length): head.framing = .contentLength(length)
        case .invalid: return .invalidContentLength
        case .conflicting: return .conflictingContentLength
        }
        return nil
    }
}

/// The parser's field index over the receive buffer, to reuse the ``HTTPFieldCollection``
/// list and `Content-Length` rules from HTTPCore.
struct ParsedFields: HTTPFieldCollection {
    let index: HTTPFieldIndex
    let buffer: ByteBuffer

    func withFieldStorage<R, E: Error>(_ body: (HTTPFieldIndex, ByteBuffer) throws(E) -> R) throws(E) -> R {
        try body(index, buffer)
    }
}

extension ASCII {
    /// True for `A`-`Z` and `a`-`z`.
    @inlinable
    static func isAlpha(_ byte: UInt8) -> Bool {
        (byte | 0x20) &- 0x61 < 26
    }

    /// True for the bytes after the first in a URI scheme: ALPHA / DIGIT / "+" / "-" / "."
    /// (RFC 3986 §3.1).
    @inlinable
    static func isSchemeCharacter(_ byte: UInt8) -> Bool {
        isAlpha(byte) || isDigit(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }
}
