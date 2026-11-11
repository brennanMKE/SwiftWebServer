import Testing
@testable import HPACK

@Suite struct HPACKStaticTableTests {
    @Test func appendixAEntries() {
        #expect(HPACKStaticTable.count == 61)
        let samples: [(Int, Field)] = [
            (1, Field(":authority", "")), (2, Field(":method", "GET")), (3, Field(":method", "POST")),
            (5, Field(":path", "/index.html")), (8, Field(":status", "200")), (14, Field(":status", "500")),
            (16, Field("accept-encoding", "gzip, deflate")), (32, Field("cookie", "")),
            (55, Field("set-cookie", "")), (61, Field("www-authenticate", "")),
        ]
        for (index, expected) in samples {
            let field = HPACKStaticTable.withEntry(at: index) { Field(string($0), string($1)) }
            #expect(field == expected, "index \(index)")
        }
    }

    @Test func everyEntryIsFoundByNameAndValue() {
        for index in 1...HPACKStaticTable.count {
            let field = HPACKStaticTable.withEntry(at: index) { Field(string($0), string($1)) }
            let match = withSpans(field) { HPACKStaticTable.search(name: $0, value: $1) }
            #expect(match == .field(index), "\(field)")
            let first = withSpan(field.name) { HPACKStaticTable.firstIndex(name: $0) }
            #expect(first != nil && first! <= index)
        }
    }

    @Test func nameOnlyAndMissingLookups() {
        #expect(withSpans(Field(":status", "404")) { HPACKStaticTable.search(name: $0, value: $1) } == .field(13))
        #expect(withSpans(Field(":status", "302")) { HPACKStaticTable.search(name: $0, value: $1) } == .name(8))
        #expect(withSpans(Field(":method", "PUT")) { HPACKStaticTable.search(name: $0, value: $1) } == .name(2))
        #expect(withSpans(Field("custom-key", "x")) { HPACKStaticTable.search(name: $0, value: $1) } == .none)
        // Names are case-sensitive in HTTP/2 (they must be lowercase).
        #expect(withSpan("Date") { HPACKStaticTable.firstIndex(name: $0) } == nil)
        #expect(withSpan("date") { HPACKStaticTable.firstIndex(name: $0) } == 33)
        #expect(withSpan("") { HPACKStaticTable.firstIndex(name: $0) } == nil)
    }

    @Test func sensitiveAndVolatileNames() {
        #expect([23, 32, 49, 55].allSatisfy(HPACKStaticTable.isSensitiveName(at:)))
        #expect(!HPACKStaticTable.isSensitiveName(at: 24))
        #expect(HPACKStaticTable.isVolatileName(at: 4))
        #expect(HPACKStaticTable.isVolatileName(at: 28))
        #expect(!HPACKStaticTable.isVolatileName(at: 33))
    }
}

