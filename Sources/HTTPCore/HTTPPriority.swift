/// An RFC 9218 priority: urgency `u` (0 most urgent … 7, default 3) and incremental `i`
/// (default false).
///
/// Shared by HTTP/2 (#0065) and HTTP/3 (#0107) for the `priority` header field and the
/// PRIORITY_UPDATE frames' Priority Field Value. ``apply(_:)`` parses the value as a Structured
/// Field Dictionary (RFC 8941 §3.2) directly from the bytes, without allocating.
///
/// Per RFC 9218 §4: a value that is not a valid dictionary is ignored as a whole; a `u` that
/// is not an integer in 0…7, or an `i` that is not a boolean, is ignored; unknown keys and
/// all parameters are ignored; a later member with the same key replaces an earlier one.
public struct HTTPPriority: Sendable, Hashable {
    /// 0 (most urgent) … 7 (least urgent).
    public var urgency: UInt8
    /// Whether the response can be used as it arrives, so it may share bandwidth with others
    /// of the same urgency.
    public var incremental: Bool

    public static let defaultUrgency: UInt8 = 3
    /// `u=3`, not incremental: what a request without a `priority` field gets.
    public static let `default` = HTTPPriority()

    @inlinable
    public init(urgency: UInt8 = HTTPPriority.defaultUrgency, incremental: Bool = false) {
        precondition(urgency <= 7, "urgency is 0...7")
        self.urgency = urgency
        self.incremental = incremental
    }

    /// The priority a field value alone signals: the defaults, overridden by its members.
    /// An invalid value yields the defaults.
    @inlinable
    public init(parsing value: UnsafeRawBufferPointer) {
        self.init()
        apply(value)
    }

    /// Applies the members of a `priority` field value on top of this priority: parameters
    /// the value carries replace these, the others stay. Returns false, changing nothing, when
    /// the value is not a valid Structured Field Dictionary.
    @discardableResult
    public mutating func apply(_ value: UnsafeRawBufferPointer) -> Bool {
        var parser = Parser(bytes: value)
        guard let parsed = parser.parseDictionary() else { return false }
        if let u = parsed.urgency { urgency = u }
        if let i = parsed.incremental { incremental = i }
        return true
    }

    /// ``apply(_:)`` for a span.
    @discardableResult
    public mutating func apply(_ value: Span<UInt8>) -> Bool {
        value.withUnsafeBytes { apply($0) }
    }

    /// Applies every `priority` field of `fields`, in order. Returns whether there was one.
    @discardableResult
    public mutating func apply(from fields: some HTTPFieldCollection) -> Bool {
        var found = false
        fields.withFieldStorage { index, arena in
            for position in 0..<index.count where index[position].name == .priority {
                found = true
                _ = arena.withSpan(of: index[position].valueView) { apply($0) }
            }
        }
        return found
    }

    /// Orders streams for sending: lower urgency first; at equal urgency non-incremental
    /// responses first, one at a time in stream order (`id`), then incremental ones, which
    /// share (equal keys).
    @inlinable
    public func schedulingKey(streamID id: UInt64) -> (UInt8, UInt8, UInt64) {
        (urgency, incremental ? 1 : 0, incremental ? 0 : id)
    }

    // MARK: Parser

    /// A minimal RFC 8941 dictionary reader that keeps only `u` and `i`.
    struct Parser {
        let bytes: UnsafeRawBufferPointer
        var at = 0

        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        enum Item {
            case integer(Int64)
            case boolean(Bool)
            case other
        }

        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func skip(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            at += 1
            return true
        }

        mutating func skipSP() { while peek == 0x20 { at += 1 } }
        mutating func skipOWS() { while peek == 0x20 || peek == 0x09 { at += 1 } }

