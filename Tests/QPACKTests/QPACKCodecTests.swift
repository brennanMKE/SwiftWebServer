import HeaderCompression
import Testing
import QPACK

@Suite struct QPACKCodecTests {
    // RFC 9204 Appendix B.1: Literal Field Line with Name Reference (static index 1), raw value.
    static let appendixB1 = hex("0000 510b 2f69 6e64 6578 2e68 746d 6c")

    @Test func appendixB1EncodesByteForByte() {
        #expect(encode([Field(":path", "/index.html")], huffman: .never) == Self.appendixB1)
    }

    @Test func appendixB1Decodes() {
        #expect(decode(Self.appendixB1) == .fields([Field(":path", "/index.html")], size: 5 + 11 + 32))
    }

    @Test func prefixIsRequiredInsertCountZeroBaseZero() {
        #expect(encode([]) == [0x00, 0x00])
        #expect(decode([0x00, 0x00]) == .fields([], size: 0))
        // Delta Base is ignored when S = 0 and nothing references the dynamic table.
        #expect(decode([0x00, 0x7F, 0x80, 0x01]) == .fields([], size: 0))
    }

    @Test func exactStaticMatchesUseIndexedFieldLines() {
        #expect(encode([Field(":method", "GET")]) == [0x00, 0x00, 0xD1])
        #expect(encode([Field(":status", "200")]) == [0x00, 0x00, 0xD9])
        // Index 98 needs a continuation byte: 63 + 35.
        #expect(encode([Field("x-frame-options", "sameorigin")]) == [0x00, 0x00, 0xFF, 0x23])
        #expect(decodedFields([0x00, 0x00, 0xFF, 0x23]) == [Field("x-frame-options", "sameorigin")])
    }

    @Test func staticNameReferenceWithHuffmanValue() {
        let bytes = encode([Field(":path", "/index.html")])
        // H set, 8 Huffman bytes instead of 11 raw ones.
        #expect(Array(bytes.prefix(4)) == [0x00, 0x00, 0x51, 0x88])
        #expect(bytes.count == 4 + 8)
        #expect(decodedFields(bytes) == [Field(":path", "/index.html")])
    }

    @Test func literalNameRepresentation() {
        let name = Array("x-custom".utf8)
        let raw = encode([Field("x-custom", "v")], huffman: .never)
        // 001 N=0 H=0 length 8 = 7 + 1.
        #expect(raw == [0x00, 0x00, 0x27, 0x01] + name + [0x01, 0x76])
        #expect(decodedFields(raw) == [Field("x-custom", "v")])

        let huffman = encode([Field("x-custom", "v")])
        #expect(huffman[2] & 0xF8 == 0x28, "H bit set on the 6-byte Huffman name")
        #expect(decodedFields(huffman) == [Field("x-custom", "v")])
    }

    @Test func sensitiveHeadersAreNeverIndexed() {
        // authorization: 0 1 N=1 T=1 index 84 = 15 + 69.
        #expect(encode([Field("authorization", "x")]) == [0x00, 0x00, 0x7F, 0x45, 0x01, 0x78])
        #expect(encode([Field("cookie", "a=b")]) == [0x00, 0x00, 0x75, 0x03, 0x61, 0x3D, 0x62])
        #expect(encode([Field("set-cookie", "a=b")]).prefix(3) == [0x00, 0x00, 0x7E])
        // Even an exact static match (empty value) stays a never-indexed literal.
        #expect(encode([Field("cookie", "")]) == [0x00, 0x00, 0x75, 0x00])

        let fields = [Field("authorization", "Basic Zm9vOmJhcg=="), Field("cookie", "a=b"), Field("set-cookie", "c=d")]
        #expect(decodedFields(encode(fields)) == fields.map { Field(name: $0.name, value: $0.value, neverIndexed: true) })
        #expect(QPACKEncoder.isSensitive(name: UnsafeRawBufferPointer(start: nil, count: 0)) == false)
        #expect(Array("cookie".utf8).withUnsafeBytes { QPACKEncoder.isSensitive(name: $0) })
        #expect(!Array("cookies".utf8).withUnsafeBytes { QPACKEncoder.isSensitive(name: $0) })
    }

