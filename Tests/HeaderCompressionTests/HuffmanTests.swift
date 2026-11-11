import Testing
@testable import HeaderCompression

private func huffmanEncode(_ input: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    input.withUnsafeBytes { Huffman.encode($0, into: &out) }
    return out
}

private func huffmanDecode(_ input: [UInt8]) throws(HeaderCompressionError) -> [UInt8] {
    var out: [UInt8] = []
    let result: HeaderCompressionError? = input.withUnsafeBytes { raw in
        do throws(HeaderCompressionError) {
            try Huffman.decode(raw, into: &out)
            return nil
        } catch {
            return error
        }
    }
    if let result { throw result }
    return out
}

private func decodeError(_ input: [UInt8]) -> HeaderCompressionError? {
    do {
        _ = try huffmanDecode(input)
        return nil
    } catch {
        return error
    }
}

private func hex(_ string: String) -> [UInt8] {
    let digits = Array(string.utf8).filter { $0 != UInt8(ascii: " ") }
    func nibble(_ c: UInt8) -> UInt8 { c <= UInt8(ascii: "9") ? c - UInt8(ascii: "0") : c - UInt8(ascii: "a") + 10 }
    return stride(from: 0, to: digits.count, by: 2).map { nibble(digits[$0]) << 4 | nibble(digits[$0 + 1]) }
}

