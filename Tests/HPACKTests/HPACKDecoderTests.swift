import HTTPCore
import Testing
@testable import HPACK

/// Collects decoded fields as strings.
struct CollectingSink: HPACKFieldSink {
    var fields: [Field] = []
    var representations: [HPACKRepresentation] = []

    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
        fields.append(Field(string(name), string(value)))
        representations.append(representation)
    }
}

/// Decodes `bytes`; returns the sink, or the error.
func decode(_ decoder: inout HPACKDecoder, _ bytes: [UInt8]) -> Result<CollectingSink, HPACKError> {
    var sink = CollectingSink()
    do throws(HPACKError) {
        try bytes.withUnsafeBufferPointer { (buffer) throws(HPACKError) in
            try decoder.decode(buffer.span, into: &sink)
        }
        return .success(sink)
    } catch {
        return .failure(error)
    }
}

func decodeError(_ decoder: inout HPACKDecoder, _ bytes: [UInt8]) -> HPACKError? {
    if case .failure(let error) = decode(&decoder, bytes) { return error }
    return nil
}

@Suite struct HPACKDecoderTests {
    // MARK: RFC 7541 Appendix C

    @Test(arguments: RFC7541Vectors.representations.map(\.name))
    func appendixC2(name: String) throws {
        let step = RFC7541Vectors.representations.first { $0.name == name }!
        var decoder = HPACKDecoder()
        let sink = try decode(&decoder, step.encoded).get()
        #expect(sink.fields == step.fields)
        #expect(decoder.dynamicTable.fields == step.table)
        #expect(decoder.dynamicTable.size == step.tableSize)
    }

    @Test func appendixC2NeverIndexedFlagIsSurfaced() throws {
        var decoder = HPACKDecoder()
        #expect(try decode(&decoder, RFC7541Vectors.c21.encoded).get().representations == [.incrementalIndexing])
        #expect(try decode(&decoder, RFC7541Vectors.c22.encoded).get().representations == [.withoutIndexing])
        #expect(try decode(&decoder, RFC7541Vectors.c23.encoded).get().representations == [.neverIndexed])
        #expect(try decode(&decoder, RFC7541Vectors.c24.encoded).get().representations == [.indexed])
    }

    @Test(arguments: RFC7541Vectors.sequences.map(\.name))
    func appendixCSequence(name: String) throws {
        let sequence = RFC7541Vectors.sequences.first { $0.name == name }!
        var decoder = HPACKDecoder(maxTableSize: sequence.tableSize)
        for step in sequence.steps {
            let sink = try decode(&decoder, step.encoded).get()
            #expect(sink.fields == step.fields, "\(step.name)")
            #expect(decoder.dynamicTable.fields == step.table, "\(step.name)")
            #expect(decoder.dynamicTable.size == step.tableSize, "\(step.name)")
        }
    }

    @Test func decodesFromByteBufferView() throws {
        var buffer = ByteBuffer()
        buffer.append(contentsOf: [0xFF, 0xFF] + RFC7541Vectors.c3.steps[0].encoded)
        let view = ByteView(offset: 2, length: buffer.readableBytes - 2)
        var decoder = HPACKDecoder()
        var sink = CollectingSink()
        try decoder.decode(view, in: buffer, into: &sink)
        #expect(sink.fields == RFC7541Vectors.request1)
    }

    // MARK: Table size updates

    @Test func sizeUpdatesAtStartOfBlock() throws {
        var decoder = HPACKDecoder()
        _ = try decode(&decoder, RFC7541Vectors.c21.encoded).get()
        // Two updates (0 then 100) at the start, then an indexed field.
        let sink = try decode(&decoder, [0x20, 0x3F, 0x45, 0x82]).get()
        #expect(sink.fields == [Field(":method", "GET")])
        #expect(decoder.dynamicTable.isEmpty)
        #expect(decoder.dynamicTable.maxSize == 100)
    }

    @Test func sizeUpdateAfterAFieldIsRejected() {
        var decoder = HPACKDecoder()
        #expect(decodeError(&decoder, [0x82, 0x20]) == .tableSizeUpdateNotAtStart)
        #expect(decoder.isUnusable)
    }

    @Test func sizeUpdateAboveAdvertisedLimitIsRejected() {
        var decoder = HPACKDecoder(maxTableSize: 256)
        // 0x3F 0xE2 0x01 = 31 + 0x62 + 128 = 257.
        #expect(decodeError(&decoder, [0x3F, 0xE2, 0x01]) == .tableSizeUpdateTooLarge(requested: 257, limit: 256))
        var exact = HPACKDecoder(maxTableSize: 256)
        #expect(decodeError(&exact, [0x3F, 0xE1, 0x01]) == nil)
        #expect(exact.dynamicTable.maxSize == 256)
    }

    @Test func loweredLimitRequiresSizeUpdate() throws {
        var decoder = HPACKDecoder(maxTableSize: 4096)
        decoder.setMaxTableSizeLimit(100)
        #expect(decodeError(&decoder, [0x82]) == .missingTableSizeUpdate)

        var other = HPACKDecoder(maxTableSize: 4096)
        other.setMaxTableSizeLimit(100)
        #expect(decodeError(&other, [0x3F, 0xE2, 0x00]) == .tableSizeUpdateTooLarge(requested: 129, limit: 100))

        var good = HPACKDecoder(maxTableSize: 4096)
        good.setMaxTableSizeLimit(100)
        _ = try decode(&good, []).get()  // an empty block does not satisfy it
        #expect(try decode(&good, [0x3F, 0x45, 0x82]).get().fields == [Field(":method", "GET")])
        #expect(try decode(&good, [0x82]).get().fields == [Field(":method", "GET")])
    }

