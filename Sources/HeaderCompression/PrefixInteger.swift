/// Prefix-coded integers (RFC 7541 §5.1), used by both HPACK and QPACK (RFC 9204 §4.1.1).
///
/// An integer occupies the low `prefixBits` bits of a first byte whose high bits carry
/// representation flags; values that do not fit continue in 7-bit groups, least significant
/// first, with the high bit of each continuation byte set while more follow.
public enum PrefixInteger {
    /// The largest value QPACK accepts: QUIC integers are bounded by 2^62 − 1 (RFC 9000 §16).
    public static let maxQUICValue: UInt64 = (1 << 62) - 1

    /// A default bound for HPACK. HPACK integers are indices, string lengths and table sizes,
    /// none of which can sensibly exceed 2^32 − 1; callers may pass something smaller still.
    public static let maxHPACKValue: UInt64 = UInt64(UInt32.max)

    /// Outcome of ``decode(_:prefixBits:maxValue:)``.
    public enum DecodeResult: Equatable, Sendable {
        /// The integer and the number of bytes it occupied, including the first byte.
        case value(UInt64, consumed: Int)
        /// The input ends before the integer does; retry with more bytes.
        case needsMoreData
        /// The integer exceeds the bound, or its encoding is longer than any valid value needs.
        case overflow
    }

    /// The number of bytes `value` occupies with an `prefixBits`-bit prefix.
    @inlinable
    public static func encodedLength(_ value: UInt64, prefixBits: Int) -> Int {
        precondition((1...8).contains(prefixBits), "prefixBits must be 1...8")
        let maxPrefix = UInt64(1 << prefixBits) - 1
        if value < maxPrefix { return 1 }
        var rest = value - maxPrefix
        var length = 2
        while rest >= 0x80 {
            rest >>= 7
            length += 1
        }
        return length
    }

    /// Appends `value` with an `prefixBits`-bit prefix. `flags` supplies the first byte's bits
    /// above the prefix; any of its bits inside the prefix are ignored.
    ///
    /// - Precondition: `prefixBits` is 1...8 and `value` ≤ ``maxQUICValue``.
    @inlinable
    public static func encode<Sink: ByteSink>(
        _ value: UInt64, prefixBits: Int, flags: UInt8 = 0, into sink: inout Sink
    ) {
        precondition((1...8).contains(prefixBits), "prefixBits must be 1...8")
        precondition(value <= maxQUICValue, "prefix integer exceeds 2^62 - 1")
        let mask = UInt8(truncatingIfNeeded: (1 << prefixBits) - 1)
        let flagBits = flags & ~mask
        let maxPrefix = UInt64(mask)
        if value < maxPrefix {
            sink.append(flagBits | UInt8(truncatingIfNeeded: value))
            return
        }
        sink.reserveAdditionalCapacity(encodedLength(value, prefixBits: prefixBits))
        sink.append(flagBits | mask)
        var rest = value - maxPrefix
        while rest >= 0x80 {
            sink.append(UInt8(truncatingIfNeeded: rest) | 0x80)
            rest >>= 7
        }
        sink.append(UInt8(truncatingIfNeeded: rest))
    }

    /// The bits of `firstByte` above an `prefixBits`-bit prefix.
    @inlinable
    public static func flags(of firstByte: UInt8, prefixBits: Int) -> UInt8 {
        firstByte & ~UInt8(truncatingIfNeeded: (1 << prefixBits) - 1)
    }

    /// Decodes an integer whose first byte is `bytes[0]`, ignoring the flag bits above the prefix.
    ///
    /// - Parameters:
    ///   - maxValue: values above this are `.overflow`. Defaults to ``maxQUICValue``, which is
    ///     also the ceiling; HPACK callers should pass ``maxHPACKValue`` or a tighter limit.
    @inlinable
    public static func decode(
        _ bytes: UnsafeRawBufferPointer, prefixBits: Int, maxValue: UInt64 = maxQUICValue
    ) -> DecodeResult {
        precondition((1...8).contains(prefixBits), "prefixBits must be 1...8")
        precondition(maxValue <= maxQUICValue, "maxValue exceeds 2^62 - 1")
        guard let first = bytes.first else { return .needsMoreData }
        let maxPrefix = UInt64(1 << prefixBits) - 1
        var value = UInt64(first) & maxPrefix
        if value < maxPrefix {
            return value <= maxValue ? .value(value, consumed: 1) : .overflow
        }
        var shift: UInt64 = 0
        var index = 1
        while index < bytes.count {
            // Any value ≤ 2^62 − 1 needs at most nine continuation bytes (shifts 0...56);
            // a tenth would only add bits at 63+ or be redundant zero padding.
            if shift > 56 { return .overflow }
            let byte = bytes[index]
            index += 1
            // value < 2^62 and the term < 2^63, so the sum cannot wrap.
            value += UInt64(byte & 0x7F) << shift
            if value > maxValue { return .overflow }
            if byte & 0x80 == 0 { return .value(value, consumed: index) }
            shift += 7
        }
        return .needsMoreData
    }
}