@Suite struct HPACKDynamicTableTests {
    @Test func sizeAccountingUsesEntryOverhead() {
        var table = HPACKDynamicTable(capacity: 4096)
        do { let added = table.insert(Field("custom-key", "custom-header")); #expect(added) }
        #expect(table.size == 10 + 13 + 32)
        #expect(table.count == 1)
        #expect(table.entrySize(at: 0) == 55)
    }

    @Test func newestIsFirstAndEvictionIsFIFO() {
        // Each entry is 1 + 1 + 32 = 34 bytes; 100 bytes hold two.
        var table = HPACKDynamicTable(capacity: 100)
        table.insert(Field("a", "1"))
        table.insert(Field("b", "2"))
        #expect(table.fields == [Field("b", "2"), Field("a", "1")])
        table.insert(Field("c", "3"))
        #expect(table.fields == [Field("c", "3"), Field("b", "2")])
        #expect(table.size == 68)
        table.insert(Field("d", "4"))
        table.insert(Field("e", "5"))
        #expect(table.fields == [Field("e", "5"), Field("d", "4")])
    }

    @Test func insertEvictsAsManyAsNeeded() {
        var table = HPACKDynamicTable(capacity: 120)
        table.insert(Field("a", "1"))
        table.insert(Field("b", "2"))
        table.insert(Field("c", "3"))
        // 34 × 3 = 102; a 70-byte entry (38 bytes of name + value) needs two evictions.
        table.insert(Field("long", String(repeating: "x", count: 34)))
        #expect(table.fields.map(\.name) == ["long", "c"])
        #expect(table.size == 70 + 34)
    }

    @Test func sizeUpdateToZeroEvictsEverything() {
        var table = HPACKDynamicTable(capacity: 4096)
        for i in 0..<20 { table.insert(Field("name-\(i)", "value-\(i)")) }
        table.setMaxSize(0)
        #expect(table.count == 0)
        #expect(table.size == 0)
        do { let added = table.insert(Field("a", "b")); #expect(!added) }
        #expect(table.isEmpty)
        table.setMaxSize(4096)
        do { let added = table.insert(Field("a", "b")); #expect(added) }
        #expect(table.fields == [Field("a", "b")])
    }

    @Test func sizeUpdateEvictsOldestUntilItFits() {
        var table = HPACKDynamicTable(capacity: 4096)
        table.insert(Field("a", "1"))
        table.insert(Field("b", "2"))
        table.insert(Field("c", "3"))
        table.setMaxSize(70)
        #expect(table.fields == [Field("c", "3"), Field("b", "2")])
        #expect(table.maxSize == 70)
    }

    @Test func entryLargerThanTableEmptiesIt() {
        var table = HPACKDynamicTable(capacity: 64)
        table.insert(Field("a", "1"))
        do { let added = table.insert(Field("big", String(repeating: "v", count: 40))); #expect(!added) }
        #expect(table.isEmpty)
        #expect(table.size == 0)
        // Exactly maxSize fits.
        do { let added = table.insert(Field("n", String(repeating: "v", count: 31))); #expect(added) }
        #expect(table.size == 64)
    }

    @Test func capacitySmallerThanOneEntry() {
        var table = HPACKDynamicTable(capacity: 16)
        do { let added = table.insert(Field("", "")); #expect(!added) }
        #expect(table.isEmpty)
    }

    @Test func emptyNamesAndValues() {
        var table = HPACKDynamicTable(capacity: 128)
        table.insert(Field("", ""))
        table.insert(Field("", "v"))
        table.insert(Field("n", ""))
        #expect(table.fields == [Field("n", ""), Field("", "v"), Field("", "")])
        #expect(table.size == 32 + 33 + 33)
    }

    @Test func unifiedIndexAddressSpace() throws {
        var table = HPACKDynamicTable(capacity: 4096)
        table.insert(Field("first", "1"))
        table.insert(Field("second", "2"))
        let s = try table.withField(atIndex: 2) { Field(string($0), string($1)) }
        #expect(s == Field(":method", "GET"))
        let last = try table.withField(atIndex: 61) { Field(string($0), string($1)) }
        #expect(last == Field("www-authenticate", ""))
        let newest = try table.withField(atIndex: 62) { Field(string($0), string($1)) }
        #expect(newest == Field("second", "2"))
        let oldest = try table.withField(atIndex: 63) { Field(string($0), string($1)) }
        #expect(oldest == Field("first", "1"))
        for bad: UInt64 in [0, 64, 1000, UInt64.max] {
            #expect(throws: HPACKError.invalidIndex(bad)) {
                try table.withField(atIndex: bad) { _, _ in () }
            }
        }
        let empty = HPACKDynamicTable(capacity: 4096)
        #expect(throws: HPACKError.invalidIndex(62)) { try empty.checkIndex(62) }
    }

    @Test func unifiedSearchPrefersStaticThenNewest() {
        var table = HPACKDynamicTable(capacity: 4096)
        table.insert(Field(":status", "302"))
        table.insert(Field("custom", "a"))
        table.insert(Field("custom", "b"))
        func search(_ field: Field) -> HPACKTableMatch {
            withSpans(field) { table.search(name: $0, value: $1) }
        }
        #expect(search(Field(":status", "200")) == .field(8))
        #expect(search(Field(":status", "302")) == .field(64))
        #expect(search(Field(":status", "307")) == .name(8))
        #expect(search(Field("custom", "a")) == .field(63))
        #expect(search(Field("custom", "z")) == .name(62))
        #expect(search(Field("other", "z")) == .none)
    }

    @Test func insertWithNameOfEvictedEntry() {
        // The only entry is evicted by the insertion that copies its name.
        var table = HPACKDynamicTable(capacity: 80)
        table.insert(Field("custom-name", "value-one"))
        let added = withSpan("value-two-longer") { table.insert(nameOfEntryAt: 0, value: $0) }
        #expect(added)
        #expect(table.fields == [Field("custom-name", "value-two-longer")])
        // The name of an entry that stays.
        var two = HPACKDynamicTable(capacity: 4096)
        two.insert(Field("x-a", "1"))
        two.insert(Field("x-b", "2"))
        withSpan("3") { _ = two.insert(nameOfEntryAt: 1, value: $0) }
        #expect(two.fields == [Field("x-a", "3"), Field("x-b", "2"), Field("x-a", "1")])
    }

    @Test func copiesAreIndependent() {
        var table = HPACKDynamicTable(capacity: 4096)
        table.insert(Field("a", "1"))
        var copy = table
        copy.insert(Field("b", "2"))
        table.insert(Field("c", "3"))
        #expect(table.fields == [Field("c", "3"), Field("a", "1")])
        #expect(copy.fields == [Field("b", "2"), Field("a", "1")])
    }

    /// Random inserts and size changes against a plain array model, so the ring and arena wrap
    /// many times at every alignment.
    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func matchesReferenceModel(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        let capacity = 256
        var table = HPACKDynamicTable(capacity: capacity)
        var model: [Field] = []
        var maxSize = capacity
        for step in 0..<5_000 {
            if random.next() % 50 == 0 {
                maxSize = Int(random.next() % UInt64(capacity + 1))
                table.setMaxSize(maxSize)
                while model.reduce(0, { $0 + $1.size }) > maxSize { model.removeLast() }
            } else {
                let nameLength = Int(random.next() % 20)
                let valueLength = Int(random.next() % 200)
                let byte = UInt8(97 + step % 26)
                let field = Field(String(repeating: Character(Unicode.Scalar(byte)), count: nameLength),
                                  String(repeating: "\(step % 10)", count: valueLength))
                let useName = !model.isEmpty && random.next() % 3 == 0
                if useName {
                    let position = Int(random.next() % UInt64(model.count))
                    let named = Field(model[position].name, field.value)
                    withSpan(named.value) { _ = table.insert(nameOfEntryAt: position, value: $0) }
                    model.insert(named, at: 0)
                } else {
                    table.insert(field)
                    model.insert(field, at: 0)
                }
                if model[0].size > maxSize {
                    model.removeAll()
                } else {
                    while model.reduce(0, { $0 + $1.size }) > maxSize { model.removeLast() }
                }
            }
            #expect(table.size == model.reduce(0, { $0 + $1.size }))
            #expect(table.size <= table.maxSize)
            if table.fields != model {
                Issue.record("step \(step): table \(table.fields) != model \(model)")
                return
            }
        }
    }
}
