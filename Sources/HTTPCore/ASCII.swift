/// Byte-level ASCII helpers for parsing and serializing HTTP without `String`.
///
/// Everything here reads bytes through bounds-checked `Span<UInt8>`; no unsafe pointers.
public enum ASCII {
    // MARK: Character classes

    /// The RFC 9110 §5.6.2 `tchar` table as 256 bits, one per byte value, in four 64-bit lanes.
    ///
    /// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
    ///       / DIGIT / ALPHA
    ///
    /// A bit table is used instead of a `[Bool]` because its lookups are constant-folded shifts
    /// with no lazy global initialization or array bounds check.
    @inlinable
    public static var tokenTable: (UInt64, UInt64, UInt64, UInt64) {
        (
            0x03FF_6CFA_0000_0000,  // 0x00-0x3F: ! # $ % & ' * + - . 0-9
            0x57FF_FFFF_C7FF_FFFE,  // 0x40-0x7F: A-Z ^ _ ` a-z | ~
            0,                      // 0x80-0xBF
            0                       // 0xC0-0xFF
        )
    }

    /// True when `byte` is an RFC 9110 token character (`tchar`).
    @inlinable
    public static func isTokenCharacter(_ byte: UInt8) -> Bool {
        let table = tokenTable
        let lane: UInt64
        switch byte >> 6 {
        case 0: lane = table.0
        case 1: lane = table.1
        case 2: lane = table.2
        default: lane = table.3
        }
        return (lane >> UInt64(byte & 63)) & 1 == 1
    }

    /// The RFC 9110 §5.5 field-value byte table as 256 bits: `field-vchar` (VCHAR / obs-text)
    /// plus SP and HTAB, which may appear inside a value. CR, LF, NUL and other controls are
    /// excluded.
    @inlinable
    public static var fieldValueTable: (UInt64, UInt64, UInt64, UInt64) {
        (
            0xFFFF_FFFF_0000_0200,  // 0x00-0x3F: HTAB, SP, 0x21-0x3F
            0x7FFF_FFFF_FFFF_FFFF,  // 0x40-0x7F: 0x40-0x7E (DEL excluded)
            0xFFFF_FFFF_FFFF_FFFF,  // 0x80-0xBF: obs-text
            0xFFFF_FFFF_FFFF_FFFF   // 0xC0-0xFF: obs-text
        )
    }

    /// True when `byte` may appear in a field value (RFC 9110 §5.5).
    @inlinable
    public static func isFieldValueCharacter(_ byte: UInt8) -> Bool {
        let table = fieldValueTable
        let lane: UInt64
        switch byte >> 6 {
        case 0: lane = table.0
        case 1: lane = table.1
        case 2: lane = table.2
        default: lane = table.3
        }
        return (lane >> UInt64(byte & 63)) & 1 == 1
    }

    /// True for `0`-`9`.
    @inlinable
    public static func isDigit(_ byte: UInt8) -> Bool {
        byte &- 0x30 < 10
    }

    /// True for `0`-`9`, `a`-`f`, `A`-`F`.
    @inlinable
    public static func isHexDigit(_ byte: UInt8) -> Bool {
        hexDigitValue(byte) != nil
    }

