import HeaderCompression
import QPACK
import Testing

/// #0106: the decoder-side dynamic table (RFC 9204), driven through ``QPACKDynamicDecoder``.
@Suite(.timeLimit(.minutes(1)))
struct QPACKDynamicTableTests {
    /// The table's live entries, oldest first, with their absolute indices.
    static func entries(_ table: QPACKDynamicTable) -> [(UInt64, String, String)] {
        (table.droppedCount..<table.insertCount).map { index in
            table.withEntry(absoluteIndex: index) { name, value in
                (index, String(decoding: name, as: UTF8.self), String(decoding: value, as: UTF8.self))
            }
        }
    }

    static func expectEntries(
        _ table: QPACKDynamicTable, _ expected: [(UInt64, String, String)], size: Int, insertCount: UInt64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = entries(table)
        #expect(actual.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(actual.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
        #expect(actual.map(\.2) == expected.map(\.2), sourceLocation: sourceLocation)
        #expect(table.size == size, sourceLocation: sourceLocation)
        #expect(table.insertCount == insertCount, sourceLocation: sourceLocation)
    }

    static func consume(_ decoder: inout QPACKDynamicDecoder, _ bytes: [UInt8]) throws -> Int {
        try bytes.withUnsafeBytes { raw throws -> Int in
            let (consumed, _) = try decoder.consumeEncoderStream(raw)
            return consumed
        }
    }

    static func decode(
        _ decoder: inout QPACKDynamicDecoder, _ section: [UInt8], streamID: UInt64
    ) throws -> [Field] {
        var sink = CollectingSink()
        try section.withUnsafeBytes { raw throws in
            guard case .ready(let count) = try decoder.admit(raw) else {
                throw QPACKError(.decompressionFailed, .truncated)   // not expected in these tests
            }
            try decoder.decode(raw, requiredInsertCount: count, streamID: streamID, into: &sink)
        }
        return sink.fields
    }

    static func output(_ decoder: inout QPACKDynamicDecoder) -> [UInt8] {
        var bytes: [UInt8] = []
        decoder.takeDecoderStreamOutput(into: &bytes)
        return bytes
    }

    // MARK: RFC 9204 Appendix B

