import Testing
import QPACK

private func lookup(_ name: [UInt8], _ value: [UInt8]) -> QPACKStaticTable.Match {
    name.withUnsafeBytes { n in value.withUnsafeBytes { v in QPACKStaticTable.lookup(name: n, value: v) } }
}

private func lookup(_ name: String, _ value: String) -> QPACKStaticTable.Match {
    lookup(Array(name.utf8), Array(value.utf8))
}

@Suite struct QPACKStaticTableTests {
    @Test func hasNinetyNineEntries() {
        #expect(QPACKStaticTable.count == 99)
    }

    @Test func spotChecksAgainstAppendixA() {
        let expected: [(Int, String, String)] = [
            (0, ":authority", ""), (1, ":path", "/"), (17, ":method", "GET"), (25, ":status", "200"),
            (31, "accept-encoding", "gzip, deflate, br"), (52, "content-type", "text/html; charset=utf-8"),
            (58, "strict-transport-security", "max-age=31536000; includesubdomains; preload"),
            (63, ":status", "100"), (84, "authorization", ""),
            (85, "content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
            (98, "x-frame-options", "sameorigin"),
        ]
        for (index, name, value) in expected {
            #expect(QPACKStaticTable.name(at: index) == Array(name.utf8), "name \(index)")
            #expect(QPACKStaticTable.value(at: index) == Array(value.utf8), "value \(index)")
        }
    }

    @Test func everyEntryIsFoundByNameAndValue() {
        for index in 0..<QPACKStaticTable.count {
            let name = QPACKStaticTable.name(at: index)
            let value = QPACKStaticTable.value(at: index)
            #expect(lookup(name, value) == .field(index), "entry \(index)")
            QPACKStaticTable.withEntry(index) { n, v in
                #expect(Array(n) == name)
                #expect(Array(v) == value)
            }
        }
    }

    @Test func nameLookupReturnsLowestIndexWithThatName() {
        for index in 0..<QPACKStaticTable.count {
            let name = QPACKStaticTable.name(at: index)
            let lowest = (0...index).first { QPACKStaticTable.name(at: $0) == name }
            let found = name.withUnsafeBytes { QPACKStaticTable.index(name: $0) }
            #expect(found == lowest, "entry \(index)")
        }
    }

    @Test func nameOnlyAndMissingLookups() {
        #expect(lookup(":method", "PATCH") == .name(15))
        #expect(lookup(":status", "201") == .name(24))
        #expect(lookup("content-type", "text/xml") == .name(44))
        #expect(lookup("user-agent", "curl/8.0") == .name(95))
        #expect(lookup("x-custom", "1") == .none)
        #expect(lookup("", "") == .none)
        // Byte-exact: uppercase names and prefixes of real names miss.
        #expect(lookup(":METHOD", "GET") == .none)
        #expect(lookup("content-typ", "text/css") == .none)
        #expect(lookup("content-type", "text/css ") == .name(44))
        // Values must not leak across the name/value boundary.
        #expect(lookup(":path/", "") == .none)
        #expect(lookup(":pat", "h/") == .none)
        let indexed = Array(":method".utf8).withUnsafeBytes { n in
            Array("GET".utf8).withUnsafeBytes { QPACKStaticTable.index(name: n, value: $0) }
        }
        #expect(indexed == 17)
    }
}
