public import HTTPCore

/// Renders access log lines into a ``ByteBuffer/Writer``: no `String`, no Foundation, no
/// allocation. Quoted fields are escaped so a hostile request target or header cannot forge a
/// line or break a parser:
///
/// - Common/Combined: `"` and `\` are backslash-escaped; control bytes, DEL and bytes ≥ 0x80
///   become `\xHH` (as Apache's `ap_escape_logitem`), so a line never contains a raw newline.
/// - JSON: RFC 8259 escaping (`\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`, `\u00XX` for other
///   control bytes and DEL). Valid UTF-8 is copied; each byte of an invalid sequence becomes
///   `\ufffd`, so every line is valid JSON.
public enum AccessLogLineFormatter {
    /// The most bytes one input byte can become: `\xHH` (4) or `\u00XX` / `\ufffd` (6).
    @inlinable
    public static func expansion(_ format: AccessLogFormat) -> Int {
        format == .json ? 6 : 4
    }

    /// Bytes reserved per line besides the escaped variable fields.
    public static let fixedBound = 256

    // MARK: Escaping

    /// Appends `bytes` escaped for a quoted Common/Combined field.
    public static func appendCLFEscaped(_ bytes: Span<UInt8>, to writer: inout ByteBuffer.Writer) {
        let count = bytes.count
        var runStart = 0
        var index = 0
        while index < count {
            let byte = bytes[unchecked: index]
            if byte >= 0x20 && byte < 0x7F && byte != 0x22 && byte != 0x5C {
                index &+= 1
                continue
            }
            if runStart < index { writer.append(contentsOf: bytes.extracting(unchecked: runStart..<index)) }
            if byte == 0x22 || byte == 0x5C {
                writer.append(0x5C, byte)
            } else {
                writer.append(0x5C, UInt8(ascii: "x"))
                writer.append(hexDigit(byte >> 4), hexDigit(byte & 0x0F))
            }
            index &+= 1
            runStart = index
        }
        if runStart < count { writer.append(contentsOf: bytes.extracting(unchecked: runStart..<count)) }
    }

    /// Appends `bytes` escaped for the inside of a JSON string.
    public static func appendJSONEscaped(_ bytes: Span<UInt8>, to writer: inout ByteBuffer.Writer) {
        let count = bytes.count
        var runStart = 0
        var index = 0
        while index < count {
            let byte = bytes[unchecked: index]
            if byte >= 0x20 && byte < 0x7F && byte != 0x22 && byte != 0x5C {
                index &+= 1
                continue
            }
            if byte >= 0x80 {
                let length = validUTF8SequenceLength(bytes, at: index)
                if length > 0 {
                    index &+= length
                    continue
                }
            }
            if runStart < index { writer.append(contentsOf: bytes.extracting(unchecked: runStart..<index)) }
            switch byte {
            case 0x22: writer.append(0x5C, 0x22)
            case 0x5C: writer.append(0x5C, 0x5C)
            case 0x0A: writer.append(0x5C, UInt8(ascii: "n"))
            case 0x0D: writer.append(0x5C, UInt8(ascii: "r"))
            case 0x09: writer.append(0x5C, UInt8(ascii: "t"))
            case 0x08: writer.append(0x5C, UInt8(ascii: "b"))
            case 0x0C: writer.append(0x5C, UInt8(ascii: "f"))
            case 0x80...: writer.append("\\ufffd")
            default:
                writer.append("\\u00")
                writer.append(hexDigit(byte >> 4), hexDigit(byte & 0x0F))
            }
            index &+= 1
            runStart = index
        }
        if runStart < count { writer.append(contentsOf: bytes.extracting(unchecked: runStart..<count)) }
    }

    /// The length of the well-formed UTF-8 sequence starting at `index` (RFC 3629 table 3-7:
    /// no overlongs, no surrogates, nothing above U+10FFFF), or 0 if there is none.
    static func validUTF8SequenceLength(_ bytes: Span<UInt8>, at index: Int) -> Int {
        let lead = bytes[unchecked: index]
        let remaining = bytes.count &- index
        func continuation(_ offset: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
            offset < remaining && range.contains(bytes[unchecked: index &+ offset])
        }
        switch lead {
        case 0xC2...0xDF:
            return continuation(1) ? 2 : 0
        case 0xE0:
            return continuation(1, 0xA0...0xBF) && continuation(2) ? 3 : 0
        case 0xE1...0xEC, 0xEE...0xEF:
            return continuation(1) && continuation(2) ? 3 : 0
        case 0xED:
            return continuation(1, 0x80...0x9F) && continuation(2) ? 3 : 0
        case 0xF0:
            return continuation(1, 0x90...0xBF) && continuation(2) && continuation(3) ? 4 : 0
        case 0xF1...0xF3:
            return continuation(1) && continuation(2) && continuation(3) ? 4 : 0
        case 0xF4:
            return continuation(1, 0x80...0x8F) && continuation(2) && continuation(3) ? 4 : 0
        default:
            return 0
        }
    }

