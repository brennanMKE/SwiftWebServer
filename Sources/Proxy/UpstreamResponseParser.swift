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
    public func parseHead(_ bytes: [UInt8], requestMethod: HTTPMethod? = nil) throws(UpstreamError) -> (UpstreamResponseHead, Int)? {
        guard let end = Self.findHeadEnd(bytes) else {
            if bytes.count > limits.maxHeadBytes { throw .malformedResponse("head too large") }
            return nil
        }
        if end > limits.maxHeadBytes { throw .malformedResponse("head too large") }
        // Split into lines (strict CRLF).
        var lines: [ArraySlice<UInt8>] = []
        var start = 0
        var i = 0
        let headEnd = end - 2  // position of the final empty line's CR
        while i < headEnd {
            if bytes[i] == 13 {
                guard bytes[i + 1] == 10 else { throw .malformedResponse("bare CR") }
                lines.append(bytes[start..<i])
                i += 2
                start = i
            } else if bytes[i] == 10 {
                throw .malformedResponse("bare LF")
            } else {
                i += 1
            }
        }
        guard let statusLine = lines.first else { throw .malformedResponse("empty head") }
        // HTTP/1.x SP 3DIGIT [SP reason]
        let s = Array(statusLine)
        guard s.count >= 12, Array(s[0..<7]) == Array("HTTP/1.".utf8), (s[7] == 0x30 || s[7] == 0x31), s[8] == 0x20 else {
            throw .malformedResponse("bad status line")
        }
        let http10 = s[7] == 0x30
        var code = 0
        for d in s[9..<12] {
            guard d >= 0x30 && d <= 0x39 else { throw .malformedResponse("bad status code") }
            code = code * 10 + Int(d - 0x30)
        }
        guard code >= 100, s.count == 12 || s[12] == 0x20 else { throw .malformedResponse("bad status code") }

        var fields = HTTPFields()
        var contentLength: Int?
        var chunked = false
        var transferEncoding = false
        var connectionClose = false
        var keepAlive = false
        let fieldLines = lines.dropFirst()
        if fieldLines.count > limits.maxFields { throw .malformedResponse("too many fields") }
        for line in fieldLines {
            guard let colon = line.firstIndex(of: 0x3A), colon > line.startIndex else { throw .malformedResponse("bad field") }
            let name = Array(line[line.startIndex..<colon])
            for b in name where !Self.isTokenByte(b) { throw .malformedResponse("bad field name") }
            var vs = colon + 1
            var ve = line.endIndex
            while vs < ve, line[vs] == 0x20 || line[vs] == 0x09 { vs += 1 }
            while ve > vs, line[ve - 1] == 0x20 || line[ve - 1] == 0x09 { ve -= 1 }
            let value = Array(line[vs..<ve])
            for b in value where (b < 0x20 && b != 0x09) || b == 0x7F { throw .malformedResponse("bad field value") }
            let lname = String(decoding: name, as: UTF8.self).lowercased()
            let svalue = String(decoding: value, as: UTF8.self)
            switch lname {
            case "content-length":
                for part in svalue.split(separator: ",") {
                    let t = part.trimmedOfSpaceAndTab
                    guard !t.isEmpty, t.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(t) else {
                        throw .malformedResponse("bad content-length")
                    }
                    if let c = contentLength, c != n { throw .malformedResponse("conflicting content-length") }
                    contentLength = n
                }
            case "transfer-encoding":
                transferEncoding = true
                let codings = svalue.lowercased().split(separator: ",").map { $0.trimmedOfSpaceAndTab }
                chunked = codings.last == "chunked"
            case "connection":
                for token in svalue.lowercased().split(separator: ",").map({ $0.trimmedOfSpaceAndTab }) {
                    if token == "close" { connectionClose = true }
                    if token == "keep-alive" { keepAlive = true }
                }
            default: break
            }
            fields.append(name: String(decoding: name, as: UTF8.self), value: svalue)
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
        let head = UpstreamResponseHead(status: HTTPStatus(code: code), headers: fields, framing: framing, closeAfter: close)
        return (head, end)
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
