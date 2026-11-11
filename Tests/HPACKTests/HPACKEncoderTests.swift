import HeaderCompression
import Testing
@testable import HPACK

/// Encodes `fields` as one block.
func encodeBlock(
    _ encoder: inout HPACKEncoder, _ fields: [Field],
    indexing: (Field) -> HPACKIndexingPolicy = { _ in .automatic }
) -> [UInt8] {
    var out: [UInt8] = []
    encoder.beginHeaderBlock(into: &out)
    for field in fields {
        withSpans(field) { name, value in
            encoder.encode(name: name, value: value, indexing: indexing(field), into: &out)
        }
    }
    return out
}

@Suite struct HPACKEncoderTests {
    // MARK: RFC 7541 Appendix C, byte for byte

    @Test func appendixC2() {
        let policies: [String: HPACKIndexingPolicy] = ["C.2.3": .neverIndexed]
        for step in RFC7541Vectors.representations {
            var encoder = HPACKEncoder(huffman: .never)
            let out = encodeBlock(&encoder, step.fields) { _ in policies[step.name] ?? .automatic }
            #expect(out == step.encoded, "\(step.name)")
            #expect(encoder.dynamicTable.fields == step.table, "\(step.name)")
            #expect(encoder.dynamicTable.size == step.tableSize, "\(step.name)")
        }
    }

    /// The automatic policy reproduces the RFC's choices, except that the RFC indexes
    /// `set-cookie`, which the encoder never indexes on its own. C.4 matches `.whenShorter`;
    /// C.6.2 Huffman-codes "307" although that is no shorter (3 bytes), so C.6 uses `.always`.
    @Test(arguments: RFC7541Vectors.sequences.map(\.name))
    func appendixCSequence(name: String) throws {
        let sequence = RFC7541Vectors.sequences.first { $0.name == name }!
        var encoder = HPACKEncoder(
            tableCapacity: sequence.tableSize, peerMaxTableSize: sequence.tableSize,
            huffman: !sequence.huffman ? .never : name == "C.6" ? .always : .whenShorter)
        var decoder = HPACKDecoder(maxTableSize: sequence.tableSize)
        for step in sequence.steps {
            let out = encodeBlock(&encoder, step.fields) { $0.name == "set-cookie" ? .incremental : .automatic }
            #expect(out == step.encoded, "\(step.name)")
            #expect(encoder.dynamicTable.fields == step.table, "\(step.name)")
            #expect(encoder.dynamicTable.size == step.tableSize, "\(step.name)")
            let sink = try decode(&decoder, out).get()
            #expect(sink.fields == step.fields)
            #expect(decoder.dynamicTable.fields == encoder.dynamicTable.fields)
        }
    }

    // MARK: Policies

    @Test func sensitiveNamesAreNeverIndexed() throws {
        var encoder = HPACKEncoder()
        var decoder = HPACKDecoder()
        let fields = [
            Field("authorization", "Bearer abc"), Field("cookie", "a=b"),
            Field("set-cookie", "c=d"), Field("proxy-authorization", "Basic x"),
        ]
        for _ in 0..<2 {
            let out = encodeBlock(&encoder, fields)
            let sink = try decode(&decoder, out).get()
            #expect(sink.fields == fields)
            #expect(sink.representations == Array(repeating: .neverIndexed, count: 4))
        }
        #expect(encoder.dynamicTable.isEmpty)
        // authorization uses static name index 23: 0x10 | 0x0F, then 23 − 15 = 8.
        let auth = encodeBlock(&encoder, [fields[0]])
        #expect(Array(auth.prefix(2)) == [0x1F, 0x08])
    }

    @Test func callerMarkedSensitiveField() throws {
        var encoder = HPACKEncoder()
        var decoder = HPACKDecoder()
        let field = Field("x-api-key", "secret")
        let out = encodeBlock(&encoder, [field]) { _ in .neverIndexed }
        #expect(out[0] == 0x10)
        #expect(try decode(&decoder, out).get().representations == [.neverIndexed])
        #expect(encoder.dynamicTable.isEmpty)
        // Even an exact static match is sent as a never-indexed literal.
        let get = encodeBlock(&encoder, [Field(":method", "GET")]) { _ in .neverIndexed }
        #expect(get == [0x12, 0x03] + Array("GET".utf8))
    }

    @Test func volatileNamesAreNotIndexedButCacheableOnesAre() {
        var encoder = HPACKEncoder(huffman: .never)
        _ = encodeBlock(&encoder, [
            Field(":path", "/a/b"), Field("content-length", "123"), Field("etag", "\"x\""),
            Field("content-type", "text/html"), Field("x-custom", "1"),
        ])
        #expect(encoder.dynamicTable.fields == [Field("x-custom", "1"), Field("content-type", "text/html")])
        // The second time, cacheable fields are one byte each.
        let again = encodeBlock(&encoder, [Field("content-type", "text/html"), Field("x-custom", "1")])
        #expect(again == [0xBF, 0xBE])
    }

    @Test func largeEntriesAreNotIndexedAutomatically() {
        var encoder = HPACKEncoder(tableCapacity: 256, peerMaxTableSize: 256)
        _ = encodeBlock(&encoder, [Field("x-big", String(repeating: "v", count: 200))])
        #expect(encoder.dynamicTable.isEmpty)
        // An explicit .incremental still indexes if it fits.
        _ = encodeBlock(&encoder, [Field("x-big", String(repeating: "v", count: 200))]) { _ in .incremental }
        #expect(encoder.dynamicTable.count == 1)
    }

