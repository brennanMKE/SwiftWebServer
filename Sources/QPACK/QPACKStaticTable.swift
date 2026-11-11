/// The QPACK static table (RFC 9204 Appendix A): 99 entries, indices 0...98.
///
/// Entries are stored as one flat byte array plus offsets. Two open-addressed hash tables over
/// the (lowercase) name bytes, built once at first use, give allocation-free lookup by name and
/// by name and value. Lookups are byte-exact: HTTP/3 field names are lowercase (RFC 9114 §4.2),
/// so an uppercase name simply misses and is encoded as a literal.
public enum QPACKStaticTable {
    /// The number of entries.
    public static let count = 99

    /// The result of ``lookup(name:value:)``.
    public enum Match: Equatable, Sendable {
        /// No entry has this name.
        case none
        /// The entry at this index has the name (the lowest such index) but not the value.
        case name(Int)
        /// The entry at this index has both the name and the value.
        case field(Int)
    }

    /// The name of entry `index` (copied; for tests and diagnostics, not the hot path).
    public static func name(at index: Int) -> [UInt8] {
        let entry = staticTable.entries[index]
        return Array(staticTable.bytes[Int(entry.nameStart)..<Int(entry.nameEnd)])
    }

    /// The value of entry `index` (copied; for tests and diagnostics, not the hot path).
    public static func value(at index: Int) -> [UInt8] {
        let entry = staticTable.entries[index]
        return Array(staticTable.bytes[Int(entry.nameEnd)..<Int(entry.valueEnd)])
    }

    /// Calls `body` with the name and value of entry `index` without copying.
    ///
    /// - Precondition: `0 <= index < count`.
    @inlinable
    public static func withEntry<Result>(
        _ index: Int,
        _ body: (_ name: UnsafeRawBufferPointer, _ value: UnsafeRawBufferPointer) -> Result
    ) -> Result {
        precondition(index >= 0 && index < count, "static table index out of range")
        let entry = staticTable.entries[index]
        return staticTable.bytes.withUnsafeBytes { bytes in
            body(
                UnsafeRawBufferPointer(rebasing: bytes[Int(entry.nameStart)..<Int(entry.nameEnd)]),
                UnsafeRawBufferPointer(rebasing: bytes[Int(entry.nameEnd)..<Int(entry.valueEnd)]))
        }
    }

    /// The best static entry for a field: an exact match if there is one, else the lowest
    /// index with the same name.
    @inlinable
    public static func lookup(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer) -> Match {
        staticTable.lookup(name: name, value: value)
    }

    /// The lowest index whose name is `name`, if any.
    @inlinable
    public static func index(name: UnsafeRawBufferPointer) -> Int? {
        staticTable.withStorage { bytes, entries, nameSlots, _ in
            StaticTableStorage.findName(
                name, hash: StaticTableStorage.hash(name), bytes: bytes, entries: entries, slots: nameSlots)
        }
    }

    /// The index whose name is `name` and value is `value`, if any.
    @inlinable
    public static func index(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer) -> Int? {
        if case .field(let index) = lookup(name: name, value: value) { return index }
        return nil
    }
}

/// Byte offsets of one entry in ``StaticTableStorage/bytes``: name is
/// `nameStart..<nameEnd`, value is `nameEnd..<valueEnd`.
@usableFromInline
struct StaticTableEntry: Sendable {
    @usableFromInline let nameStart: UInt16
    @usableFromInline let nameEnd: UInt16
    @usableFromInline let valueEnd: UInt16

    @usableFromInline
    init(nameStart: UInt16, nameEnd: UInt16, valueEnd: UInt16) {
        self.nameStart = nameStart
        self.nameEnd = nameEnd
        self.valueEnd = valueEnd
    }
}

@usableFromInline
let staticTable = StaticTableStorage()

@usableFromInline
struct StaticTableStorage: Sendable {
    /// Hash slots per table; a power of two well above the entry count keeps probes short.
    @usableFromInline static let slotCount = 256
    /// Marks an empty slot.
    @usableFromInline static let emptySlot: UInt8 = 0xFF

    @usableFromInline let bytes: [UInt8]
    @usableFromInline let entries: [StaticTableEntry]
    /// Name hash → lowest entry index with that name.
    @usableFromInline let nameSlots: [UInt8]
    /// (Name, value) hash → entry index.
    @usableFromInline let fieldSlots: [UInt8]

