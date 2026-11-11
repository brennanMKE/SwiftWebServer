import Testing
import HeaderCompression

private func encodeLiteral(
    _ string: String, prefixBits: Int = 7, flags: UInt8 = 0,
    huffman: StringLiteral.HuffmanPolicy = .whenShorter
) -> [UInt8] {
    var out: [UInt8] = []
    Array(string.utf8).withUnsafeBytes {
        StringLiteral.encode($0, prefixBits: prefixBits, flags: flags, huffman: huffman, into: &out)
    }
    return out
}

private enum Decoded: Equatable {
    case string([UInt8], consumed: Int)
    case needsMoreData
    case error(HeaderCompressionError)
}

private func decodeLiteral(_ bytes: [UInt8], prefixBits: Int = 7, maxLength: Int = 4096) -> Decoded {
    var out: [UInt8] = []
    return bytes.withUnsafeBytes { raw in
        do throws(HeaderCompressionError) {
            switch try StringLiteral.decode(raw, prefixBits: prefixBits, maxLength: maxLength, into: &out) {
            case .decoded(let consumed): return .string(out, consumed: consumed)
            case .needsMoreData: return .needsMoreData
            }
        } catch {
            return .error(error)
        }
    }
}

@Suite struct StringLiteralTests {
    let host = Array("www.example.com".utf8)

    // RFC 7541 C.3.1 (raw) and C.4.1 (Huffman) encode the :authority value this way.
    @Test func rfc7541Literals() {
        let raw: [UInt8] = [0x0F] + host
        let coded: [UInt8] = [0x8C, 0xF1, 0xE3, 0xC2, 0xE5, 0xF2, 0x3A, 0x6B, 0xA0, 0xAB, 0x90, 0xF4, 0xFF]
        #expect(encodeLiteral("www.example.com", huffman: .never) == raw)
        #expect(encodeLiteral("www.example.com", huffman: .always) == coded)
        #expect(encodeLiteral("www.example.com") == coded)
        #expect(decodeLiteral(raw) == .string(host, consumed: raw.count))
        #expect(decodeLiteral(coded) == .string(host, consumed: coded.count))
        #expect(host.withUnsafeBytes { StringLiteral.encodedLength($0, prefixBits: 7) } == coded.count)
    }

    @Test func whenShorterKeepsRawIfHuffmanIsNotShorter() {
        // Bytes with long codes grow under Huffman.
        let encoded = encodeLiteral("\u{01}\u{02}")
        #expect(encoded == [0x02, 0x01, 0x02])
        #expect(encodeLiteral("") == [0x00])
        #expect(decodeLiteral([0x00]) == .string([], consumed: 1))
        #expect(decodeLiteral([0x80]) == .string([], consumed: 1))
    }

    @Test func qpackPrefixKeepsFlagsAboveHuffmanBit() {
        // RFC 9204 §4.5.6 literal field line with literal name: 001 N H + 3-bit name length.
        let encoded = encodeLiteral("custom-key", prefixBits: 3, flags: 0b0010_0000)
        #expect(encoded[0] & 0b1111_0000 == 0b0010_0000)
        #expect(encoded[0] & StringLiteral.huffmanFlag(prefixBits: 3) != 0)
        #expect(decodeLiteral(encoded, prefixBits: 3) == .string(Array("custom-key".utf8), consumed: encoded.count))
        // A flag bit that collides with H is ignored rather than forcing Huffman.
        let raw = encodeLiteral("ab", prefixBits: 3, flags: 0xFF, huffman: .never)
        #expect(raw[0] == 0b1111_0010)
        #expect(decodeLiteral(raw, prefixBits: 3) == .string(Array("ab".utf8), consumed: 3))
    }

    @Test func needsMoreDataUntilTheWholeLiteralArrives() {
        let encoded = encodeLiteral("custom-value")
        for cut in 0..<encoded.count {
            #expect(decodeLiteral(Array(encoded[..<cut])) == .needsMoreData)
        }
        #expect(decodeLiteral(encoded + [0x42]) == .string(Array("custom-value".utf8), consumed: encoded.count))
    }

    @Test func limitsAndErrors() {
        #expect(decodeLiteral([0x05, 0x61], maxLength: 4) == .error(.stringTooLong))
        #expect(decodeLiteral([0x7F] + Array(repeating: 0xFF, count: 9) + [0x7F]) == .error(.integerOverflow))
        // Huffman errors pass through: H set, one byte of eight padding ones.
        #expect(decodeLiteral([0x81, 0xFF]) == .error(.paddingTooLong))
        #expect(decodeLiteral([0x81, 0x18]) == .error(.invalidPadding))
        #expect(decodeLiteral([0x84, 0xFF, 0xFF, 0xFF, 0xFF]) == .error(.endOfStringSymbol))
    }
}
