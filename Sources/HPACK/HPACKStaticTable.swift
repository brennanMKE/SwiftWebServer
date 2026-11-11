import HTTPCore

/// The result of looking a field up in an HPACK table.
public enum HPACKTableMatch: Equatable, Sendable {
    /// No entry has this name.
    case none
    /// The entry at this index has the name but a different value.
    case name(Int)
    /// The entry at this index has both the name and the value.
    case field(Int)
}

/// The 61-entry HPACK static table (RFC 7541 §2.3.1, Appendix A), indexed 1...61.
///
/// The entries are packed into one ``ByteArena`` when first used. Name lookup goes through a
/// precomputed 128-slot open-addressed table keyed by FNV-1a of the name; entries sharing a name
/// are contiguous in Appendix A, so a name-value lookup scans only that run. Lookups do not
/// allocate.
public enum HPACKStaticTable {
    /// Number of entries.
    public static let count = 61

    /// Calls `body` with the name and value of the entry at `index` (1...61).
    public static func withEntry<R, E: Error>(
        at index: Int, _ body: (_ name: Span<UInt8>, _ value: Span<UInt8>) throws(E) -> R
    ) throws(E) -> R {
        precondition(index >= 1 && index <= count, "static table index \(index) outside 1...61")
        return try storage.withEntry(at: index, body)
    }

    /// The smallest index whose name is `name`, or `nil`.
    public static func firstIndex(name: Span<UInt8>) -> Int? {
        storage.firstIndex(name: name)
    }

    /// Looks up `name` and `value`: the index of an exact match, else of the first entry with
    /// the name.
    public static func search(name: Span<UInt8>, value: Span<UInt8>) -> HPACKTableMatch {
        guard let first = storage.firstIndex(name: name) else { return .none }
        let last = storage.nameRunEnd[first]
        for index in first...last where storage.valueEquals(at: index, value) {
            return .field(index)
        }
        return .name(first)
    }

    /// Whether the encoder must never index a field with the name at `index`: `authorization`,
    /// `cookie`, `proxy-authorization` and `set-cookie` (RFC 7541 §7.1.3).
    static func isSensitiveName(at index: Int) -> Bool {
        storage.flags[index] & Storage.sensitive != 0
    }

    /// Whether a field with the name at `index` usually changes from block to block, so
    /// indexing it would only evict entries that are reused.
    static func isVolatileName(at index: Int) -> Bool {
        storage.flags[index] & Storage.volatile != 0
    }

    static let storage = Storage()

    struct Storage: Sendable {
        static let sensitive: UInt8 = 1
        static let volatile: UInt8 = 2
        static let slotCount = 128

        let arena: ByteArena
        /// Per index (0 unused): offset of the name, name length, value length.
        let offsets: [Int]
        let nameLengths: [Int]
        let valueLengths: [Int]
        /// Per index: the last index with the same name.
        let nameRunEnd: [Int]
        let flags: [UInt8]
        /// Open-addressed name hash → first index with that name (0 = empty slot).
        let slots: [UInt8]

        init() {
            let entries = HPACKStaticTable.entries
            var total = 0
            for (name, value, _) in entries { total += name.utf8CodeUnitCount + value.utf8CodeUnitCount }
            let arena = ByteArena(capacity: total)
            var offsets = [0], nameLengths = [0], valueLengths = [0], flags: [UInt8] = [0]
            var offset = 0
            for (name, value, flag) in entries {
                arena.write(name, at: offset)
                arena.write(value, at: offset + name.utf8CodeUnitCount)
                offsets.append(offset)
                nameLengths.append(name.utf8CodeUnitCount)
                valueLengths.append(value.utf8CodeUnitCount)
                flags.append(flag)
                offset += name.utf8CodeUnitCount + value.utf8CodeUnitCount
            }
            var runEnd = Array(repeating: 0, count: entries.count + 1)
            var index = entries.count
            while index >= 1 {
                let sameAsNext = index < entries.count
                    && entries[index - 1].0.description == entries[index].0.description
                runEnd[index] = sameAsNext ? runEnd[index + 1] : index
                index -= 1
            }
            var slots = [UInt8](repeating: 0, count: Self.slotCount)
            for index in 1...entries.count where index == 1 || runEnd[index - 1] != runEnd[index] {
                let hash = arena.withSpan(offset: offsets[index], count: nameLengths[index]) {
                    ASCII.fnv1aLowercased($0)
                }
                var slot = Int(hash) & (Self.slotCount - 1)
                while slots[slot] != 0 { slot = (slot + 1) & (Self.slotCount - 1) }
                slots[slot] = UInt8(index)
            }
            self.arena = arena
            self.offsets = offsets
            self.nameLengths = nameLengths
            self.valueLengths = valueLengths
            self.nameRunEnd = runEnd
            self.flags = flags
            self.slots = slots
        }