    @Test func callerCanForceNeverIndexed() {
        let fields = [Field(":method", "GET", neverIndexed: true), Field("x-secret", "s", neverIndexed: true)]
        let bytes = encode(fields)
        // :method GET becomes a name reference literal with N (0x40|0x20|0x10|15, then 2).
        #expect(Array(bytes[2...4]) == [0x7F, 0x02, 0x03])
        #expect(decodedFields(bytes) == fields)
    }

    @Test(arguments: [StringLiteral.HuffmanPolicy.whenShorter, .always, .never])
    func browserRequestsRoundTrip(huffman: StringLiteral.HuffmanPolicy) {
        for fields in browserRequests {
            let bytes = encode(fields, huffman: huffman)
            guard case .fields(let decoded, let size) = decode(bytes) else {
                Issue.record("decode failed for \(fields)")
                continue
            }
            #expect(stripN(decoded) == fields)
            #expect(size == sectionSize(fields))
            for (field, out) in zip(fields, decoded) {
                let sensitive = field.name.withUnsafeBytes { QPACKEncoder.isSensitive(name: $0) }
                #expect(out.neverIndexed == sensitive, "\(field)")
            }
        }
    }

    @Test(arguments: [StringLiteral.HuffmanPolicy.whenShorter, .always, .never])
    func responsesRoundTrip(huffman: StringLiteral.HuffmanPolicy) {
        for fields in typicalResponses {
            #expect(decodedFields(encode(fields, huffman: huffman)).map(stripN) == fields)
        }
    }

    @Test func huffmanPolicyShrinksTypicalRequests() {
        for fields in browserRequests {
            let raw = encode(fields, huffman: .never).count
            let shorter = encode(fields, huffman: .whenShorter).count
            #expect(shorter < raw)
            #expect(shorter <= encode(fields, huffman: .always).count)
        }
    }

    @Test func decoderIsReusableAcrossSections() {
        var decoder = QPACKDecoder()
        for fields in browserRequests + typicalResponses {
            let bytes = encode(fields, huffman: .always)
            var sink = CollectingSink()
            let size = try? bytes.withUnsafeBytes { raw in try decoder.decode(raw, into: &sink) }
            #expect(size == sectionSize(fields))
            #expect(stripN(sink.fields) == fields)
        }
    }

    @Test func encodeConvenienceMatchesFieldByField() {
        let fields = browserRequests[0]
        var out: [UInt8] = []
        QPACKEncoder().encode(fields.map { (name: $0.name, value: $0.value) }, into: &out)
        #expect(out == encode(fields))
    }

    @Test func fieldSectionSizeIsEnforcedIncrementally() {
        let getBytes = encode([Field(":method", "GET")])
        #expect(decode(getBytes, maxFieldSectionSize: 42) == .fields([Field(":method", "GET")], size: 42))
        #expect(decodeError(getBytes, maxFieldSectionSize: 41) == QPACKError(.decompressionFailed, .fieldSectionTooLarge))

        // Delivered fields before the limit are kept; the third field crosses it.
        let fields = [Field(":method", "GET"), Field(":path", "/"), Field("x-a", "b")]
        let bytes = encode(fields)
        var decoder = QPACKDecoder(maxFieldSectionSize: 42 + 38 + 10)
        var sink = CollectingSink()
        #expect(throws: QPACKError(.decompressionFailed, .fieldSectionTooLarge)) {
            try bytes.withUnsafeBytes { raw in try decoder.decode(raw, into: &sink) }
        }
        #expect(sink.fields == Array(fields.prefix(2)))

        // A declared string length beyond the budget fails before waiting for its bytes.
        #expect(
            decodeError([0x00, 0x00, 0x51, 0x7F, 0xE9, 0x06], maxFieldSectionSize: 100)
                == QPACKError(.decompressionFailed, .fieldSectionTooLarge))
        // Huffman strings are bounded by their decoded size.
        let huffman = encode([Field("x-long", String(repeating: "a", count: 200))], huffman: .always)
        #expect(decodeError(huffman, maxFieldSectionSize: 200) == QPACKError(.decompressionFailed, .fieldSectionTooLarge))
        #expect(decodedFields(huffman, maxFieldSectionSize: 238) != nil)
    }
}