    init() {
        var bytes: [UInt8] = []
        var entries: [StaticTableEntry] = []
        for (name, value) in staticTableDefinition {
            let start = UInt16(bytes.count)
            bytes += name.utf8
            let nameEnd = UInt16(bytes.count)
            bytes += value.utf8
            entries.append(StaticTableEntry(nameStart: start, nameEnd: nameEnd, valueEnd: UInt16(bytes.count)))
        }
        precondition(entries.count == QPACKStaticTable.count, "RFC 9204 static table has 99 entries")

        let mask = Self.slotCount - 1
        var nameSlots = [UInt8](repeating: Self.emptySlot, count: Self.slotCount)
        var fieldSlots = [UInt8](repeating: Self.emptySlot, count: Self.slotCount)
        bytes.withUnsafeBytes { raw in
            for (index, entry) in entries.enumerated() {
                let name = UnsafeRawBufferPointer(rebasing: raw[Int(entry.nameStart)..<Int(entry.nameEnd)])
                let value = UnsafeRawBufferPointer(rebasing: raw[Int(entry.nameEnd)..<Int(entry.valueEnd)])
                let nameHash = Self.hash(name)
                var slot = Int(nameHash) & mask
                while true {
                    let existing = nameSlots[slot]
                    if existing == Self.emptySlot {
                        nameSlots[slot] = UInt8(index)
                        break
                    }
                    let other = entries[Int(existing)]
                    if Self.equal(name, raw, Int(other.nameStart), Int(other.nameEnd)) { break }
                    slot = (slot + 1) & mask
                }
                slot = Int(Self.hash(value: value, nameHash: nameHash)) & mask
                while fieldSlots[slot] != Self.emptySlot { slot = (slot + 1) & mask }
                fieldSlots[slot] = UInt8(index)
            }
        }
        self.bytes = bytes
        self.entries = entries
        self.nameSlots = nameSlots
        self.fieldSlots = fieldSlots
    }

    /// FNV-1a (32-bit) over `bytes`, starting from `seed`.
    @inlinable
    static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt32 = 0x811C_9DC5) -> UInt32 {
        var hash = seed
        for byte in bytes {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        // Fold the high bits in: the low 8 bits alone index the slots.
        return hash ^ (hash >> 15)
    }

    /// The hash of a (name, value) pair, chained from the name's hash through a separator
    /// byte (0xFF never occurs in a field name) so ("ab", "c") and ("a", "bc") differ.
    @inlinable
    static func hash(value: UnsafeRawBufferPointer, nameHash: UInt32) -> UInt32 {
        hash(value, seed: (nameHash ^ 0xFF) &* 0x0100_0193)
    }

    @inlinable
    static func equal(
        _ candidate: UnsafeRawBufferPointer, _ bytes: UnsafeRawBufferPointer, _ start: Int, _ end: Int
    ) -> Bool {
        guard candidate.count == end &- start else { return false }
        var i = 0
        while i < candidate.count {
            if candidate[i] != bytes[start &+ i] { return false }
            i &+= 1
        }
        return true
    }

    @inlinable
    func withStorage<Result>(
        _ body: (
            UnsafeRawBufferPointer, UnsafeBufferPointer<StaticTableEntry>,
            UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>
        ) -> Result
    ) -> Result {
        bytes.withUnsafeBytes { bytes in
            entries.withUnsafeBufferPointer { entries in
                nameSlots.withUnsafeBufferPointer { nameSlots in
                    fieldSlots.withUnsafeBufferPointer { fieldSlots in
                        body(bytes, entries, nameSlots, fieldSlots)
                    }
                }
            }
        }
    }

    @inlinable
    static func findName(
        _ name: UnsafeRawBufferPointer, hash: UInt32, bytes: UnsafeRawBufferPointer,
        entries: UnsafeBufferPointer<StaticTableEntry>, slots: UnsafeBufferPointer<UInt8>
    ) -> Int? {
        let mask = slotCount &- 1
        var slot = Int(hash) & mask
        while true {
            let index = slots[slot]
            if index == emptySlot { return nil }
            let entry = entries[Int(index)]
            if equal(name, bytes, Int(entry.nameStart), Int(entry.nameEnd)) { return Int(index) }
            slot = (slot &+ 1) & mask
        }
    }

    @inlinable
    func lookup(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer) -> QPACKStaticTable.Match {
        withStorage { bytes, entries, nameSlots, fieldSlots in
            let nameHash = Self.hash(name)
            let mask = Self.slotCount &- 1
            var slot = Int(Self.hash(value: value, nameHash: nameHash)) & mask
            while true {
                let index = fieldSlots[slot]
                if index == Self.emptySlot { break }
                let entry = entries[Int(index)]
                if Self.equal(name, bytes, Int(entry.nameStart), Int(entry.nameEnd))
                    && Self.equal(value, bytes, Int(entry.nameEnd), Int(entry.valueEnd))
                {
                    return .field(Int(index))
                }
                slot = (slot &+ 1) & mask
            }
            if let index = Self.findName(name, hash: nameHash, bytes: bytes, entries: entries, slots: nameSlots) {
                return .name(index)
            }
            return .none
        }
    }
}