/// SplitMix64: a small seeded generator so random cases are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct HuffmanTests {
    /// Huffman-coded strings from RFC 7541 Appendix C.4 (requests) and C.6 (responses).
    static let rfcVectors: [(String, String)] = [
        // C.4
        ("www.example.com", "f1e3 c2e5 f23a 6ba0 ab90 f4ff"),
        ("no-cache", "a8eb 1064 9cbf"),
        ("custom-key", "25a8 49e9 5ba9 7d7f"),
        ("custom-value", "25a8 49e9 5bb8 e8b4 bf"),
        // C.6
        ("302", "6402"),
        ("private", "aec3 771a 4b"),
        ("Mon, 21 Oct 2013 20:13:21 GMT", "d07a be94 1054 d444 a820 0595 040b 8166 e082 a62d 1bff"),
        ("https://www.example.com", "9d29 ad17 1863 c78f 0b97 c8e9 ae82 ae43 d3"),
        ("307", "640e ff"),
        ("Mon, 21 Oct 2013 20:13:22 GMT", "d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff"),
        ("gzip", "9bd9 ab"),
        ("foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
         "94e7 821d d7f2 e6c7 b335 dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f 9587 3160 65c0 03ed 4ee5 b106 3d50 07"),
    ]

    @Test(arguments: rfcVectors)
    func rfc7541AppendixC(plain: String, encoded: String) throws {
        let input = Array(plain.utf8)
        let expected = hex(encoded)
        #expect(huffmanEncode(input) == expected)
        #expect(input.withUnsafeBytes { Huffman.encodedLength($0) } == expected.count)
        #expect(try huffmanDecode(expected) == input)
    }

    @Test func codeTableIsTheCanonicalRFC7541Code() {
        #expect(huffmanCodes.count == 257 && huffmanCodeLengths.count == 257)
        let order = (0...256).sorted { (huffmanCodeLengths[$0], $0) < (huffmanCodeLengths[$1], $1) }
        var code: UInt32 = 0
        var previous = huffmanCodeLengths[order[0]]
        for (i, symbol) in order.enumerated() {
            if i > 0 {
                code = (code + 1) << UInt32(huffmanCodeLengths[symbol] - previous)
                previous = huffmanCodeLengths[symbol]
            }
            #expect(huffmanCodes[symbol] == code, "symbol \(symbol)")
        }
        #expect(huffmanCodes[256] == 0x3FFF_FFFF && huffmanCodeLengths[256] == 30)
        #expect(huffmanDecodeTable.count == 256 * 16)
    }

    @Test func emptyString() throws {
        #expect(huffmanEncode([]) == [])
        #expect(try huffmanDecode([]) == [])
    }

    @Test func everySingleByteRoundTrips() throws {
        for value in 0...255 {
            let input = [UInt8(value)]
            let encoded = huffmanEncode(input)
            let bits = Int(huffmanCodeLengths[value])
            #expect(encoded.count == (bits + 7) / 8, "byte \(value)")
            #expect(try huffmanDecode(encoded) == input, "byte \(value)")
        }
        let all = (0...255).map { UInt8($0) }
        #expect(try huffmanDecode(huffmanEncode(all)) == all)
    }

    @Test func seededRandomStringsRoundTrip() throws {
        var generator = SeededGenerator(state: 0x5357_5348_5546_4600)
        for round in 0..<2_000 {
            let length = Int.random(in: 0...200, using: &generator)
            // Alternate between arbitrary bytes and header-like printable ASCII.
            let input: [UInt8] = (0..<length).map { _ in
                round.isMultiple(of: 2)
                    ? UInt8.random(in: 0...255, using: &generator)
                    : UInt8.random(in: 0x20...0x7E, using: &generator)
            }
            let encoded = huffmanEncode(input)
            #expect(encoded.count == input.withUnsafeBytes { Huffman.encodedLength($0) })
            #expect(try huffmanDecode(encoded) == input, "round \(round)")
        }
    }

    @Test func decodeAppendsToExistingContents() throws {
        var out: [UInt8] = [0x41]
        let encoded = huffmanEncode(Array("gzip".utf8))
        let failed = encoded.withUnsafeBytes { raw in
            (try? Huffman.decode(raw, into: &out)) == nil
        }
        #expect(!failed)
        #expect(out == Array("Agzip".utf8))
    }

    // MARK: - Valid padding

    @Test func acceptsPaddingOfOneToSevenOnes() throws {
        // '0' (00000) then three ones.
        #expect(try huffmanDecode([0x07]) == Array("0".utf8))
        // '0' '0' then six ones: 00000000 00111111.
        #expect(try huffmanDecode([0x00, 0x3F]) == Array("00".utf8))
        // Every padding length 1...7 occurs for some pair of symbols; each must decode.
        var seen = Set<Int>()
        for a in 0...255 {
            for b in 0...255 {
                let bits = Int(huffmanCodeLengths[a]) + Int(huffmanCodeLengths[b])
                let padding = (8 - bits % 8) % 8
                guard padding > 0, seen.insert(padding).inserted else { continue }
                let input = [UInt8(a), UInt8(b)]
                let encoded = huffmanEncode(input)
                let mask = UInt8((1 << padding) - 1)
                #expect(encoded.last.map { $0 & mask } == mask)
                #expect(try huffmanDecode(encoded) == input, "padding \(padding)")
            }
        }
        #expect(seen == Set(1...7))
    }

    // MARK: - Invalid input (RFC 7541 §5.2)

    @Test func rejectsEOSSymbol() {
        // EOS alone: 30 ones, then 2 bits of padding.
        #expect(decodeError([0xFF, 0xFF, 0xFF, 0xFF]) == .endOfStringSymbol)
        // 'a' (00011) then 35 ones: EOS completes after the first 30.
        #expect(decodeError([0x1F, 0xFF, 0xFF, 0xFF, 0xFF]) == .endOfStringSymbol)
        // EOS followed by a valid symbol.
        #expect(decodeError([0xFF, 0xFF, 0xFF, 0xFC] + huffmanEncode(Array("a".utf8))) == .endOfStringSymbol)
        // A valid string, then EOS in the middle of the input.
        #expect(decodeError(huffmanEncode(Array("gzip".utf8)) + [0xFF, 0xFF, 0xFF, 0xFC, 0x1F])
            == .endOfStringSymbol)
    }

    @Test func rejectsPaddingLongerThanSevenBits() {
        // Eight ones and nothing else.
        #expect(decodeError([0xFF]) == .paddingTooLong)
        // '0' (00000) then 11 ones.
        #expect(decodeError([0x07, 0xFF]) == .paddingTooLong)
        // A valid string followed by a whole byte of padding.
        #expect(decodeError(huffmanEncode(Array("gzip".utf8)) + [0xFF]) == .paddingTooLong)
        // 24 ones: a long EOS prefix that stops short of EOS.
        #expect(decodeError([0xFF, 0xFF, 0xFF]) == .paddingTooLong)
    }

    @Test func rejectsPaddingThatIsNotAllOnes() {
        // 'a' (00011) padded with 000, 101 and 110.
        #expect(decodeError([0x18]) == .invalidPadding)
        #expect(decodeError([0x1D]) == .invalidPadding)
        #expect(decodeError([0x1E]) == .invalidPadding)
        // '0' (00000) padded with 011.
        #expect(decodeError([0x03]) == .invalidPadding)
        // '\0' (13 bits: 1111111111000) then 000.
        #expect(decodeError([0xFF, 0xC0]) == .invalidPadding)
        // A valid string, then '0' (00000) padded with 000.
        #expect(decodeError(huffmanEncode(Array("gzip".utf8)) + [0x00]) == .invalidPadding)
    }
}
