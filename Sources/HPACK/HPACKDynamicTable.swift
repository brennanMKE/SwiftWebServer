import HTTPCore

/// The HPACK dynamic table (RFC 7541 §2.3.2, §4): a FIFO of header fields, newest first.
///
/// ## Layout
///
/// Entries are a ring of fixed-size records over a single ``ByteArena`` that holds their name
/// and value bytes contiguously. Both are sized once from ``capacity`` (the largest
/// ``maxSize`` the table will ever be given, normally `SETTINGS_HEADER_TABLE_SIZE`), so inserts,
/// evictions and size updates never allocate.
///
/// The byte arena is `2 × capacity` bytes. An entry that does not fit before the end of the
/// arena is written at offset 0 instead, so every entry stays contiguous; the live bytes never
/// exceed `maxSize − 32 × count` and the gap left at the end is smaller than one entry, so the
/// doubled arena always has room without overwriting a live entry.
///
/// ## Indexing
///
/// ``withEntry(at:_:)`` takes a 0-based position (0 = newest). ``withField(atIndex:_:)`` and
/// ``search(name:value:)`` use the unified HPACK address space: 1...61 is the static table,
/// 62 and above the dynamic table (RFC 7541 §2.3.3).
///
/// `HPACKDynamicTable` is a copy-on-write value; a copy shares the arena until either is mutated.
public struct HPACKDynamicTable: Sendable {
    /// Per-entry overhead in the size accounting (RFC 7541 §4.1).
    public static let entryOverhead = 32

    /// The first dynamic index in the unified address space.
    public static let firstIndex = HPACKStaticTable.count + 1

    struct Entry: Sendable {
        var offset = 0
        var nameLength = 0
        var valueLength = 0
        /// FNV-1a of the name and of the value, to skip byte comparisons when searching.
        var nameHash: UInt32 = 0
        var valueHash: UInt32 = 0

        var length: Int { nameLength + valueLength }
        var size: Int { nameLength + valueLength + HPACKDynamicTable.entryOverhead }
    }

    /// The largest ``maxSize`` this table accepts; fixed at creation.
    public let capacity: Int

    /// The current maximum size, in RFC 7541 §4.1 units (≤ ``capacity``).
    public private(set) var maxSize: Int

    /// The current size: the sum of each entry's name length + value length + 32.
    public private(set) var size = 0

    /// The number of entries.
    public private(set) var count = 0

    var arena: ByteArena
    var entries: [Entry]
    /// Ring slot of the oldest entry.
    var oldestSlot = 0
    /// Arena offset one past the newest entry's bytes.
    var head = 0

    /// Creates an empty table whose ``maxSize`` starts at, and never exceeds, `capacity`.
    public init(capacity: Int = 4096) {
        precondition(capacity >= 0, "dynamic table capacity must not be negative")
        self.capacity = capacity
        maxSize = capacity
        arena = ByteArena(capacity: 2 * capacity)
        entries = Array(repeating: Entry(), count: Swift.max(1, capacity / Self.entryOverhead))
    }

    /// True when the table has no entries.
    public var isEmpty: Bool { count == 0 }

    // MARK: Reading

    @inline(__always)
    func slot(ofPosition position: Int) -> Int {
        var slot = oldestSlot + count - 1 - position
        if slot >= entries.count { slot -= entries.count }
        return slot
    }

    /// The RFC 7541 §4.1 size of the entry at `position` (0 = newest).
    public func entrySize(at position: Int) -> Int {
        precondition(position >= 0 && position < count, "dynamic table position \(position) outside 0..<\(count)")
        return entries[slot(ofPosition: position)].size
    }

    /// Calls `body` with the name and value of the entry at `position` (0 = newest).
    public func withEntry<R, E: Error>(
        at position: Int, _ body: (_ name: Span<UInt8>, _ value: Span<UInt8>) throws(E) -> R
    ) throws(E) -> R {
        precondition(position >= 0 && position < count, "dynamic table position \(position) outside 0..<\(count)")
        let entry = entries[slot(ofPosition: position)]
        return try arena.withSpan(offset: entry.offset, count: entry.nameLength) { (name) throws(E) -> R in
            try arena.withSpan(offset: entry.offset + entry.nameLength, count: entry.valueLength) {
                (value) throws(E) -> R in
                try body(name, value)
            }
        }
    }

    /// Calls `body` with the field at `index` in the unified address space (1...61 static,
    /// 62... dynamic).
    ///
    /// - Throws: ``HPACKError/invalidIndex(_:)`` for 0 or an index past the last entry.
    public func withField<R>(
        atIndex index: UInt64,
        _ body: (_ name: Span<UInt8>, _ value: Span<UInt8>) throws(HPACKError) -> R
    ) throws(HPACKError) -> R {
        try checkIndex(index)
        if index <= UInt64(HPACKStaticTable.count) {
            return try HPACKStaticTable.withEntry(at: Int(index), body)
        }
        return try withEntry(at: Int(index) - Self.firstIndex, body)
    }

    /// Throws unless `index` addresses an entry in the unified address space.
    public func checkIndex(_ index: UInt64) throws(HPACKError) {
        guard index >= 1, index < UInt64(Self.firstIndex + count) else { throw .invalidIndex(index) }
    }