/// RFC 9204 Appendix A, in index order.
let staticTableDefinition: [(String, String)] = [
    (":authority", ""),
    (":path", "/"),
    ("age", "0"),
    ("content-disposition", ""),
    ("content-length", "0"),
    ("cookie", ""),
    ("date", ""),
    ("etag", ""),
    ("if-modified-since", ""),
    ("if-none-match", ""),
    ("last-modified", ""),
    ("link", ""),
    ("location", ""),
    ("referer", ""),
    ("set-cookie", ""),
    (":method", "CONNECT"),
    (":method", "DELETE"),
    (":method", "GET"),
    (":method", "HEAD"),
    (":method", "OPTIONS"),
    (":method", "POST"),
    (":method", "PUT"),
    (":scheme", "http"),
    (":scheme", "https"),
    (":status", "103"),
    (":status", "200"),
    (":status", "304"),
    (":status", "404"),
    (":status", "503"),
    ("accept", "*/*"),
    ("accept", "application/dns-message"),
    ("accept-encoding", "gzip, deflate, br"),
    ("accept-ranges", "bytes"),
    ("access-control-allow-headers", "cache-control"),
    ("access-control-allow-headers", "content-type"),
    ("access-control-allow-origin", "*"),
    ("cache-control", "max-age=0"),
    ("cache-control", "max-age=2592000"),
    ("cache-control", "max-age=604800"),
    ("cache-control", "no-cache"),
    ("cache-control", "no-store"),
    ("cache-control", "public, max-age=31536000"),
    ("content-encoding", "br"),
    ("content-encoding", "gzip"),
    ("content-type", "application/dns-message"),
    ("content-type", "application/javascript"),
    ("content-type", "application/json"),
    ("content-type", "application/x-www-form-urlencoded"),
    ("content-type", "image/gif"),
    ("content-type", "image/jpeg"),
    ("content-type", "image/png"),
    ("content-type", "text/css"),
    ("content-type", "text/html; charset=utf-8"),
    ("content-type", "text/plain"),
    ("content-type", "text/plain;charset=utf-8"),
    ("range", "bytes=0-"),
    ("strict-transport-security", "max-age=31536000"),
    ("strict-transport-security", "max-age=31536000; includesubdomains"),
    ("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
    ("vary", "accept-encoding"),
    ("vary", "origin"),
    ("x-content-type-options", "nosniff"),
    ("x-xss-protection", "1; mode=block"),
    (":status", "100"),
    (":status", "204"),
    (":status", "206"),
    (":status", "302"),
    (":status", "400"),
    (":status", "403"),
    (":status", "421"),
    (":status", "425"),
    (":status", "500"),
    ("accept-language", ""),
    ("access-control-allow-credentials", "FALSE"),
    ("access-control-allow-credentials", "TRUE"),
    ("access-control-allow-headers", "*"),
    ("access-control-allow-methods", "get"),
    ("access-control-allow-methods", "get, post, options"),
    ("access-control-allow-methods", "options"),
    ("access-control-expose-headers", "content-length"),
    ("access-control-request-headers", "content-type"),
    ("access-control-request-method", "get"),
    ("access-control-request-method", "post"),
    ("alt-svc", "clear"),
    ("authorization", ""),
    ("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
    ("early-data", "1"),
    ("expect-ct", ""),
    ("forwarded", ""),
    ("if-range", ""),
    ("origin", ""),
    ("purpose", "prefetch"),
    ("server", ""),
    ("timing-allow-origin", "*"),
    ("upgrade-insecure-requests", "1"),
    ("user-agent", ""),
    ("x-forwarded-for", ""),
    ("x-frame-options", "deny"),
    ("x-frame-options", "sameorigin"),
]