        mutating func parseDictionary() -> (urgency: UInt8?, incremental: Bool?)? {
            var urgency: UInt8?
            var incremental: Bool?
            skipOWS()
            if peek == nil { return (nil, nil) }
            while true {
                guard let key = parseKey() else { return nil }
                let value: Item
                if skip(0x3D) {  // "="
                    if peek == 0x28 {  // "(": inner list
                        guard parseInnerList() else { return nil }
                        value = .other
                    } else {
                        guard let item = parseBareItem() else { return nil }
                        value = item
                    }
                } else {
                    value = .boolean(true)
                }
                guard parseParameters() else { return nil }
                if key == 0x75 {  // "u": an out-of-range or non-integer value is ignored
                    switch value {
                    case .integer(let n) where n >= 0 && n <= 7: urgency = UInt8(n)
                    default: urgency = nil
                    }
                } else if key == 0x69 {  // "i"
                    if case .boolean(let b) = value { incremental = b } else { incremental = nil }
                }
                skipOWS()
                if peek == nil { return (urgency, incremental) }
                guard skip(0x2C) else { return nil }  // ","
                skipOWS()
                if peek == nil { return nil }  // trailing comma
            }
        }

        /// Returns the key's byte when it is one byte long, 0 for any other valid key.
        mutating func parseKey() -> UInt8? {
            guard let first = peek, (first >= 0x61 && first <= 0x7A) || first == 0x2A else { return nil }
            at += 1
            var length = 1
            while let b = peek,
                  (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2D || b == 0x2E
                    || b == 0x2A {
                at += 1
                length += 1
            }
            return length == 1 ? first : 0
        }

        mutating func parseParameters() -> Bool {
            while skip(0x3B) {  // ";"
                skipSP()
                guard parseKey() != nil else { return false }
                if skip(0x3D) { guard parseBareItem() != nil else { return false } }
            }
            return true
        }

        mutating func parseInnerList() -> Bool {
            guard skip(0x28) else { return false }
            while true {
                skipSP()
                if skip(0x29) { return true }  // ")"; parameters follow in the caller
                guard parseBareItem() != nil, parseParameters() else { return false }
                guard peek == 0x20 || peek == 0x29 else { return false }
            }
        }

        mutating func parseBareItem() -> Item? {
            guard let b = peek else { return nil }
            switch b {
            case 0x2D, 0x30...0x39: return parseNumber()
            case 0x22: return parseString() ? .other : nil
            case 0x3F:  // "?"
                at += 1
                if skip(0x30) { return .boolean(false) }
                if skip(0x31) { return .boolean(true) }
                return nil
            case 0x3A:  // ":" byte sequence
                at += 1
                while let c = peek, c != 0x3A {
                    guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                            || c == 0x2B || c == 0x2F || c == 0x3D else { return nil }
                    at += 1
                }
                return skip(0x3A) ? .other : nil
            case 0x40:  // "@" date (RFC 9651)
                at += 1
                guard case .integer = parseNumber() else { return nil }
                return .other
            case 0x2A, 0x41...0x5A, 0x61...0x7A:  // token
                at += 1
                while let c = peek, c > 0x20, c < 0x7F,
                      c != 0x22, c != 0x28, c != 0x29, c != 0x2C, c != 0x3B, c != 0x3D, c != 0x3C, c != 0x3E,
                      c != 0x40, c != 0x5B, c != 0x5C, c != 0x5D, c != 0x7B, c != 0x7D, c != 0x3F {
                    at += 1
                }
                return .other
            default:
                return nil
            }
        }

        mutating func parseNumber() -> Item? {
            let negative = skip(0x2D)
            var value: Int64 = 0
            var digits = 0
            while let c = peek, c >= 0x30 && c <= 0x39 {
                guard digits < 15 else { return nil }
                value = value * 10 + Int64(c - 0x30)
                digits += 1
                at += 1
            }
            guard digits > 0 else { return nil }
            if skip(0x2E) {  // decimal
                guard digits <= 12 else { return nil }
                var fraction = 0
                while let c = peek, c >= 0x30 && c <= 0x39 {
                    fraction += 1
                    at += 1
                }
                guard fraction >= 1 && fraction <= 3 else { return nil }
                return .other
            }
            return .integer(negative ? -value : value)
        }

        mutating func parseString() -> Bool {
            guard skip(0x22) else { return false }
            while let c = peek {
                at += 1
                if c == 0x22 { return true }
                if c == 0x5C {
                    guard let e = peek, e == 0x22 || e == 0x5C else { return false }
                    at += 1
                } else if c < 0x20 || c > 0x7E {
                    return false
                }
            }
            return false
        }
    }
}