@Suite struct QPACKDecoderRejectionTests {
    private func expect(_ bytes: [UInt8], _ reason: QPACKError.Reason, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(decodeError(bytes) == QPACKError(.decompressionFailed, reason), sourceLocation: sourceLocation)
    }

    @Test func nonZeroRequiredInsertCount() {
        // RFC 9204 Appendix B.2, stream 4: Required Insert Count = 2.
        expect(hex("0381 10 11"), .requiredInsertCountNotZero)
        expect([0x01, 0x00], .requiredInsertCountNotZero)
        #expect(QPACKError.Code.decompressionFailed.rawValue == 0x0200)
    }

    @Test func negativeBase() {
        expect([0x00, 0x80], .negativeBase)
        expect([0x00, 0xFF, 0x01], .negativeBase)
    }

    @Test func dynamicTableReferences() {
        expect([0x00, 0x00, 0x80], .dynamicTableReference)  // Indexed, T = 0
        expect([0x00, 0x00, 0xBF, 0x05], .dynamicTableReference)
        expect([0x00, 0x00, 0x10], .dynamicTableReference)  // Indexed with Post-Base Index
        expect([0x00, 0x00, 0x40, 0x01, 0x61], .dynamicTableReference)  // Name reference, T = 0
        expect([0x00, 0x00, 0x60, 0x01, 0x61], .dynamicTableReference)  // ... with N
        expect([0x00, 0x00, 0x00, 0x01, 0x61], .dynamicTableReference)  // Post-Base Name Reference
        expect([0x00, 0x00, 0x08, 0x01, 0x61], .dynamicTableReference)
        // Fields before the bad line are delivered, then the section fails.
        expect([0x00, 0x00, 0xD1, 0x80], .dynamicTableReference)
    }

    @Test func staticIndexOutOfRange() {
        expect([0x00, 0x00, 0xFF, 0x24], .staticIndexOutOfRange)  // 63 + 36 = 99
        expect([0x00, 0x00, 0x5F, 0x54, 0x00], .staticIndexOutOfRange)  // 15 + 84 = 99
        expect([0x00, 0x00, 0xFF, 0xFF, 0x7F], .staticIndexOutOfRange)
        #expect(decodedFields([0x00, 0x00, 0x5F, 0x53, 0x00]) == [Field("x-frame-options", "")])
    }

    @Test func truncation() {
        expect([], .truncated)
        expect([0x00], .truncated)
        expect([0xFF], .truncated)  // Required Insert Count continues
        expect([0x00, 0x7F], .truncated)  // Delta Base continues
        expect([0x00, 0x00, 0xFF], .truncated)  // static index continues
        expect([0x00, 0x00, 0x51], .truncated)  // value missing
        expect([0x00, 0x00, 0x51, 0x0B, 0x2F], .truncated)  // value short
        expect([0x00, 0x00, 0x51, 0x7F], .truncated)  // value length continues
        expect([0x00, 0x00, 0x21, 0x61], .truncated)  // literal name, value missing
        expect([0x00, 0x00, 0x23, 0x61], .truncated)  // literal name short
    }

    @Test func integerOverflow() {
        let tooLong = [UInt8](repeating: 0xFF, count: 10) + [0x01]
        expect([0xFF] + tooLong, .integerOverflow)
        expect([0x00, 0x7F] + tooLong, .integerOverflow)
        expect([0x00, 0x00, 0xFF] + tooLong, .integerOverflow)
        expect([0x00, 0x00, 0x51, 0x7F] + tooLong, .integerOverflow)
    }

    @Test func invalidHuffman() {
        // Four bytes of ones contain the 30-bit EOS code.
        expect([0x00, 0x00, 0x51, 0x84, 0xFF, 0xFF, 0xFF, 0xFF], .huffman(.endOfStringSymbol))
        // '0' is 00000; the three padding bits must be ones.
        expect([0x00, 0x00, 0x51, 0x81, 0x00], .huffman(.invalidPadding))
        // Huffman literal name.
        expect([0x00, 0x00, 0x29, 0x00, 0x00], .huffman(.invalidPadding))
    }
}