    @inline(__always)
    static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 &+ nibble : 0x61 &+ nibble &- 10
    }

    // MARK: Dates

    /// Bytes of a rendered date for `format`: `10/Oct/2026:13:55:36 +0000` (26) or
    /// `2026-10-10T13:55:36Z` (20).
    public static func dateLength(_ format: AccessLogFormat) -> Int {
        format == .json ? 20 : 26
    }

    /// Writes the UTC date for `seconds` since the epoch (clamped to years 1970...9999).
    public static func writeDate(_ seconds: Int64, format: AccessLogFormat, to writer: inout ByteBuffer.Writer) {
        let clamped = IMFFixdate.clamp(seconds)
        let days = Int(clamped / 86_400)
        let secondOfDay = Int(clamped % 86_400)
        // civil_from_days (http://howardhinnant.github.io/date_algorithms.html), days >= 0.
        let z = days + 719_468
        let era = z / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay / 60) % 60
        let second = secondOfDay % 60

        if format == .json {
            writer.append(twoDigits: year / 100)
            writer.append(twoDigits: year % 100)
            writer.append(UInt8(ascii: "-"))
            writer.append(twoDigits: month)
            writer.append(UInt8(ascii: "-"))
            writer.append(twoDigits: day)
            writer.append(UInt8(ascii: "T"))
            writer.append(twoDigits: hour)
            writer.append(UInt8(ascii: ":"))
            writer.append(twoDigits: minute)
            writer.append(UInt8(ascii: ":"))
            writer.append(twoDigits: second)
            writer.append(UInt8(ascii: "Z"))
        } else {
            let monthNames: StaticString = "JanFebMarAprMayJunJulAugSepOctNovDec"
            writer.append(twoDigits: day)
            writer.append(UInt8(ascii: "/"))
            monthNames.withUTF8Buffer { names in
                let base = (month - 1) * 3
                writer.append(names[base])
                writer.append(names[base + 1], names[base + 2])
            }
            writer.append(UInt8(ascii: "/"))
            writer.append(twoDigits: year / 100)
            writer.append(twoDigits: year % 100)
            writer.append(UInt8(ascii: ":"))
            writer.append(twoDigits: hour)
            writer.append(UInt8(ascii: ":"))
            writer.append(twoDigits: minute)
            writer.append(UInt8(ascii: ":"))
            writer.append(twoDigits: second)
            writer.append(" +0000")
        }
    }

    // MARK: Lines

    /// One request's recorded values besides the request itself (whose views stay valid while
    /// the handler runs). The request is passed alongside, not stored, so formatting a line
    /// retains nothing.
    public struct Fields {
        public var status: Int
        /// Response body bytes, or `nil` when unknown (a stream without a length).
        public var responseBytes: Int?
        public var durationNanoseconds: UInt64?
        public var referer: ByteView?
        public var userAgent: ByteView?

        public init(status: Int, responseBytes: Int?, durationNanoseconds: UInt64?,
                    referer: ByteView?, userAgent: ByteView?) {
            self.status = status
            self.responseBytes = responseBytes
            self.durationNanoseconds = durationNanoseconds
            self.referer = referer
            self.userAgent = userAgent
        }

        /// The most bytes the line for `request` and these fields can take after a prefix of
        /// `prefixLength` bytes.
        public func bound(for request: HTTPRequest, format: AccessLogFormat, prefixLength: Int) -> Int {
            var variable = request.path.length + request.query.length
            if format != .common {
                variable += (referer?.length ?? 0) + (userAgent?.length ?? 0)
            }
            return AccessLogLineFormatter.fixedBound + prefixLength + AccessLogLineFormatter.expansion(format) * variable
        }
    }

    /// Writes the part of a line that only changes once per second on a connection:
    /// `<remote> - - [<date>] "` (Common, Combined) or
    /// `{"time":"<date>","remote":"<remote>","protocol":"<protocol>","method":"` (JSON).
    /// `remote` must already be escaped for the format.
    public static func writePrefix(format: AccessLogFormat, remote: Span<UInt8>, seconds: Int64,
                                   protocolName: StaticString, to writer: inout ByteBuffer.Writer) {
        switch format {
        case .common, .combined:
            writer.append(contentsOf: remote)
            writer.append(" - - [")
            writeDate(seconds, format: format, to: &writer)
            writer.append("] \"")
        case .json:
            writer.append("{\"time\":\"")
            writeDate(seconds, format: format, to: &writer)
            writer.append("\",\"remote\":\"")
            writer.append(contentsOf: remote)
            writer.append("\",\"protocol\":\"")
            writer.append(protocolName)
            writer.append("\",\"method\":\"")
        }
    }

    /// Writes one line (newline included) after `prefix` (``writePrefix(format:remote:seconds:protocolName:to:)``).
    /// `protocolName` is `HTTP/1.1`, `HTTP/2.0` or `HTTP/3.0`. The writer must have
    /// ``Fields/bound(for:format:prefixLength:)`` bytes free.
    public static func writeLine(
        _ request: HTTPRequest, _ fields: Fields, format: AccessLogFormat, prefix: Span<UInt8>,
        protocolName: StaticString, to writer: inout ByteBuffer.Writer
    ) {
        writer.append(contentsOf: prefix)
        writeMethod(request.method, to: &writer)
        switch format {
        case .common, .combined:
            writer.append(UInt8(ascii: " "))
            request.withSpan(of: request.path) { appendCLFEscaped($0, to: &writer) }
            if !request.query.isEmpty {
                writer.append(UInt8(ascii: "?"))
                request.withSpan(of: request.query) { appendCLFEscaped($0, to: &writer) }
            }
            writer.append(UInt8(ascii: " "))
            writer.append(protocolName)
            writer.append(UInt8(ascii: "\""), UInt8(ascii: " "))
            writeStatus(fields.status, to: &writer)
            if let bytes = fields.responseBytes, bytes > 0 {
                writer.append(UInt8(ascii: " "))
                writer.append(decimal: bytes)
            } else {
                writer.append(UInt8(ascii: " "), UInt8(ascii: "-"))
            }
            if format == .combined {
                writer.append(" \"")
                writeCLFHeader(fields.referer, of: request, to: &writer)
                writer.append("\" \"")
                writeCLFHeader(fields.userAgent, of: request, to: &writer)
                writer.append(UInt8(ascii: "\""))
            }
        case .json:
            writer.append("\",\"path\":\"")
            request.withSpan(of: request.path) { appendJSONEscaped($0, to: &writer) }
            writer.append("\",\"query\":\"")
            request.withSpan(of: request.query) { appendJSONEscaped($0, to: &writer) }
            writer.append("\",\"status\":")
            writeStatus(fields.status, to: &writer)
            writer.append(",\"bytes\":")
            if let bytes = fields.responseBytes {
                writer.append(decimal: max(bytes, 0))
            } else {
                writer.append("null")
            }
            writer.append(",\"duration_us\":")
            if let nanoseconds = fields.durationNanoseconds {
                writer.append(decimal: Int(truncatingIfNeeded: nanoseconds / 1_000))
            } else {
                writer.append("null")
            }
            writer.append(",\"referer\":")
            writeJSONHeader(fields.referer, of: request, to: &writer)
            writer.append(",\"user_agent\":")
            writeJSONHeader(fields.userAgent, of: request, to: &writer)
            writer.append(UInt8(ascii: "}"))
        }
        writer.append(UInt8(ascii: "\n"))
    }

    /// Three digits for the usual 100...999, decimal otherwise.
    @inline(__always)
    static func writeStatus(_ status: Int, to writer: inout ByteBuffer.Writer) {
        if status >= 100 && status <= 999 {
            writer.append(UInt8(truncatingIfNeeded: 0x30 &+ status / 100))
            writer.append(twoDigits: status % 100)
        } else {
            writer.append(decimal: max(status, 0))
        }
    }

    static func writeMethod(_ method: HTTPMethod, to writer: inout ByteBuffer.Writer) {
        if let name = method.standardName {
            writer.append(name)
        } else if case .other(let token) = method {
            // Method tokens are `tchar`s: nothing to escape.
            for index in 0..<token.count { writer.append(token[index]) }
        }
    }

    static func writeCLFHeader(_ view: ByteView?, of request: HTTPRequest, to writer: inout ByteBuffer.Writer) {
        guard let view, !view.isEmpty else { return writer.append(UInt8(ascii: "-")) }
        request.withSpan(of: view) { appendCLFEscaped($0, to: &writer) }
    }

    static func writeJSONHeader(_ view: ByteView?, of request: HTTPRequest, to writer: inout ByteBuffer.Writer) {
        guard let view else { return writer.append("null") }
        writer.append(UInt8(ascii: "\""))
        request.withSpan(of: view) { appendJSONEscaped($0, to: &writer) }
        writer.append(UInt8(ascii: "\""))
    }
}