    @Test func huffmanOnlyWhenShorter() {
        var encoder = HPACKEncoder()
        // "www.example.com" is 12 bytes Huffman-coded (C.4.1).
        let short = encodeBlock(&encoder, [Field(":authority", "www.example.com")])
        #expect(short[1] == 0x8C)
        // Bytes with long codes grow under Huffman, so they stay raw.
        let raw = encodeBlock(&encoder, [Field("x-bin", "\u{7F}\u{7F}")]) { _ in .withoutIndexing }
        #expect(raw.suffix(3) == [0x02, 0x7F, 0x7F])
    }

    // MARK: Table size updates

    @Test func sizeUpdateAfterPeerSettingsChange() throws {
        var encoder = HPACKEncoder()
        var decoder = HPACKDecoder()
        _ = try decode(&decoder, encodeBlock(&encoder, RFC7541Vectors.request1)).get()
        encoder.setPeerMaxTableSize(0)
        decoder.setMaxTableSizeLimit(0)
        #expect(encoder.dynamicTable.isEmpty)
        let out = encodeBlock(&encoder, [Field(":method", "GET")])
        #expect(out == [0x20, 0x82])
        _ = try decode(&decoder, out).get()
        // No update once it has been sent.
        #expect(encodeBlock(&encoder, [Field(":method", "GET")]) == [0x82])
    }

    @Test func shrinkThenGrowSendsMinimumThenFinal() throws {
        var encoder = HPACKEncoder()
        encoder.setPeerMaxTableSize(100)
        encoder.setPeerMaxTableSize(4096)
        let out = encodeBlock(&encoder, [])
        // 100 = 31 + 69; 4096 = 31 + 4065 = 0x1F, 0xE1, 0x1F.
        #expect(out == [0x3F, 0x45, 0x3F, 0xE1, 0x1F])
        var decoder = HPACKDecoder()
        _ = try decode(&decoder, out).get()
        #expect(decoder.dynamicTable.maxSize == 4096)
    }

    @Test func peerSettingAboveCapacityIsClamped() {
        var encoder = HPACKEncoder(tableCapacity: 1024)
        // Capacity below the peer's initial 4096: the first block announces 1024.
        #expect(encoder.hasPendingTableSizeUpdate)
        #expect(encodeBlock(&encoder, []) == [0x3F, 0xE1, 0x07])
        encoder.setPeerMaxTableSize(65_536)
        #expect(!encoder.hasPendingTableSizeUpdate)
        #expect(encoder.dynamicTable.maxSize == 1024)
        encoder.setPeerMaxTableSize(4096)
        #expect(!encoder.hasPendingTableSizeUpdate)
    }

    // MARK: Round trips

    /// Random header lists (repeated names and values, sensitive names, all policies, peer
    /// table size changes) must decode to the same fields and leave both tables identical.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func seededRoundTrip(seed: UInt64) throws {
        var random = SeededRandom(seed: seed)
        let names = [
            ":method", ":path", ":status", "content-type", "cookie", "set-cookie", "authorization",
            "x-trace", "x-a", "accept", "date", "cache-control", "user-agent",
        ]
        let policies: [HPACKIndexingPolicy] = [.automatic, .automatic, .incremental, .withoutIndexing, .neverIndexed]
        let capacity = 512
        var encoder = HPACKEncoder(
            tableCapacity: capacity, peerMaxTableSize: capacity,
            huffman: [StringLiteral.HuffmanPolicy.whenShorter, .always, .never][Int(seed % 3)])
        var decoder = HPACKDecoder(maxTableSize: capacity, maxHeaderListSize: 1 << 20)
        for blockNumber in 0..<300 {
            if random.next() % 20 == 0 {
                let size = Int(random.next() % UInt64(capacity + 1))
                encoder.setPeerMaxTableSize(size)
                decoder.setMaxTableSizeLimit(size)
            }
            var fields: [Field] = []
            var indexing: [HPACKIndexingPolicy] = []
            for _ in 0..<Int(random.next() % 12) {
                let name = random.next() % 8 == 0
                    ? "x-\(random.next() % 1000)" : names[Int(random.next() % UInt64(names.count))]
                let valueLength = Int(random.next() % (random.next() % 4 == 0 ? 300 : 12))
                let value = String((0..<valueLength).map { _ in
                    Character(Unicode.Scalar(UInt8(32 + random.next() % 95)))
                })
                fields.append(Field(name, random.next() % 3 == 0 ? "1" : value))
                indexing.append(policies[Int(random.next() % UInt64(policies.count))])
            }
            var out: [UInt8] = []
            encoder.beginHeaderBlock(into: &out)
            for (field, policy) in zip(fields, indexing) {
                withSpans(field) { encoder.encode(name: $0, value: $1, indexing: policy, into: &out) }
            }
            let sink = try decode(&decoder, out).get()
            #expect(sink.fields == fields, "block \(blockNumber)")
            for (representation, policy) in zip(sink.representations, indexing) where policy == .neverIndexed {
                #expect(representation == .neverIndexed)
            }
            #expect(decoder.dynamicTable.fields == encoder.dynamicTable.fields, "block \(blockNumber)")
            #expect(decoder.dynamicTable.size == encoder.dynamicTable.size)
            #expect(decoder.dynamicTable.maxSize == encoder.dynamicTable.maxSize)
        }
    }

    /// Random bytes must either decode or throw; never crash or hang.
    @Test(arguments: [11, 12, 13] as [UInt64])
    func seededGarbageDecodes(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        for _ in 0..<2_000 {
            var decoder = HPACKDecoder(maxTableSize: 256, maxHeaderListSize: 4096)
            let bytes = (0..<Int(random.next() % 64)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            _ = decode(&decoder, bytes)
        }
    }
}