    /// The value of a hexadecimal digit, or `nil`.
    @inlinable
    public static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        let digit = byte &- 0x30
        if digit < 10 { return digit }
        let letter = (byte | 0x20) &- 0x61   // fold to lowercase, then 'a' -> 0
        if letter < 6 { return letter &+ 10 }
        return nil
    }

    /// The lowercase ASCII hex digit for `nibble` (`0...15`).
    @inlinable
    public static func lowercaseHexDigit(_ nibble: UInt8) -> UInt8 {
        assert(nibble < 16)
        return nibble < 10 ? 0x30 &+ nibble : 0x57 &+ nibble   // 0x57 + 10 == 'a'
    }

    // MARK: Case folding

    /// `byte` with `A`-`Z` folded to `a`-`z`; every other byte is unchanged.
    @inlinable
    public static func lowercased(_ byte: UInt8) -> UInt8 {
        byte &- 0x41 < 26 ? byte | 0x20 : byte
    }

    /// The eight bytes of `word` with `A`-`Z` folded to `a`-`z` (SWAR); every other byte,
    /// including `@`, `[`-`` ` `` and bytes 0x80 and above, is unchanged.
    @inlinable
    public static func lowercased(word: UInt64) -> UInt64 {
        let lowBits = word & 0x7F7F_7F7F_7F7F_7F7F
        // Per byte, adding 0x80 - c sets bit 7 when the byte's low seven bits are >= c; the
        // sums stay below 0x100, so no carry crosses into the next byte.
        let atLeastA = lowBits &+ 0x3F3F_3F3F_3F3F_3F3F    // 0x80 - 0x41 ("A")
        let pastZ = lowBits &+ 0x2525_2525_2525_2525       // 0x80 - 0x5B (one past "Z")
        let upper = atLeastA & ~pastZ & ~word & 0x8080_8080_8080_8080
        return word | (upper &>> 2)
    }

    /// Case-insensitive ASCII comparison of `bytes` with `literal`.
    @inlinable
    public static func equalsCaseInsensitive(_ bytes: Span<UInt8>, _ literal: StaticString) -> Bool {
        withSpan(of: literal) { expected in
            guard bytes.count == expected.count else { return false }
            for i in bytes.indices where lowercased(bytes[i]) != lowercased(expected[i]) {
                return false
            }
            return true
        }
    }

    /// Exact byte comparison of `bytes` with `literal`.
    @inlinable
    public static func equals(_ bytes: Span<UInt8>, _ literal: StaticString) -> Bool {
        withSpan(of: literal) { expected in
            guard bytes.count == expected.count else { return false }
            for i in bytes.indices where bytes[i] != expected[i] {
                return false
            }
            return true
        }
    }

    // MARK: Scanning

    /// Index of the first `byte` in `bytes` at or after `start`, or `nil`.
    @inlinable
    public static func firstIndex(of byte: UInt8, in bytes: Span<UInt8>, from start: Int = 0) -> Int? {
        precondition(start >= 0 && start <= bytes.count, "scan start \(start) outside 0...\(bytes.count)")
        var i = start
        while i < bytes.count {
            if bytes[i] == byte { return i }
            i &+= 1
        }
        return nil
    }

    /// Index of the CR of the first CRLF in `bytes` at or after `start`, or `nil` (including
    /// when the input ends in a lone CR, which needs more bytes to decide).
    @inlinable
    public static func firstCRLF(in bytes: Span<UInt8>, from start: Int = 0) -> Int? {
        var i = start
        while let cr = firstIndex(of: 0x0D, in: bytes, from: i) {
            let next = cr &+ 1
            guard next < bytes.count else { return nil }
            if bytes[next] == 0x0A { return cr }
            i = next
        }
        return nil
    }

    // MARK: Hashing

    /// Incremental 32-bit FNV-1a over lowercased bytes, so a scanner can hash a header name in
    /// the same pass that finds its `:` (docs/ROADMAP.md §7, "scan and hash in one pass").
    public struct FNV1a: Sendable, Hashable {
        public static let offsetBasis: UInt32 = 0x811C_9DC5
        public static let prime: UInt32 = 0x0100_0193

        /// The hash of the bytes combined so far.
        public var value: UInt32

        @inlinable
        public init() {
            value = Self.offsetBasis
        }

        /// Folds `byte` to lowercase and mixes it into the hash.
        @inlinable
        public mutating func combineLowercased(_ byte: UInt8) {
            value = (value ^ UInt32(ASCII.lowercased(byte))) &* Self.prime
        }
    }

    /// FNV-1a of the lowercased bytes, computed in a single pass.
    @inlinable
    public static func fnv1aLowercased(_ bytes: Span<UInt8>) -> UInt32 {
        var hasher = FNV1a()
        for i in bytes.indices {
            hasher.combineLowercased(bytes[i])
        }
        return hasher.value
    }

    /// FNV-1a of the lowercased bytes of `literal`, for building well-known-name tables.
    @inlinable
    public static func fnv1aLowercased(_ literal: StaticString) -> UInt32 {
        withSpan(of: literal) { fnv1aLowercased($0) }
    }

    // MARK: Integers

    /// Parses an unsigned decimal integer consisting only of digits.
    ///
    /// Returns `nil` for an empty input, any non-digit byte (including signs and whitespace), or
    /// a value above `UInt64.max`. Leading zeros are accepted.
    @inlinable
    public static func parseDecimal(_ bytes: Span<UInt8>) -> UInt64? {
        guard !bytes.isEmpty else { return nil }
        var value: UInt64 = 0
        for i in bytes.indices {
            let digit = bytes[i] &- 0x30
            guard digit < 10 else { return nil }
            let (times10, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times10.addingReportingOverflow(UInt64(digit))
            guard !overflow1 && !overflow2 else { return nil }
            value = sum
        }
        return value
    }

    /// Parses an unsigned hexadecimal integer (either case, no `0x` prefix), as used for chunk
    /// sizes (RFC 9112 §7.1). The caller strips chunk extensions and line endings first.
    ///
    /// Returns `nil` for an empty input, any non-hex byte, or a value above `UInt64.max`.
    /// Leading zeros are accepted and do not count toward overflow.
    @inlinable
    public static func parseHex(_ bytes: Span<UInt8>) -> UInt64? {
        guard !bytes.isEmpty else { return nil }
        var value: UInt64 = 0
        for i in bytes.indices {
            guard let digit = hexDigitValue(bytes[i]) else { return nil }
            guard value <= UInt64.max >> 4 else { return nil }
            value = value << 4 | UInt64(digit)
        }
        return value
    }

    /// Number of decimal digits needed for `value` (1 for zero).
    @inlinable
    public static func decimalDigitCount(_ value: UInt64) -> Int {
        var count = 1
        var remaining = value
        while remaining >= 10 {
            remaining /= 10
            count += 1
        }
        return count
    }

    /// Number of hexadecimal digits needed for `value` (1 for zero).
    @inlinable
    public static func hexDigitCount(_ value: UInt64) -> Int {
        value == 0 ? 1 : (67 - value.leadingZeroBitCount) / 4
    }
}
