public import HTTPCore
public import HTTP1

/// The outcome of parsing one request head, in a form both ``ReferenceHTTP1Parser`` and
/// `HTTP1Parser` can produce, so a differential test can compare them with `==`.
///
/// Errors compare by status code only: which of several 400 reasons a parser names is not
/// part of the contract, but the status, and the byte position that decides it, is.
public enum HTTP1HeadOutcome: Hashable, Sendable, CustomStringConvertible {
    case needMoreBytes
    case error(status: Int)
    case complete(Head)

    public struct Field: Hashable, Sendable {
        /// The name as received (any case).
        public var name: String
        /// The well-known ID the name resolves to.
        public var id: HTTPFieldName
        public var value: String

        public init(name: String, id: HTTPFieldName, value: String) {
            self.name = name
            self.id = id
            self.value = value
        }
    }

    public struct Head: Hashable, Sendable {
        public var method: String
        public var version: HTTP1Version
        public var form: HTTP1RequestTargetForm
        public var target: String
        public var scheme: String
        public var authority: String
        public var path: String
        public var query: String
        public var pathHasPercent: Bool
        public var queryHasPercent: Bool
        public var fields: [Field]
        public var framing: HTTP1RequestFraming
        /// Bytes consumed by the head.
        public var length: Int
    }

    /// The outcome of an `HTTP1Parser.parseHead(_:)` call. `buffer` is the buffer after the
    /// call; for a complete head its ranges are read from it.
    public init(_ result: HTTP1ParseResult, parser: HTTP1Parser, buffer: ByteBuffer) {
        switch result {
        case .needMoreBytes:
            self = .needMoreBytes
        case .error(let error):
            self = .error(status: error.status.code)
        case .complete:
            let head = parser.head
            func string(_ view: ByteView) -> String {
                buffer.withSpan(of: view) { bytes in
                    var scalars = String.UnicodeScalarView()
                    for i in bytes.indices { scalars.append(Unicode.Scalar(bytes[i])) }
                    return String(scalars)
                }
            }
            let index = parser.fields
            var fields: [Field] = []
            for i in 0..<index.count {
                fields.append(Field(name: string(index.nameViews[i]), id: index.names[i],
                                    value: string(index.valueViews[i])))
            }
            self = .complete(Head(
                method: head.method.description, version: head.version, form: head.targetForm,
                target: string(head.target), scheme: string(head.scheme),
                authority: string(head.authority), path: string(head.path), query: string(head.query),
                pathHasPercent: head.pathHasPercent, queryHasPercent: head.queryHasPercent,
                fields: fields, framing: head.framing, length: head.length))
        }
    }

    public var description: String {
        switch self {
        case .needMoreBytes: "needMoreBytes"
        case .error(let status): "error(\(status))"
        case .complete(let head): "complete(\(head))"
        }
    }
}

/// A slow, obviously-correct HTTP/1.1 request-head parser for differential testing
/// (docs/ROADMAP.md §7, "keep a validating path").
///
/// It works on the whole input at once, as `String`s of Latin-1 characters (one character
/// per byte), line by line. It implements the rules documented on `HTTP1Parser` without
/// sharing any of its code; in particular, errors are decided by the earliest offending byte,
/// and a limit counts as an offending byte at the first position past it.
public enum ReferenceHTTP1Parser {
    public static func parse(_ bytes: [UInt8], limits: HTTP1ParserLimits = HTTP1ParserLimits()) -> HTTP1HeadOutcome {
        // A head longer than the limit is the same as the prefix that fits, except that
        // "need more bytes" becomes 431: the next byte would cross the limit.
        if bytes.count > limits.maxHeadBytes {
            let outcome = parseUnbounded(Array(bytes.prefix(limits.maxHeadBytes)), limits: limits)
            return outcome == .needMoreBytes ? .error(status: 431) : outcome
        }
        return parseUnbounded(bytes, limits: limits)
    }

    // MARK: Characters