        func withEntry<R, E: Error>(
            at index: Int, _ body: (Span<UInt8>, Span<UInt8>) throws(E) -> R
        ) throws(E) -> R {
            let offset = offsets[index], nameLength = nameLengths[index]
            return try arena.withSpan(offset: offset, count: nameLength) { (name) throws(E) -> R in
                try arena.withSpan(offset: offset + nameLength, count: valueLengths[index]) {
                    (value) throws(E) -> R in
                    try body(name, value)
                }
            }
        }

        func firstIndex(name: Span<UInt8>) -> Int? {
            var slot = Int(ASCII.fnv1aLowercased(name)) & (Self.slotCount - 1)
            while true {
                let index = Int(slots[slot])
                if index == 0 { return nil }
                if nameEquals(at: index, name) { return index }
                slot = (slot + 1) & (Self.slotCount - 1)
            }
        }

        func nameEquals(at index: Int, _ name: Span<UInt8>) -> Bool {
            guard nameLengths[index] == name.count else { return false }
            return arena.withSpan(offset: offsets[index], count: name.count) { spanEquals($0, name) }
        }

        func valueEquals(at index: Int, _ value: Span<UInt8>) -> Bool {
            guard valueLengths[index] == value.count else { return false }
            return arena.withSpan(offset: offsets[index] + nameLengths[index], count: value.count) {
                spanEquals($0, value)
            }
        }
    }

    /// RFC 7541 Appendix A, in index order (index = position + 1).
    static let entries: [(StaticString, StaticString, UInt8)] = [
        (":authority", "", 0),
        (":method", "GET", 0),
        (":method", "POST", 0),
        (":path", "/", Storage.volatile),
        (":path", "/index.html", Storage.volatile),
        (":scheme", "http", 0),
        (":scheme", "https", 0),
        (":status", "200", 0),
        (":status", "204", 0),
        (":status", "206", 0),
        (":status", "304", 0),
        (":status", "400", 0),
        (":status", "404", 0),
        (":status", "500", 0),
        ("accept-charset", "", 0),
        ("accept-encoding", "gzip, deflate", 0),
        ("accept-language", "", 0),
        ("accept-ranges", "", 0),
        ("accept", "", 0),
        ("access-control-allow-origin", "", 0),
        ("age", "", Storage.volatile),
        ("allow", "", 0),
        ("authorization", "", Storage.sensitive),
        ("cache-control", "", 0),
        ("content-disposition", "", 0),
        ("content-encoding", "", 0),
        ("content-language", "", 0),
        ("content-length", "", Storage.volatile),
        ("content-location", "", 0),
        ("content-range", "", Storage.volatile),
        ("content-type", "", 0),
        ("cookie", "", Storage.sensitive),
        ("date", "", 0),
        ("etag", "", Storage.volatile),
        ("expect", "", 0),
        ("expires", "", 0),
        ("from", "", 0),
        ("host", "", 0),
        ("if-match", "", Storage.volatile),
        ("if-modified-since", "", Storage.volatile),
        ("if-none-match", "", Storage.volatile),
        ("if-range", "", Storage.volatile),
        ("if-unmodified-since", "", Storage.volatile),
        ("last-modified", "", Storage.volatile),
        ("link", "", 0),
        ("location", "", 0),
        ("max-forwards", "", 0),
        ("proxy-authenticate", "", 0),
        ("proxy-authorization", "", Storage.sensitive),
        ("range", "", Storage.volatile),
        ("referer", "", 0),
        ("refresh", "", 0),
        ("retry-after", "", 0),
        ("server", "", 0),
        ("set-cookie", "", Storage.sensitive),
        ("strict-transport-security", "", 0),
        ("transfer-encoding", "", 0),
        ("user-agent", "", 0),
        ("vary", "", 0),
        ("via", "", 0),
        ("www-authenticate", "", 0),
    ]
}

/// Byte-for-byte equality of two spans.
@inline(__always)
func spanEquals(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
    guard a.count == b.count else { return false }
    var i = 0
    while i < a.count {
        if a[i] != b[i] { return false }
        i &+= 1
    }
    return true
}
