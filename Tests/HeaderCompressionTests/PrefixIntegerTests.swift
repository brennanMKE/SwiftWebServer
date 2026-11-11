import Testing
import HeaderCompression

private func encode(_ value: UInt64, prefixBits: Int, flags: UInt8 = 0) -> [UInt8] {
    var out: [UInt8] = []
    PrefixInteger.encode(value, prefixBits: prefixBits, flags: flags, into: &out)
    return out
}

private func decode(
    _ bytes: [UInt8], prefixBits: Int, maxValue: UInt64 = PrefixInteger.maxQUICValue
) -> PrefixInteger.DecodeResult {
    bytes.withUnsafeBytes { PrefixInteger.decode($0, prefixBits: prefixBits, maxValue: maxValue) }
}

@Suite struct PrefixIntegerTests {
    // RFC 7541 Appendix C.1.1: 10 with a 5-bit prefix.
    @Test func rfc7541C11() {
        #expect(encode(10, prefixBits: 5) == [0x0A])
        #expect(decode([0x0A], prefixBits: 5) == .value(10, consumed: 1))
    }

    // RFC 7541 Appendix C.1.2: 1337 with a 5-bit prefix.
    @Test func rfc7541C12() {
        #expect(encode(1337, prefixBits: 5) == [0x1F, 0x9A, 0x0A])
        #expect(decode([0x1F, 0x9A, 0x0A], prefixBits: 5) == .value(1337, consumed: 3))
    }

    // RFC 7541 Appendix C.1.3: 42 starting at an octet boundary (8-bit prefix).
    @Test func rfc7541C13() {
        #expect(encode(42, prefixBits: 8) == [0x2A])
        #expect(decode([0x2A], prefixBits: 8) == .value(42, consumed: 1))
    }

    @Test func flagBitsArePreservedAndIgnored() {
        // HPACK literal with incremental indexing: '01' flags, 6-bit prefix.
        let bytes = encode(1337, prefixBits: 6, flags: 0b0100_0000)
        #expect(bytes[0] == 0b0111_1111)
        #expect(PrefixInteger.flags(of: bytes[0], prefixBits: 6) == 0b0100_0000)
        #expect(decode(bytes, prefixBits: 6) == .value(1337, consumed: bytes.count))
        // Flag bits that overlap the prefix are dropped rather than corrupting the value.
        #expect(encode(3, prefixBits: 4, flags: 0xFF) == [0xF3])
        #expect(decode([0xF3], prefixBits: 4) == .value(3, consumed: 1))
        // A 1-bit prefix leaves seven flag bits.
        #expect(encode(0, prefixBits: 1, flags: 0xFE) == [0xFE])
        #expect(decode([0xFE], prefixBits: 1) == .value(0, consumed: 1))
    }

    @Test(arguments: 1...8)
    func roundTripAcrossBoundaries(prefixBits: Int) {
        let maxPrefix = UInt64(1 << prefixBits) - 1
        var values: [UInt64] = [0, 1, maxPrefix - 1, maxPrefix, maxPrefix + 1, maxPrefix + 127,
                                maxPrefix + 128, 1337, 65_535, UInt64(UInt32.max),
                                PrefixInteger.maxQUICValue - 1, PrefixInteger.maxQUICValue]
        for shift in stride(from: 7, through: 61, by: 7) {
            values.append(maxPrefix + (1 << UInt64(shift)) - 1)
            values.append(maxPrefix + (1 << UInt64(shift)))
        }
        let flags = UInt8(truncatingIfNeeded: 0xFF << prefixBits)
        for value in values where value <= PrefixInteger.maxQUICValue {
            let bytes = encode(value, prefixBits: prefixBits, flags: flags)
            #expect(bytes.count == PrefixInteger.encodedLength(value, prefixBits: prefixBits))
            #expect(PrefixInteger.flags(of: bytes[0], prefixBits: prefixBits) == flags)
            #expect(decode(bytes, prefixBits: prefixBits) == .value(value, consumed: bytes.count))
            // Trailing bytes are not consumed.
            #expect(decode(bytes + [0xAA], prefixBits: prefixBits) == .value(value, consumed: bytes.count))
            // Every strict prefix of the encoding needs more data.
            for cut in 0..<bytes.count {
                #expect(decode(Array(bytes[..<cut]), prefixBits: prefixBits) == .needsMoreData)
            }
        }
    }

    @Test func needsMoreData() {
        #expect(decode([], prefixBits: 5) == .needsMoreData)
        #expect(decode([0x1F], prefixBits: 5) == .needsMoreData)
        #expect(decode([0x1F, 0x9A], prefixBits: 5) == .needsMoreData)
        #expect(decode([0xFF, 0x80, 0x80], prefixBits: 8) == .needsMoreData)
    }

    @Test func rejectsValuesAboveQUICBound() {
        // 2^62 with an 8-bit prefix: 255 + continuation of 2^62 − 255.
        let rest = (UInt64(1) << 62) - 255
        var bytes: [UInt8] = [0xFF]
        var r = rest
        while r >= 0x80 { bytes.append(UInt8(truncatingIfNeeded: r) | 0x80); r >>= 7 }
        bytes.append(UInt8(r))
        #expect(decode(bytes, prefixBits: 8) == .overflow)
        // One less is the maximum and decodes.
        let max = encode(PrefixInteger.maxQUICValue, prefixBits: 8)
        #expect(decode(max, prefixBits: 8) == .value(PrefixInteger.maxQUICValue, consumed: max.count))
        // Ten continuation bytes all set to 0x7F would need 70 bits.
        #expect(decode([0x1F] + Array(repeating: 0xFF, count: 9) + [0x7F], prefixBits: 5) == .overflow)
        // Overflow is reported as soon as it is known, even with input still missing.
        #expect(decode([0x1F] + Array(repeating: 0xFF, count: 9), prefixBits: 5) == .overflow)
    }

    @Test func rejectsOverlongZeroPadding() {
        // 31 encoded with redundant 0x80 continuation bytes beyond any valid length.
        let bytes: [UInt8] = [0x1F] + Array(repeating: 0x80, count: 9) + [0x00]
        #expect(decode(bytes, prefixBits: 5) == .overflow)
        // Fewer redundant bytes are tolerated (RFC 7541 §5.1 permits but does not require rejection).
        #expect(decode([0x1F, 0x80, 0x00], prefixBits: 5) == .value(31, consumed: 3))
    }

    @Test func hpackBound() {
        let atBound = encode(PrefixInteger.maxHPACKValue, prefixBits: 7)
        #expect(decode(atBound, prefixBits: 7, maxValue: PrefixInteger.maxHPACKValue)
            == .value(PrefixInteger.maxHPACKValue, consumed: atBound.count))
        let over = encode(PrefixInteger.maxHPACKValue + 1, prefixBits: 7)
        #expect(decode(over, prefixBits: 7, maxValue: PrefixInteger.maxHPACKValue) == .overflow)
        // A tight caller-chosen bound, including one below the prefix maximum.
        #expect(decode(encode(4097, prefixBits: 5), prefixBits: 5, maxValue: 4096) == .overflow)
        #expect(decode(encode(20, prefixBits: 5), prefixBits: 5, maxValue: 16) == .overflow)
        #expect(decode(encode(16, prefixBits: 5), prefixBits: 5, maxValue: 16) == .value(16, consumed: 1))
    }
}
