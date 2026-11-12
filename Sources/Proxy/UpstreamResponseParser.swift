public import HTTPCore

/// Limits for parsing an upstream response head.
public struct UpstreamResponseParserLimits: Sendable, Hashable {
    public var maxHeadBytes: Int
    public var maxFields: Int
    public init(maxHeadBytes: Int = 64 * 1024, maxFields: Int = 128) {
        self.maxHeadBytes = maxHeadBytes
        self.maxFields = maxFields
    }
}

/// How the response body is delimited (RFC 9112 §6.3).
public enum UpstreamBodyFraming: Sendable, Hashable {
    case none
    case length(Int)
    case chunked
    case close
}

/// A parsed upstream response head.
public struct UpstreamResponseHead: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPFields
    public var framing: UpstreamBodyFraming
    /// The upstream asked to close (`Connection: close`) or spoke HTTP/1.0 without keep-alive.
    public var closeAfter: Bool
}

/// Parses an HTTP/1.1 response head from accumulated bytes. Split-invariant: it only
/// looks for a complete head (terminated by CRLF CRLF), so any split of input yields the
/// same result. Interim 1xx responses are skipped by the caller calling again.
public struct UpstreamResponseParser: Sendable {
    public var limits: UpstreamResponseParserLimits

    public init(limits: UpstreamResponseParserLimits = UpstreamResponseParserLimits()) {
        self.limits = limits
    }

    /// Returns the head and the number of bytes it occupied, or nil when more bytes are
    /// needed. Throws `UpstreamError.malformedResponse` on invalid input or exceeded limits.
    ///
    /// Works on the bytes in place: the only allocation is the returned fields' storage.
    public func parseHead(_ bytes: [UInt8], requestMethod: HTTPMethod? = nil) throws(UpstreamError) -> (UpstreamResponseHead, Int)? {
        guard let end = Self.findHeadEnd(bytes) else {
            if bytes.count > limits.maxHeadBytes { throw .malformedResponse("head too large") }
            return nil
        }
        if end > limits.maxHeadBytes { throw .malformedResponse("head too large") }
        let result: Result<UpstreamResponseHead, UpstreamError> = bytes.withUnsafeBufferPointer { buffer in
            do throws(UpstreamError) {
                return .success(try parse(buffer.span, end: end, requestMethod: requestMethod))
            } catch {
                return .failure(error)
            }
        }
        return (try result.get(), end)
    }