    /// Looks `name` and `value` up in the unified address space: an exact match (static table
    /// first, then the newest dynamic entry), else the first index with the name (static first).
    public func search(name: Span<UInt8>, value: Span<UInt8>) -> HPACKTableMatch {
        let staticMatch = HPACKStaticTable.search(name: name, value: value)
        if case .field = staticMatch { return staticMatch }
        switch searchDynamic(name: name, value: value) {
        case .field(let position):
            return .field(Self.firstIndex + position)
        case .name(let position):
            if case .none = staticMatch { return .name(Self.firstIndex + position) }
            return staticMatch
        case .none:
            return staticMatch
        }
    }

    /// Searches the dynamic table only; the result holds 0-based positions (0 = newest).
    public func searchDynamic(name: Span<UInt8>, value: Span<UInt8>) -> HPACKTableMatch {
        guard count > 0 else { return .none }
        let nameHash = ASCII.fnv1aLowercased(name)
        let valueHash = ASCII.fnv1aLowercased(value)
        var nameMatch: Int?
        for position in 0..<count {
            let entry = entries[slot(ofPosition: position)]
            guard entry.nameHash == nameHash, entry.nameLength == name.count,
                  arena.withSpan(offset: entry.offset, count: entry.nameLength, { spanEquals($0, name) })
            else { continue }
            if entry.valueHash == valueHash, entry.valueLength == value.count,
               arena.withSpan(offset: entry.offset + entry.nameLength, count: entry.valueLength, {
                   spanEquals($0, value)
               }) {
                return .field(position)
            }
            if nameMatch == nil { nameMatch = position }
        }
        if let nameMatch { return .name(nameMatch) }
        return .none
    }

    // MARK: Mutating

    /// Sets ``maxSize``, evicting the oldest entries until the table fits (RFC 7541 §4.3).
    public mutating func setMaxSize(_ newValue: Int) {
        precondition(newValue >= 0 && newValue <= capacity,
                     "dynamic table size \(newValue) outside 0...\(capacity)")
        maxSize = newValue
        evict(toFit: 0)
    }

    /// Removes every entry.
    public mutating func removeAll() {
        count = 0
        size = 0
        oldestSlot = 0
        head = 0
    }

    /// Adds a field as the newest entry, evicting old entries to make room (RFC 7541 §4.4).
    ///
    /// - Returns: `false` when the entry is larger than ``maxSize``; the table is then empty.
    @discardableResult
    public mutating func insert(name: Span<UInt8>, value: Span<UInt8>) -> Bool {
        guard let offset = reserve(length: name.count + value.count) else { return false }
        makeArenaUnique()
        arena.write(name, at: offset)
        arena.write(value, at: offset + name.count)
        append(Entry(offset: offset, nameLength: name.count, valueLength: value.count,
                     nameHash: ASCII.fnv1aLowercased(name), valueHash: ASCII.fnv1aLowercased(value)))
        return true
    }

    /// Adds a field whose name is that of the entry at `position`, which the insertion may
    /// evict (RFC 7541 §4.4 allows this; the name is copied before its bytes are reused).
    ///
    /// - Returns: `false` when the entry is larger than ``maxSize``; the table is then empty.
    @discardableResult
    public mutating func insert(nameOfEntryAt position: Int, value: Span<UInt8>) -> Bool {
        precondition(position >= 0 && position < count, "dynamic table position \(position) outside 0..<\(count)")
        let source = entries[slot(ofPosition: position)]
        guard let offset = reserve(length: source.nameLength + value.count) else { return false }
        makeArenaUnique()
        // Eviction only moves indices, so the source bytes are intact; `move` is memmove.
        arena.move(from: source.offset, to: offset, count: source.nameLength)
        arena.write(value, at: offset + source.nameLength)
        append(Entry(offset: offset, nameLength: source.nameLength, valueLength: value.count,
                     nameHash: source.nameHash, valueHash: ASCII.fnv1aLowercased(value)))
        return true
    }

    /// Evicts to make room for an entry of `length` name + value bytes and returns where its
    /// bytes go, or empties the table and returns `nil` when it can never fit.
    private mutating func reserve(length: Int) -> Int? {
        let entrySize = length + Self.entryOverhead
        guard entrySize <= maxSize else {
            removeAll()
            return nil
        }
        evict(toFit: entrySize)
        guard count > 0 else {
            head = 0
            return 0
        }
        let oldestStart = entries[oldestSlot].offset
        if head >= oldestStart {
            if head + length <= arena.capacity { return head }
            precondition(length <= oldestStart, "HPACK arena invariant violated")
            return 0
        }
        precondition(head + length <= oldestStart, "HPACK arena invariant violated")
        return head
    }

    private mutating func append(_ entry: Entry) {
        var slot = oldestSlot + count
        if slot >= entries.count { slot -= entries.count }
        entries[slot] = entry
        count += 1
        size += entry.size
        head = entry.offset + entry.length
    }

    private mutating func makeArenaUnique() {
        if !isKnownUniquelyReferenced(&arena) { arena = arena.copy() }
    }

    /// Evicts the oldest entries until `additional` more bytes fit within ``maxSize``.
    private mutating func evict(toFit additional: Int) {
        while count > 0 && size + additional > maxSize {
            size -= entries[oldestSlot].size
            oldestSlot += 1
            if oldestSlot == entries.count { oldestSlot = 0 }
            count -= 1
        }
        if count == 0 {
            oldestSlot = 0
            head = 0
        }
    }
}
