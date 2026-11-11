import HPACK

/// A header field as strings, for comparing against RFC 7541 Appendix C.
struct Field: Equatable, CustomStringConvertible {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    var description: String { "\(name): \(value)" }

    /// RFC 7541 §4.1 size.
    var size: Int { name.utf8.count + value.utf8.count + 32 }
}

/// Calls `body` with a span of `bytes` (`Array.span` needs macOS 26).
func withSpan<R>(_ bytes: [UInt8], _ body: (Span<UInt8>) throws -> R) rethrows -> R {
    try bytes.withUnsafeBufferPointer { try body($0.span) }
}

/// Calls `body` with a span of the UTF-8 bytes of `string`.
func withSpan<R>(_ string: String, _ body: (Span<UInt8>) throws -> R) rethrows -> R {
    try withSpan(Array(string.utf8), body)
}

/// Calls `body` with spans of `field`'s name and value.
func withSpans<R>(_ field: Field, _ body: (Span<UInt8>, Span<UInt8>) throws -> R) rethrows -> R {
    try withSpan(field.name) { name in try withSpan(field.value) { value in try body(name, value) } }
}

func string(_ span: Span<UInt8>) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(span.count)
    for i in span.indices { bytes.append(span[i]) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Bytes from a hex dump such as `"8286 8441"`; whitespace is ignored.
func hex(_ text: String) -> [UInt8] {
    let digits = text.filter { !$0.isWhitespace }
    precondition(digits.count % 2 == 0, "odd hex length")
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

extension HPACKDynamicTable {
    /// The entries, newest first.
    var fields: [Field] {
        (0..<count).map { position in
            withEntry(at: position) { name, value in Field(string(name), string(value)) }
        }
    }

    /// Inserts `field`; returns whether it was added.
    @discardableResult
    mutating func insert(_ field: Field) -> Bool {
        withSpans(field) { name, value in insert(name: name, value: value) }
    }
}

/// A deterministic generator (SplitMix64) for seeded fuzz tests.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