    private func parse(_ bytes: Span<UInt8>, end: Int, requestMethod: HTTPMethod?) throws(UpstreamError) -> UpstreamResponseHead {
        let headEnd = end - 2  // position of the final empty line's CR
        // Status line: HTTP/1.x SP 3DIGIT [SP reason] CRLF (strict CRLF everywhere).
        guard let statusEnd = try Self.lineEnd(bytes, from: 0, limit: headEnd) else { throw .malformedResponse("empty head") }
        guard statusEnd >= 12,
              bytes[0] == 0x48, bytes[1] == 0x54, bytes[2] == 0x54, bytes[3] == 0x50, bytes[4] == 0x2F,
              bytes[5] == 0x31, bytes[6] == 0x2E, bytes[7] == 0x30 || bytes[7] == 0x31, bytes[8] == 0x20 else {
            throw .malformedResponse("bad status line")
        }
        let http10 = bytes[7] == 0x30
        var code = 0
        for i in 9..<12 {
            let d = bytes[i]
            guard d >= 0x30 && d <= 0x39 else { throw .malformedResponse("bad status code") }
            code = code * 10 + Int(d - 0x30)
        }
        guard code >= 100, statusEnd == 12 || bytes[12] == 0x20 else { throw .malformedResponse("bad status code") }

        var fields = HTTPFields()
        var contentLength: Int?
        var chunked = false
        var transferEncoding = false
        var connectionClose = false
        var keepAlive = false
        var count = 0
        var start = statusEnd + 2
        while let lineEnd = try Self.lineEnd(bytes, from: start, limit: headEnd) {
            count += 1
            if count > limits.maxFields { throw .malformedResponse("too many fields") }
            var colon = start
            while colon < lineEnd, bytes[colon] != 0x3A { colon += 1 }
            guard colon < lineEnd, colon > start else { throw .malformedResponse("bad field") }
            for i in start..<colon where !Self.isTokenByte(bytes[i]) { throw .malformedResponse("bad field name") }
            var vs = colon + 1
            var ve = lineEnd
            while vs < ve, bytes[vs] == 0x20 || bytes[vs] == 0x09 { vs += 1 }
            while ve > vs, bytes[ve - 1] == 0x20 || bytes[ve - 1] == 0x09 { ve -= 1 }
            for i in vs..<ve {
                let b = bytes[i]
                if (b < 0x20 && b != 0x09) || b == 0x7F { throw .malformedResponse("bad field value") }
            }
            let name = bytes.extracting(start..<colon)
            let value = bytes.extracting(vs..<ve)
            switch HTTPFieldName.lookup(name) {
            case .contentLength:
                var bad = false
                Self.forEachToken(value) { token in
                    guard let n = ASCII.parseDecimal(token), n <= UInt64(Int.max) else { bad = true; return }
                    if let c = contentLength, c != Int(n) { bad = true }
                    contentLength = Int(n)
                }
                if bad || contentLength == nil { throw .malformedResponse("bad content-length") }
            case .transferEncoding:
                transferEncoding = true
                var last = false
                Self.forEachToken(value) { token in last = ASCII.equalsCaseInsensitive(token, "chunked") }
                chunked = last
            case .connection:
                Self.forEachToken(value) { token in
                    if ASCII.equalsCaseInsensitive(token, "close") { connectionClose = true }
                    if ASCII.equalsCaseInsensitive(token, "keep-alive") { keepAlive = true }
                }
            default: break
            }
            fields.append(name: name, value: value)
            start = lineEnd + 2
        }

        let framing: UpstreamBodyFraming
        if (100..<200).contains(code) || code == 204 || code == 304 || requestMethod == .head {
            framing = .none
        } else if transferEncoding {
            framing = chunked ? .chunked : .close
        } else if let n = contentLength {
            framing = n == 0 ? .none : .length(n)
        } else {
            framing = .close
        }
        let close = connectionClose || (http10 && !keepAlive) || framing == .close
        return UpstreamResponseHead(status: HTTPStatus(code: code), headers: fields, framing: framing, closeAfter: close)
    }

    /// The index of the CR ending the line that starts at `start`, or nil at `limit`. Throws on
    /// a bare CR or LF.
    private static func lineEnd(_ bytes: Span<UInt8>, from start: Int, limit: Int) throws(UpstreamError) -> Int? {
        guard start < limit else { return nil }
        var i = start
        while i < limit {
            let b = bytes[i]
            if b == 13 {
                guard bytes[i + 1] == 10 else { throw .malformedResponse("bare CR") }
                return i
            }
            if b == 10 { throw .malformedResponse("bare LF") }
            i += 1
        }
        return limit
    }

    /// Calls `body` with each comma-separated token of `value`, trimmed of spaces and tabs
    /// (empty tokens included, so `1, ,2` fails number parsing).
    private static func forEachToken(_ value: Span<UInt8>, _ body: (Span<UInt8>) -> Void) {
        var start = 0
        while start <= value.count {
            var end = start
            while end < value.count, value[end] != 0x2C { end += 1 }
            var s = start
            var e = end
            while s < e, value[s] == 0x20 || value[s] == 0x09 { s += 1 }
            while e > s, value[e - 1] == 0x20 || value[e - 1] == 0x09 { e -= 1 }
            body(value.extracting(s..<e))
            start = end + 1
        }
    }

    /// Index just past the first CRLF CRLF, or nil.
    static func findHeadEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 3
        while i < bytes.count {
            if bytes[i] == 10, bytes[i - 1] == 13, bytes[i - 2] == 10, bytes[i - 3] == 13 { return i + 1 }
            i += 1
        }
        return nil
    }

    static func isTokenByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"), UInt8(ascii: "&"),
             UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."),
             UInt8(ascii: "^"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
            return true
        default: return false
        }
    }
}

extension Substring {
    var trimmedOfSpaceAndTab: String {
        var s = self[...]
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}