    /// Appendix B.1 to B.5 in sequence, checking the table after each step.
    @Test func appendixBExamples() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 16)

        // B.1: a static-only literal; the table stays empty and nothing is acknowledged.
        #expect(try Self.decode(&decoder, hex("0000 510b 2f69 6e64 6578 2e68 746d 6c"), streamID: 0)
            == [Field(":path", "/index.html")])
        Self.expectEntries(decoder.table, [], size: 0, insertCount: 0)
        #expect(Self.output(&decoder) == [])

        // B.2: capacity 220, two inserts with static name references, then a section that
        // references both with post-Base indices.
        let b2Encoder = hex("3fbd01 c00f7777772e6578616d706c652e636f6d c10c2f73616d706c652f70617468")
        #expect(try Self.consume(&decoder, b2Encoder) == b2Encoder.count)
        #expect(decoder.table.capacity == 220)
        Self.expectEntries(decoder.table, [(0, ":authority", "www.example.com"), (1, ":path", "/sample/path")],
                           size: 106, insertCount: 2)
        #expect(try Self.decode(&decoder, hex("0381 10 11"), streamID: 4)
            == [Field(":authority", "www.example.com"), Field(":path", "/sample/path")])
        // Section Acknowledgment for stream 4; it also acknowledges both inserts.
        #expect(Self.output(&decoder) == hex("84"))
        #expect(decoder.knownReceivedCount == 2)

        // B.3: a speculative insert with a literal name, acknowledged with an Insert Count
        // Increment of 1.
        #expect(try Self.consume(&decoder, hex("4a637573746f6d2d6b65790c637573746f6d2d76616c7565")) == 24)
        Self.expectEntries(decoder.table, [(0, ":authority", "www.example.com"), (1, ":path", "/sample/path"),
                                           (2, "custom-key", "custom-value")], size: 160, insertCount: 3)
        #expect(Self.output(&decoder) == hex("01"))
        #expect(decoder.knownReceivedCount == 3)

        // B.4: Duplicate of relative index 2 (absolute 0), then stream 8 references it, a
        // static entry and absolute 2.
        #expect(try Self.consume(&decoder, hex("02")) == 1)
        Self.expectEntries(decoder.table, [(0, ":authority", "www.example.com"), (1, ":path", "/sample/path"),
                                           (2, "custom-key", "custom-value"), (3, ":authority", "www.example.com")],
                           size: 217, insertCount: 4)
        #expect(try Self.decode(&decoder, hex("0500 80 c1 81"), streamID: 8)
            == [Field(":authority", "www.example.com"), Field(":path", "/"), Field("custom-key", "custom-value")])
        // The RFC's decoder then sees stream 8 reset and sends Stream Cancellation (0x48)
        // instead; ours decoded it, so it acknowledges it (0x88), which also covers insert 3.
        #expect(Self.output(&decoder) == hex("88"))
        decoder.cancelStream(8)
        #expect(Self.output(&decoder) == hex("48"))

        // B.5: an insert with a dynamic name reference (relative 1 = absolute 2) evicts
        // absolute 0.
        #expect(try Self.consume(&decoder, hex("810d637573746f6d2d76616c756532")) == 15)
        Self.expectEntries(decoder.table, [(1, ":path", "/sample/path"), (2, "custom-key", "custom-value"),
                                           (3, ":authority", "www.example.com"), (4, "custom-key", "custom-value2")],
                           size: 215, insertCount: 5)
        #expect(Self.output(&decoder) == hex("01"))
    }

    // MARK: Required Insert Count

    @Test func requiredInsertCountWrapsAroundFullRange() throws {
        // MaxEntries 6, FullRange 12 (capacity 220).
        func decode(_ encoded: UInt64, inserts: UInt64) throws -> UInt64 {
            try QPACKDynamicDecoder.requiredInsertCount(encoded: encoded, maxEntries: 6, totalInserts: inserts)
        }
        #expect(try decode(0, inserts: 100) == 0)
        #expect(try decode(3, inserts: 2) == 2)
        #expect(try decode(5, inserts: 3) == 4)       // one insert ahead: blocked
        // 100 % 12 = 4, encoded 5 -> 100; encoded 4 -> 99 (wrapped below the window top)
        #expect(try decode(5, inserts: 100) == 100)
        #expect(try decode(4, inserts: 100) == 99)
        #expect(try decode(12, inserts: 100) == 95)
        #expect(throws: QPACKError(.decompressionFailed, .invalidRequiredInsertCount)) { try decode(13, inserts: 0) }
        // Encoded 2 with no inserts would mean Required Insert Count 1 via wrap past FullRange... here
        // MaxValue 6, MaxWrapped 0, count 1: valid (blocked).
        #expect(try decode(2, inserts: 0) == 1)
        // Encoded 1 with MaxValue 12: MaxWrapped 12, count 12 <= MaxValue fine.
        #expect(try decode(1, inserts: 6) == 12)
        // Count 0 after unwrapping is invalid: encoded 1, inserts 0 -> MaxValue 6, MaxWrapped 0, count 0.
        #expect(throws: QPACKError(.decompressionFailed, .invalidRequiredInsertCount)) { try decode(1, inserts: 0) }
        // A non-zero encoded value with no table at all.
        #expect(throws: QPACKError(.decompressionFailed, .invalidRequiredInsertCount)) {
            try QPACKDynamicDecoder.requiredInsertCount(encoded: 1, maxEntries: 0, totalInserts: 0)
        }
    }

    @Test func requiredInsertCountLargerThanNeededIsDecompressionFailed() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 16)
        _ = try Self.consume(&decoder, hex("3fbd01 c00f7777772e6578616d706c652e636f6d c10c2f73616d706c652f70617468"))
        // Required Insert Count 2, but only absolute 0 is referenced (Base 2, relative 1).
        #expect(throws: QPACKError(.decompressionFailed, .invalidRequiredInsertCount)) {
            try Self.decode(&decoder, hex("0300 81"), streamID: 0)
        }
        // Required Insert Count 2 with no dynamic reference at all.
        #expect(throws: QPACKError(.decompressionFailed, .invalidRequiredInsertCount)) {
            try Self.decode(&decoder, hex("0300 c1"), streamID: 0)
        }
    }

    // MARK: Field section references

    @Test func referencesOutsideTheSectionsInsertCountAreDecompressionFailed() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 16)
        _ = try Self.consume(&decoder, hex("3fbd01 c00f7777772e6578616d706c652e636f6d c10c2f73616d706c652f70617468"))
        let invalid = QPACKError(.decompressionFailed, .invalidDynamicIndex)
        // Required Insert Count 1, post-Base index 1 = absolute 1 >= 1.
        #expect(throws: invalid) { try Self.decode(&decoder, hex("0200 11"), streamID: 0) }
        // Relative index 2 with Base 2: below absolute 0.
        #expect(throws: invalid) { try Self.decode(&decoder, hex("0300 82"), streamID: 0) }
        // Base = Required Insert Count − Delta − 1 below zero.
        #expect(throws: QPACKError(.decompressionFailed, .negativeBase)) {
            try Self.decode(&decoder, hex("0382 10"), streamID: 0)
        }
        // Post-Base name reference (0000 N idx) and Literal with dynamic name reference (01N0 idx).
        #expect(try Self.decode(&decoder, hex("0280 00 03 616263"), streamID: 0) == [Field(":authority", "abc")])
        #expect(try Self.decode(&decoder, hex("0300 60 03 78797a 41 01 7a"), streamID: 4)
            == [Field(":path", "xyz", neverIndexed: true), Field(":authority", "z")])
        #expect(Self.output(&decoder) == hex("80 84"))
    }

    @Test func evictedEntriesCannotBeReferenced() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 100, maxBlockedStreams: 16)
        // Capacity 100; "a: 1" is 34 bytes, so three inserts evict the first.
        let insert: [UInt8] = hex("41 61 01 31")   // literal name "a", value "1"
        _ = try Self.consume(&decoder, hex("3f45") + insert + insert + insert)
        #expect(decoder.table.insertCount == 3 && decoder.table.count == 2 && decoder.table.droppedCount == 1)
        // MaxEntries 3, FullRange 6: Required Insert Count 3 encodes as 4. Relative 2 from Base 3 = absolute 0.
        #expect(throws: QPACKError(.decompressionFailed, .invalidDynamicIndex)) {
            try Self.decode(&decoder, hex("0400 82 80"), streamID: 0)
        }
    }

    @Test func fieldSectionSizeLimitCoversDynamicEntries() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 16, maxFieldSectionSize: 60)
        _ = try Self.consume(&decoder, hex("3fbd01 c00f7777772e6578616d706c652e636f6d c10c2f73616d706c652f70617468"))
        // 57 fits; 57 + 49 does not.
        #expect(try Self.decode(&decoder, hex("0200 80"), streamID: 0) == [Field(":authority", "www.example.com")])
        #expect(throws: QPACKError(.decompressionFailed, .fieldSectionTooLarge)) {
            try Self.decode(&decoder, hex("0381 10 11"), streamID: 0)
        }
    }

    // MARK: Blocked streams

    @Test func blockedStreamsAreBounded() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 2)
        let section = hex("0200 80")   // Required Insert Count 1, before any insert
        try section.withUnsafeBytes { raw throws in
            #expect(try decoder.admit(raw) == .blocked(requiredInsertCount: 1))
            #expect(try decoder.admit(raw) == .blocked(requiredInsertCount: 1))
            #expect(throws: QPACKError(.decompressionFailed, .blockedStreamsExceeded)) { try decoder.admit(raw) }
            decoder.unblock()
            #expect(try decoder.admit(raw) == .blocked(requiredInsertCount: 1))
        }
        #expect(decoder.blockedStreams == 2)
        // The insert arrives; both streams decode.
        _ = try Self.consume(&decoder, hex("3fbd01 c00f7777772e6578616d706c652e636f6d"))
        decoder.unblock()
        decoder.unblock()
        var sink = CollectingSink()
        try section.withUnsafeBytes { raw throws in
            try decoder.decode(raw, requiredInsertCount: 1, streamID: 0, into: &sink)
            try decoder.decode(raw, requiredInsertCount: 1, streamID: 4, into: &sink)
        }
        #expect(sink.fields == [Field(":authority", "www.example.com"), Field(":authority", "www.example.com")])
        #expect(Self.output(&decoder) == hex("80 84"))
    }

    @Test func zeroBlockedStreamsRejectsAnySectionAhead() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 0)
        #expect(throws: QPACKError(.decompressionFailed, .blockedStreamsExceeded)) {
            try hex("0200 80").withUnsafeBytes { try decoder.admit($0) }
        }
    }

    // MARK: Encoder stream errors

    @Test func invalidEncoderInstructionsAreEncoderStreamErrors() throws {
        func error(_ bytes: [UInt8], capacity: Int = 220) -> QPACKError? {
            var decoder = QPACKDynamicDecoder(maxTableCapacity: capacity, maxBlockedStreams: 16)
            do {
                _ = try Self.consume(&decoder, bytes)
                return nil
            } catch {
                return error as? QPACKError
            }
        }
        func encoderError(_ reason: QPACKError.Reason) -> QPACKError { QPACKError(.encoderStreamError, reason) }
        // Capacity 221 above the 220 we advertised.
        #expect(error(hex("3fbe01")) == encoderError(.tableCapacityExceeded))
        // Insert before any capacity was set: capacity 0 holds nothing.
        #expect(error(hex("c00161")) == encoderError(.insertExceedsCapacity))
        // An entry larger than the capacity: capacity 40, "a" + 8 bytes + 32 = 41.
        #expect(error(hex("3f09 4161 08 3132333435363738")) == encoderError(.insertExceedsCapacity))
        // Static name index 99.
        #expect(error(hex("3fbd01 ff24 0161")) == encoderError(.staticIndexOutOfRange))
        // Dynamic name reference and Duplicate with nothing inserted.
        #expect(error(hex("3fbd01 80 0161")) == encoderError(.invalidDynamicIndex))
        #expect(error(hex("3fbd01 00")) == encoderError(.invalidDynamicIndex))
        // Duplicate past the newest entry.
        #expect(error(hex("3fbd01 41610131 01")) == encoderError(.invalidDynamicIndex))
        // A string longer than any insert could be.
        #expect(error(hex("3fbd01 c0 7f ff 0f"), capacity: 220) == encoderError(.stringTooLong))
        // Invalid Huffman (EOS padding of more than 7 bits).
        #expect(error(hex("3fbd01 c0 82 ffff")) != nil)
    }

    @Test func partialInstructionsWaitForMoreBytes() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 220, maxBlockedStreams: 16)
        let stream = hex("3fbd01 c00f7777772e6578616d706c652e636f6d")
        var consumed = 0
        var buffer: [UInt8] = []
        for byte in stream {
            buffer.append(byte)
            let used = try Self.consume(&decoder, buffer)
            buffer.removeFirst(used)
            consumed += used
        }
        #expect(consumed == stream.count && buffer.isEmpty)
        Self.expectEntries(decoder.table, [(0, ":authority", "www.example.com")], size: 57, insertCount: 1)
    }

    @Test func huffmanCodedInsertsDecode() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 4096, maxBlockedStreams: 16)
        var stream: [UInt8] = hex("3fe11f")   // capacity 4096
        // Insert With Literal Name, both Huffman-coded.
        var name: [UInt8] = []
        var value: [UInt8] = []
        Array("x-custom".utf8).withUnsafeBytes { StringLiteral.encode($0, prefixBits: 5, flags: 0x40, huffman: .always, into: &name) }
        Array("some value".utf8).withUnsafeBytes { StringLiteral.encode($0, prefixBits: 7, huffman: .always, into: &value) }
        stream += name + value
        #expect(try Self.consume(&decoder, stream) == stream.count)
        Self.expectEntries(decoder.table, [(0, "x-custom", "some value")], size: 50, insertCount: 1)
    }

    /// Many inserts wrap the ring and the arena; every live entry stays intact.
    @Test func ringAndArenaWrap() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 300, maxBlockedStreams: 16)
        _ = try Self.consume(&decoder, hex("3f8d02"))   // capacity 300
        var rng = SplitMix64(seed: 106)
        var model: [(UInt64, String, String)] = []
        for i in 0..<500 {
            let name = "n\(i % 7)"
            let value = String(repeating: "v", count: Int(rng.next() % 60))
            var bytes: [UInt8] = []
            switch rng.next() % 3 {
            case 0 where !model.isEmpty:
                // Duplicate the oldest live entry.
                let relative = UInt64(model.count - 1)
                PrefixInteger.encode(relative, prefixBits: 5, flags: 0x00, into: &bytes)
                let oldest = model[0]
                model.append((decoder.table.insertCount, oldest.1, oldest.2))
            case 1 where !model.isEmpty:
                // Name of the oldest live entry, which this insert may evict.
                let relative = UInt64(model.count - 1)
                PrefixInteger.encode(relative, prefixBits: 6, flags: 0x80, into: &bytes)
                Array(value.utf8).withUnsafeBytes { StringLiteral.encode($0, prefixBits: 7, huffman: .never, into: &bytes) }
                model.append((decoder.table.insertCount, model[0].1, value))
            default:
                Array(name.utf8).withUnsafeBytes { StringLiteral.encode($0, prefixBits: 5, flags: 0x40, huffman: .never, into: &bytes) }
                Array(value.utf8).withUnsafeBytes { StringLiteral.encode($0, prefixBits: 7, huffman: .never, into: &bytes) }
                model.append((decoder.table.insertCount, name, value))
            }
            _ = try Self.consume(&decoder, bytes)
            // Evict from the model like the table does.
            var size = model.reduce(0) { $0 + $1.1.utf8.count + $1.2.utf8.count + 32 }
            while size > 300 {
                size -= model[0].1.utf8.count + model[0].2.utf8.count + 32
                model.removeFirst()
            }
            let actual = Self.entries(decoder.table)
            #expect(actual.map(\.0) == model.map(\.0))
            #expect(actual.map(\.1) == model.map(\.1))
            #expect(actual.map(\.2) == model.map(\.2))
            #expect(decoder.table.size == size)
        }
    }

    @Test func staticOnlySectionsDecodeLikeTheStaticDecoder() throws {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 4096, maxBlockedStreams: 16)
        for request in browserRequests {
            let section = encode(request)
            #expect(try Self.decode(&decoder, section, streamID: 0) == decodedFields(section))
        }
        // Nothing referenced the table: nothing to acknowledge.
        #expect(Self.output(&decoder) == [])
    }
}
