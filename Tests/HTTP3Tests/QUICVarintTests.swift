import Testing
import HTTP3

private func encode(_ value: UInt64) throws(QUICVarintError) -> [UInt8] {
    var out: [UInt8] = []
    try QUICVarint.encode(value, into: &out)
    return out
}

private func decode(_ bytes: [UInt8]) -> QUICVarint.DecodeResult {
    bytes.withUnsafeBytes { QUICVarint.decode($0) }
}

/// Feeds `bytes` to a `VarintParser` in chunks of `chunk` bytes.
private func parseIncrementally(_ bytes: [UInt8], chunk: Int) -> (UInt64, Int)? {
    var parser = VarintParser()
    var offset = 0
    while offset < bytes.count {
        let end = min(offset + chunk, bytes.count)
        let result = bytes[offset..<end].withUnsafeBytes { parser.parse($0) }
        switch result {
        case .value(let value, let consumed): return (value, offset + consumed)
        case .needsMoreData: offset = end
        }
    }
    return nil
}

@Suite struct QUICVarintTests {
    /// RFC 9000 Appendix A.1 sample decodings, including the non-minimal two-byte 37.
    static let rfc9000Samples: [([UInt8], UInt64)] = [
        ([0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c], 151_288_809_941_952_652),
        ([0x9d, 0x7f, 0x3e, 0x7d], 494_878_333),
        ([0x7b, 0xbd], 15_293),
        ([0x25], 37),
        ([0x40, 0x25], 37),
    ]

    @Test(arguments: rfc9000Samples)
    func rfc9000AppendixA1Decodes(bytes: [UInt8], value: UInt64) {
        #expect(decode(bytes) == .value(value, consumed: bytes.count))
        for chunk in 1...bytes.count {
            let result = parseIncrementally(bytes, chunk: chunk)
            #expect(result?.0 == value)
            #expect(result?.1 == bytes.count)
        }
    }

    @Test func rfc9000AppendixA1EncodesMinimally() throws {
        #expect(try encode(151_288_809_941_952_652) == [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
        #expect(try encode(494_878_333) == [0x9d, 0x7f, 0x3e, 0x7d])
        #expect(try encode(15_293) == [0x7b, 0xbd])
        // 37 has a two-byte form in the samples, but the minimal form is one byte.
        #expect(try encode(37) == [0x25])
    }

    @Test func lengthBoundaries() throws {
        let cases: [(UInt64, Int)] = [
            (0, 1), (63, 1), (64, 2), (16_383, 2), (16_384, 4),
            ((1 << 30) - 1, 4), (1 << 30, 8), (QUICVarint.maxValue, 8),
        ]
        for (value, length) in cases {
            #expect(QUICVarint.encodedLength(value) == length)
            let bytes = try encode(value)
            #expect(bytes.count == length)
            #expect(decode(bytes) == .value(value, consumed: length))
        }
    }

    @Test func rejectsValuesOf2To62AndAbove() {
        #expect(QUICVarint.encodedLength(1 << 62) == nil)
        #expect(QUICVarint.encodedLength(.max) == nil)
        #expect(throws: QUICVarintError.valueOutOfRange(1 << 62)) { try encode(1 << 62) }
        #expect(throws: QUICVarintError.valueOutOfRange(.max)) { try encode(.max) }
        var out: [UInt8] = []
        #expect(throws: QUICVarintError.self) { try QUICVarint.encode(1 << 62, into: &out) }
        #expect(out.isEmpty)
    }

    @Test func fixedLengthEncodingAllowsPaddingButNotTruncation() throws {
        var out: [UInt8] = []
        try QUICVarint.encode(37, length: 2, into: &out)
        #expect(out == [0x40, 0x25])
        out.removeAll()
        try QUICVarint.encode(37, length: 8, into: &out)
        #expect(out == [0xc0, 0, 0, 0, 0, 0, 0, 0x25])
        #expect(decode(out) == .value(37, consumed: 8))
        #expect(throws: QUICVarintError.valueOutOfRange(64)) { try QUICVarint.encode(64, length: 1, into: &out) }
    }

    @Test func needsMoreData() {
        #expect(decode([]) == .needsMoreData)
        #expect(decode([0x40]) == .needsMoreData)
        #expect(decode([0x9d, 0x7f, 0x3e]) == .needsMoreData)
        #expect(decode([0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8]) == .needsMoreData)

        var parser = VarintParser()
        #expect([UInt8]().withUnsafeBytes { parser.parse($0) } == .needsMoreData)
        #expect(!parser.isMidValue)
        #expect([UInt8]([0x9d]).withUnsafeBytes { parser.parse($0) } == .needsMoreData)
        #expect(parser.isMidValue)
        #expect([UInt8]().withUnsafeBytes { parser.parse($0) } == .needsMoreData)
        // Trailing bytes after the integer are left for the caller.
        #expect([UInt8]([0x7f, 0x3e, 0x7d, 0xaa]).withUnsafeBytes { parser.parse($0) } == .value(494_878_333, consumed: 3))
        #expect(!parser.isMidValue)
    }

    @Test func seededRoundTripsByteAtATime() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<500 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = (state >> 2) >> (state % 62)
            let bytes = try encode(value)
            #expect(decode(bytes) == .value(value, consumed: bytes.count))
            #expect(parseIncrementally(bytes, chunk: 1)?.0 == value)
        }
    }
}
