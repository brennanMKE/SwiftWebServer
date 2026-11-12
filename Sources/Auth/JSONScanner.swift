/// A minimal JSON reader for JWT headers and claim sets (RFC 8259): walks one object's members
/// over bytes in place, without allocating. Nested values are validated and skipped.
struct JSONScanner {
    enum Kind: Equatable {
        case string
        case number
        case boolean
        case null
        case object
        case array
    }

    /// A value: its kind and byte range (strings exclude the quotes and are still escaped).
    struct Value {
        var kind: Kind
        var start: Int
        var end: Int
        /// True when a string contains a backslash escape.
        var escaped: Bool
    }

    static let maximumDepth = 16

    let bytes: UnsafeBufferPointer<UInt8>
    var position: Int
    let end: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        self.position = start
        self.end = end ?? bytes.count
    }

    // MARK: Objects and arrays

    /// Calls `member(key, value)` for each member of the object at the scanner's position.
    /// Returns false on malformed input, or when `member` returns false; on success the whole
    /// input must have been one object (trailing whitespace allowed).
    mutating func forEachMember(_ member: (Value, Value) -> Bool) -> Bool {
        skipWhitespace()
        guard take(UInt8(ascii: "{")) else { return false }
        skipWhitespace()
        if take(UInt8(ascii: "}")) { return atEnd() }
        while true {
            skipWhitespace()
            guard let key = string() else { return false }
            skipWhitespace()
            guard take(UInt8(ascii: ":")) else { return false }
            skipWhitespace()
            guard let value = value(depth: 1) else { return false }
            guard member(key, value) else { return false }
            skipWhitespace()
            if take(UInt8(ascii: ",")) { continue }
            guard take(UInt8(ascii: "}")) else { return false }
            return atEnd()
        }
    }

    /// Calls `element` for each element of the array spanning `value`.
    static func forEachElement(of value: Value, in bytes: UnsafeBufferPointer<UInt8>, _ element: (Value) -> Bool) -> Bool {
        var scanner = JSONScanner(bytes, from: value.start &+ 1, to: value.end &- 1)
        scanner.skipWhitespace()
        if scanner.position == scanner.end { return true }
        while true {
            scanner.skipWhitespace()
            guard let item = scanner.value(depth: 1), element(item) else { return false }
            scanner.skipWhitespace()
            if scanner.position == scanner.end { return true }
            guard scanner.take(UInt8(ascii: ",")) else { return false }
        }
    }

    mutating func atEnd() -> Bool {
        skipWhitespace()
        return position == end
    }

    // MARK: Values

    mutating func value(depth: Int) -> Value? {
        guard position < end, depth <= Self.maximumDepth else { return nil }
        let start = position
        switch bytes[position] {
        case UInt8(ascii: "\""):
            return string()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let open = bytes[position]
            let close = open == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
            position &+= 1
            skipWhitespace()
            if take(close) { return Value(kind: open == UInt8(ascii: "{") ? .object : .array, start: start, end: position, escaped: false) }
            while true {
                skipWhitespace()
                if open == UInt8(ascii: "{") {
                    guard string() != nil else { return nil }
                    skipWhitespace()
                    guard take(UInt8(ascii: ":")) else { return nil }
                    skipWhitespace()
                }
                guard value(depth: depth &+ 1) != nil else { return nil }
                skipWhitespace()
                if take(UInt8(ascii: ",")) { continue }
                guard take(close) else { return nil }
                return Value(kind: open == UInt8(ascii: "{") ? .object : .array, start: start, end: position, escaped: false)
            }
        case UInt8(ascii: "t"):
            return literal("true", kind: .boolean)
        case UInt8(ascii: "f"):
            return literal("false", kind: .boolean)
        case UInt8(ascii: "n"):
            return literal("null", kind: .null)
        default:
            return number()
        }
    }

    mutating func string() -> Value? {
        guard take(UInt8(ascii: "\"")) else { return nil }
        let start = position
        var escaped = false
        while position < end {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                let value = Value(kind: .string, start: start, end: position, escaped: escaped)
                position &+= 1
                return value
            }
            if byte < 0x20 { return nil }
            if byte == UInt8(ascii: "\\") {
                escaped = true
                position &+= 1
                guard position < end else { return nil }
                switch bytes[position] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                     UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    break
                case UInt8(ascii: "u"):
                    guard position &+ 4 < end else { return nil }
                    for k in 1...4 where !isHex(bytes[position &+ k]) { return nil }
                    position &+= 4
                default:
                    return nil
                }
            }
            position &+= 1
        }
        return nil
    }

    mutating func number() -> Value? {
        let start = position
        _ = take(UInt8(ascii: "-"))
        guard digits() else { return nil }
        if take(UInt8(ascii: ".")) { guard digits() else { return nil } }
        if position < end, bytes[position] | 0x20 == UInt8(ascii: "e") {
            position &+= 1
            if !take(UInt8(ascii: "+")) { _ = take(UInt8(ascii: "-")) }
            guard digits() else { return nil }
        }
        return Value(kind: .number, start: start, end: position, escaped: false)
    }

    mutating func digits() -> Bool {
        let start = position
        while position < end, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") { position &+= 1 }
        return position > start
    }

    mutating func literal(_ text: StaticString, kind: Kind) -> Value? {
        let start = position
        let count = text.utf8CodeUnitCount
        guard end &- position >= count else { return nil }
        for k in 0..<count where bytes[position &+ k] != text.utf8Start[k] { return nil }
        position &+= count
        return Value(kind: kind, start: start, end: position, escaped: false)
    }

    @inline(__always)
    mutating func take(_ byte: UInt8) -> Bool {
        guard position < end, bytes[position] == byte else { return false }
        position &+= 1
        return true
    }

    @inline(__always)
    mutating func skipWhitespace() {
        while position < end {
            let byte = bytes[position]
            guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else { return }
            position &+= 1
        }
    }

    @inline(__always)
    func isHex(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "f"))
    }

    // MARK: Reading values

    /// Calls `body` with each byte of the decoded string `value` (UTF-8; `\uXXXX` escapes and
    /// surrogate pairs decoded). Stops early when `body` returns false; returns false then or
    /// on a lone surrogate.
    static func forEachDecodedByte(of value: Value, in bytes: UnsafeBufferPointer<UInt8>, _ body: (UInt8) -> Bool) -> Bool {
        var i = value.start
        func hex4(_ at: Int) -> UInt32 {
            var result: UInt32 = 0
            for k in 0..<4 {
                let byte = bytes[at &+ k]
                let digit = byte <= UInt8(ascii: "9") ? byte &- UInt8(ascii: "0") : (byte | 0x20) &- UInt8(ascii: "a") &+ 10
                result = result << 4 | UInt32(digit)
            }
            return result
        }
        while i < value.end {
            let byte = bytes[i]
            if byte != UInt8(ascii: "\\") {
                guard body(byte) else { return false }
                i &+= 1
                continue
            }
            let escape = bytes[i &+ 1]
            i &+= 2
            var scalar: UInt32
            switch escape {
            case UInt8(ascii: "b"): scalar = 0x08
            case UInt8(ascii: "f"): scalar = 0x0C
            case UInt8(ascii: "n"): scalar = 0x0A
            case UInt8(ascii: "r"): scalar = 0x0D
            case UInt8(ascii: "t"): scalar = 0x09
            case UInt8(ascii: "u"):
                scalar = hex4(i)
                i &+= 4
                if scalar >= 0xD800 && scalar <= 0xDBFF {
                    guard i &+ 6 <= value.end, bytes[i] == UInt8(ascii: "\\"), bytes[i &+ 1] == UInt8(ascii: "u") else { return false }
                    let low = hex4(i &+ 2)
                    guard low >= 0xDC00 && low <= 0xDFFF else { return false }
                    scalar = 0x10000 &+ ((scalar &- 0xD800) << 10) &+ (low &- 0xDC00)
                    i &+= 6
                } else if scalar >= 0xDC00 && scalar <= 0xDFFF {
                    return false
                }
            default: scalar = UInt32(escape)   // \" \\ \/
            }
            // UTF-8 encode.
            if scalar < 0x80 {
                guard body(UInt8(scalar)) else { return false }
            } else if scalar < 0x800 {
                guard body(UInt8(0xC0 | scalar >> 6)), body(UInt8(0x80 | scalar & 0x3F)) else { return false }
            } else if scalar < 0x10000 {
                guard body(UInt8(0xE0 | scalar >> 12)), body(UInt8(0x80 | scalar >> 6 & 0x3F)),
                      body(UInt8(0x80 | scalar & 0x3F)) else { return false }
            } else {
                guard body(UInt8(0xF0 | scalar >> 18)), body(UInt8(0x80 | scalar >> 12 & 0x3F)),
                      body(UInt8(0x80 | scalar >> 6 & 0x3F)), body(UInt8(0x80 | scalar & 0x3F)) else { return false }
            }
        }
        return true
    }

    /// True when the string `value` decodes to exactly `expected`. Does not allocate.
    static func string(_ value: Value, in bytes: UnsafeBufferPointer<UInt8>, equals expected: [UInt8]) -> Bool {
        guard value.kind == .string else { return false }
        if !value.escaped {
            guard value.end &- value.start == expected.count else { return false }
            for k in 0..<expected.count where bytes[value.start &+ k] != expected[k] { return false }
            return true
        }
        var k = 0
        let complete = forEachDecodedByte(of: value, in: bytes) { byte in
            guard k < expected.count, expected[k] == byte else { return false }
            k &+= 1
            return true
        }
        return complete && k == expected.count
    }

    /// True when the string `value` decodes to `literal`.
    static func string(_ value: Value, in bytes: UnsafeBufferPointer<UInt8>, equals literal: StaticString) -> Bool {
        guard value.kind == .string else { return false }
        let count = literal.utf8CodeUnitCount, start = literal.utf8Start
        var k = 0
        let complete = forEachDecodedByte(of: value, in: bytes) { byte in
            guard k < count, start[k] == byte else { return false }
            k &+= 1
            return true
        }
        return complete && k == count
    }

    /// The decoded string `value` (allocates).
    static func decodedString(_ value: Value, in bytes: UnsafeBufferPointer<UInt8>) -> String? {
        if !value.escaped {
            // Straight from the bytes: no intermediate array (and no allocation for short strings).
            return String(validating: UnsafeBufferPointer(rebasing: bytes[value.start..<value.end]), as: UTF8.self)
        }
        var output: [UInt8] = []
        output.reserveCapacity(value.end &- value.start)
        guard forEachDecodedByte(of: value, in: bytes, { output.append($0); return true }) else { return nil }
        return String(validating: output, as: UTF8.self)
    }

    /// A NumericDate (RFC 7519 §2): seconds, possibly fractional or with an exponent; the
    /// integer part, or `nil` when not a number or out of range.
    static func seconds(_ value: Value, in bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard value.kind == .number else { return nil }
        var i = value.start
        var negative = false
        if bytes[i] == UInt8(ascii: "-") { negative = true; i &+= 1 }
        var result: Int64 = 0
        while i < value.end, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
            let (times, o1) = result.multipliedReportingOverflow(by: 10)
            let (sum, o2) = times.addingReportingOverflow(Int64(bytes[i] &- UInt8(ascii: "0")))
            guard !o1, !o2 else { return nil }
            result = sum
            i &+= 1
        }
        // Skip a fraction; refuse exponents (no issuer writes dates that way).
        if i < value.end, bytes[i] == UInt8(ascii: ".") {
            i &+= 1
            while i < value.end, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i &+= 1 }
        }
        guard i == value.end else { return nil }
        return negative ? -result : result
    }
}