    // MARK: Errors

    @Test func invalidIndexes() {
        var zero = HPACKDecoder()
        #expect(decodeError(&zero, [0x80]) == .invalidIndex(0))
        var past = HPACKDecoder()
        #expect(decodeError(&past, [0xBE]) == .invalidIndex(62))
        var name = HPACKDecoder()
        #expect(decodeError(&name, [0x7F, 0x00, 0x01, 0x61]) == .invalidIndex(63))
    }

    @Test func truncatedBlocks() {
        let full = RFC7541Vectors.c21.encoded
        for length in 1..<full.count {
            var decoder = HPACKDecoder()
            #expect(decodeError(&decoder, Array(full[..<length])) == .truncatedBlock, "length \(length)")
        }
        var integer = HPACKDecoder()
        #expect(decodeError(&integer, [0xFF, 0x80]) == .truncatedBlock)
    }

    @Test func integerOverflow() {
        var decoder = HPACKDecoder()
        #expect(decodeError(&decoder, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) == .integerOverflow)
    }

    @Test func stringTooLong() {
        var decoder = HPACKDecoder(maxStringLength: 4)
        #expect(decodeError(&decoder, [0x40, 0x05] + Array("abcde".utf8) + [0x00]) == .stringTooLong)
    }

    @Test func invalidHuffman() {
        // Huffman value with padding of a zero bit (0x00 is not an EOS prefix).
        var padding = HPACKDecoder()
        #expect(decodeError(&padding, [0x04, 0x81, 0x00]) == .invalidHuffman(.invalidPadding))
        // EOS (30 ones) in the string.
        var eos = HPACKDecoder()
        #expect(decodeError(&eos, [0x04, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]) == .invalidHuffman(.endOfStringSymbol))
    }

    @Test func decoderIsUnusableAfterAnError() {
        var decoder = HPACKDecoder()
        #expect(decodeError(&decoder, [0x80]) == .invalidIndex(0))
        #expect(decodeError(&decoder, [0x82]) == .decoderUnusable)
        #expect(HPACKError.decoderUnusable.http2ErrorCode == 0x9)
    }

    // MARK: Header list size

    @Test func headerListSizeIsEnforcedPerField() throws {
        var decoder = HPACKDecoder(maxHeaderListSize: 42 + 32)
        // :method GET is 7 + 3 + 32 = 42; two of them exceed 74.
        _ = try decode(&decoder, [0x82]).get()
        #expect(decodeError(&decoder, [0x82, 0x82]) == .headerListTooLarge(limit: 74))
    }

    /// An HPACK bomb: one large dynamic entry, then many one-byte references to it. The decoder
    /// must stop at the first field over the limit instead of expanding all of them.
    @Test func hpackBombStopsAtTheLimit() throws {
        var decoder = HPACKDecoder(maxTableSize: 4096, maxHeaderListSize: 16_384)
        let value = [UInt8](repeating: 0x61, count: 4000)
        var insert: [UInt8] = [0x40, 0x01, 0x78, 0x7F]  // literal name "x", value length 4000
        insert += [0xA1, 0x1E]  // 127 + 0x21 + 0x1E·128 = 4000
        insert += value
        let bomb = insert + [UInt8](repeating: 0xBE, count: 10_000)
        let error = decodeError(&decoder, bomb)
        #expect(error == .headerListTooLarge(limit: 16_384))
    }

    // MARK: Incremental indexing edge cases

    @Test func literalLargerThanTableEmptiesIt() throws {
        var decoder = HPACKDecoder(maxTableSize: 64)
        _ = try decode(&decoder, [0x40, 0x01, 0x61, 0x01, 0x62]).get()
        #expect(decoder.dynamicTable.count == 1)
        let big = [UInt8](repeating: 0x76, count: 40)
        let sink = try decode(&decoder, [0x40, 0x01, 0x63, 0x28] + big).get()
        #expect(sink.fields == [Field("c", String(repeating: "v", count: 40))])
        #expect(sink.representations == [.incrementalIndexing])
        #expect(decoder.dynamicTable.isEmpty)
    }

    @Test func literalNamedByAnEntryItEvicts() throws {
        var decoder = HPACKDecoder(maxTableSize: 80)
        _ = try decode(&decoder, [0x40, 0x04] + Array("name".utf8) + [0x05] + Array("one-1".utf8)).get()
        // Name index 62 (the only entry), which the insertion evicts.
        let value = Array("a-much-longer-value-x".utf8)
        let sink = try decode(&decoder, [0x7E, UInt8(value.count)] + value).get()
        #expect(sink.fields == [Field("name", "a-much-longer-value-x")])
        #expect(decoder.dynamicTable.fields == [Field("name", "a-much-longer-value-x")])
    }

    @Test func huffmanNameAndValueTogether() throws {
        // C.4.3's custom-key: custom-value uses Huffman for both strings.
        var decoder = HPACKDecoder()
        let block = hex("4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf")
        let sink = try decode(&decoder, block).get()
        #expect(sink.fields == [Field("custom-key", "custom-value")])
    }
}