    static let tchars = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)

    static func isTchar(_ c: Unicode.Scalar) -> Bool { tchars.contains(c) }
    /// Bytes allowed in a request target or version token: visible ASCII.
    static func isVisible(_ c: Unicode.Scalar) -> Bool { c.value >= 0x21 && c.value <= 0x7E }
    static func isFieldValueChar(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || isVisible(c) || c.value >= 0x80
    }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
    static func isAlpha(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }

    static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func trimOWS(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return string(scalars)
    }

    static let wellKnownNames: [String: HTTPFieldName] = Dictionary(
        uniqueKeysWithValues: HTTPFieldName.allCases.filter(\.isWellKnown).map { ($0.canonicalName.description, $0) })

    static func wellKnownID(_ name: String) -> HTTPFieldName {
        wellKnownNames[name.lowercased()] ?? .unknown
    }

    // MARK: Parsing

    static func parseUnbounded(_ bytes: [UInt8], limits: HTTP1ParserLimits) -> HTTP1HeadOutcome {
        let text = string(bytes.map { Unicode.Scalar($0) })
        let c = Array(text.unicodeScalars)   // c[i] is byte i
        let n = c.count
        let bad: HTTP1HeadOutcome = .error(status: 400)

        // Leading empty lines.
        var pos = 0
        while pos < n && c[pos] == "\r" {
            if pos + 1 >= n { return .needMoreBytes }
            if c[pos + 1] != "\n" { return bad }
            pos += 2
        }
        if pos >= n { return .needMoreBytes }

        // Request line: the bytes before the first CR or LF.
        let lineStart = pos
        let terminator = (lineStart..<n).first { c[$0] == "\r" || c[$0] == "\n" }
        let content = Array(c[lineStart..<(terminator ?? n)])
        let tooLong = content.count > limits.maxRequestLineLength
        let examined = Array(content.prefix(limits.maxRequestLineLength))
        // What happens when a part runs to the end of what was examined.
        func incompleteLine() -> HTTP1HeadOutcome {
            if tooLong { return .error(status: 414) }
            if terminator != nil { return bad }    // CR or LF inside the method or target
            return .needMoreBytes
        }

        // Method.
        let sp1 = examined.firstIndex(of: " ")
        let methodChars = Array(examined[..<(sp1 ?? examined.count)])
        if let firstBad = methodChars.firstIndex(where: { !isTchar($0) }), firstBad <= HTTPMethod.Token.maximumLength {
            return bad
        }
        if methodChars.count > HTTPMethod.Token.maximumLength { return .error(status: 501) }
        guard let sp1 else { return incompleteLine() }
        if sp1 == 0 { return bad }
        let method = string(methodChars)

        // Target.
        let afterMethod = Array(examined[(sp1 + 1)...])
        let sp2 = afterMethod.firstIndex(of: " ")
        let targetChars = Array(afterMethod[..<(sp2 ?? afterMethod.count)])
        if targetChars.contains(where: { !isVisible($0) }) { return bad }
        guard let sp2 else { return incompleteLine() }
        if targetChars.isEmpty { return bad }
        let target = string(targetChars)
        guard var head = classifyTarget(target, method: method) else { return bad }

        // Version.
        let versionChars = Array(afterMethod[(sp2 + 1)...])
        if versionChars.contains(where: { !isVisible($0) }) { return bad }
        if tooLong { return .error(status: 414) }
        guard let terminator else { return .needMoreBytes }
        if c[terminator] == "\n" { return bad }
        let version = string(versionChars)
        switch version {
        case "HTTP/1.1": head.version = .http1_1
        case "HTTP/1.0": head.version = .http1_0
        default:
            let v = Array(version.unicodeScalars)
            if v.count == 8 && version.hasPrefix("HTTP/") && isDigit(v[5]) && v[6] == "." && isDigit(v[7]) {
                return .error(status: 505)
            }
            return bad
        }
        if terminator + 1 >= n { return .needMoreBytes }
        if c[terminator + 1] != "\n" { return bad }
        pos = terminator + 2

        // Field lines.
        var fields: [HTTP1HeadOutcome.Field] = []
        while true {
            if pos >= n { return .needMoreBytes }
            let first = c[pos]
            if first == "\r" {
                if pos + 1 >= n { return .needMoreBytes }
                if c[pos + 1] != "\n" { return bad }
                pos += 2
                break
            }
            if first == "\n" { return bad }
            if first == " " || first == "\t" { return bad }            // obs-fold
            if fields.count >= limits.maxHeaderCount { return .error(status: 431) }

            let end = (pos..<n).first { c[$0] == "\r" || c[$0] == "\n" }
            let line = Array(c[pos..<(end ?? n)])
            let colon = line.firstIndex(of: ":")
            let nameChars = Array(line[..<(colon ?? line.count)])
            if nameChars.contains(where: { !isTchar($0) }) { return bad }   // includes SP before ':'
            guard let colon else { return end == nil ? .needMoreBytes : bad }
            if nameChars.isEmpty { return bad }
            let valueChars = Array(line[(colon + 1)...])
            if valueChars.contains(where: { !isFieldValueChar($0) }) { return bad }
            guard let end else { return .needMoreBytes }
            if c[end] == "\n" { return bad }
            if end + 1 >= n { return .needMoreBytes }
            if c[end + 1] != "\n" { return bad }
            let name = string(nameChars)
            fields.append(HTTP1HeadOutcome.Field(name: name, id: wellKnownID(name),
                                                 value: trimOWS(string(valueChars))))
            pos = end + 2
        }
        head.fields = fields
        head.length = pos

        // Host (RFC 9112 §3.2).
        let hosts = fields.filter { $0.name.lowercased() == "host" }.count
        if hosts > 1 { return bad }
        if hosts == 0 && head.version == .http1_1 { return bad }

        // Framing (RFC 9112 §6.1, §6.3).
        let te = fields.filter { $0.name.lowercased() == "transfer-encoding" }
        let cl = fields.filter { $0.name.lowercased() == "content-length" }
        if !te.isEmpty {
            if !cl.isEmpty { return bad }
            if head.version == .http1_0 { return bad }
            let codings = te.flatMap { listElements($0.value) }.map { $0.lowercased() }
            guard codings.last == "chunked", codings.filter({ $0 == "chunked" }).count == 1 else { return bad }
            if codings.count > 1 { return .error(status: 501) }
            head.framing = .chunked
        } else if !cl.isEmpty {
            var value: UInt64?
            var conflicting = false
            for field in cl {
                let elements = listElements(field.value)
                if elements.isEmpty { return bad }
                for element in elements {
                    guard element.unicodeScalars.allSatisfy(isDigit), let number = UInt64(element) else { return bad }
                    if let value, value != number { conflicting = true }
                    value = number
                }
            }
            if conflicting { return bad }
            head.framing = .contentLength(value!)
        } else {
            head.framing = .none
        }
        return .complete(head)
    }

    /// Splits a list-valued field at commas outside quoted strings, trims OWS and drops
    /// empty elements (RFC 9110 §5.6.1).
    static func listElements(_ value: String) -> [String] {
        var elements: [String] = []
        var current: [Unicode.Scalar] = []
        var quoted = false
        var escaped = false
        for c in value.unicodeScalars {
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                current.append(c)
            } else if c == "\"" {
                quoted = true
                current.append(c)
            } else if c == "," {
                elements.append(trimOWS(string(current)))
                current = []
            } else {
                current.append(c)
            }
        }
        elements.append(trimOWS(string(current)))
        return elements.filter { !$0.isEmpty }
    }

    /// The target form and its parts, or `nil` for an invalid target (RFC 9112 §3.2).
    static func classifyTarget(_ target: String, method: String) -> HTTP1HeadOutcome.Head? {
        let beforeQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var head = HTTP1HeadOutcome.Head(
            method: method, version: .http1_1, form: .origin, target: target, scheme: "", authority: "",
            path: "", query: "", pathHasPercent: beforeQuery.contains("%"),
            queryHasPercent: target.contains("?") && target[target.firstIndex(of: "?")!...].contains("%"),
            fields: [], framing: .none, length: 0)
        func setPathAndQuery(_ rest: Substring) {
            if let q = rest.firstIndex(of: "?") {
                head.path = String(rest[..<q])
                head.query = String(rest[rest.index(after: q)...])
            } else {
                head.path = String(rest)
            }
        }

        if method == "CONNECT" {
            guard !target.contains(where: { "/?@#".contains($0) }),
                  let colon = target.lastIndex(of: ":") else { return nil }
            let host = target[..<colon]
            let port = target[target.index(after: colon)...]
            guard !host.isEmpty, (1...5).contains(port.count),
                  port.unicodeScalars.allSatisfy(isDigit) else { return nil }
            head.form = .authority
            head.authority = target
            return head
        }
        if target.hasPrefix("/") {
            head.form = .origin
            setPathAndQuery(target[...])
            return head
        }
        if target.hasPrefix("*") {
            guard target == "*", method == "OPTIONS" else { return nil }
            head.form = .asterisk
            head.path = "*"
            return head
        }
        // absolute-form
        let t = Array(target)
        guard let schemeLength = (0..<t.count).first(where: { t.count - $0 >= 3 && String(t[$0..<($0 + 3)]) == "://" })
        else { return nil }
        let scheme = target.prefix(schemeLength)
        let schemeScalars = Array(scheme.unicodeScalars)
        guard let first = schemeScalars.first, isAlpha(first),
              schemeScalars.allSatisfy({ isAlpha($0) || isDigit($0) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        let rest = target.dropFirst(schemeLength + 3)
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        head.form = .absolute
        head.scheme = String(scheme)
        head.authority = String(authority)
        setPathAndQuery(rest[authorityEnd...])
        return head
    }
}
