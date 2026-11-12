/// The QPACK dynamic table of a decoder (RFC 9204 §3.2): a FIFO of field lines that the peer's
/// encoder stream inserts and evicts, addressed by absolute index (§3.2.4).
///
/// ## Layout
///
/// Entries are a ring of fixed-size records over one ``QPACKByteArena`` holding their name and
/// value bytes contiguously (docs/ROADMAP.md §7). Both are sized once from ``maxCapacity`` (our
/// `SETTINGS_QPACK_MAX_TABLE_CAPACITY`), so inserts, evictions and capacity changes never
/// allocate.
///
/// The arena is `2 × maxCapacity` bytes. An entry that does not fit before the end of the arena
/// is written at offset 0 instead, so every entry stays contiguous: the live bytes never exceed
/// `capacity − 32 × count` and the gap at the end is smaller than one entry, so the doubled
/// arena always has room without overwriting a live entry (the HPACK table's scheme).
///
/// ## Indexing
///
/// Absolute index 0 is the first entry ever inserted. The live entries are
/// ``droppedCount`` ..< ``insertCount``. Encoder instructions use relative indices
/// (`insertCount − 1 − relative`); field sections use Base-relative and post-Base indices,
/// which ``QPACKDynamicDecoder`` turns into absolute ones.
///
/// A copy shares the arena until either copy is mutated (copy-on-write).
public struct QPACKDynamicTable: Sendable {
    /// Per-entry overhead in the size accounting (RFC 9204 §3.2.1).
    public static let entryOverhead = 32

    struct Entry: Sendable {
        var offset = 0
        var nameLength = 0
        var valueLength = 0

        var length: Int { nameLength &+ valueLength }
        var size: Int { nameLength &+ valueLength &+ QPACKDynamicTable.entryOverhead }
    }

    /// The largest ``capacity`` the encoder may set: our `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
    public let maxCapacity: Int
    /// The capacity the encoder set with Set Dynamic Table Capacity (§4.3.1); starts at 0
    /// (§3.2.3).
    public private(set) var capacity = 0
    /// The sum of each entry's name length + value length + 32.
    public private(set) var size = 0
    /// The number of live entries.
    public private(set) var count = 0
    /// The total number of insertions so far (the Insert Count of §2.1.4).
    public private(set) var insertCount: UInt64 = 0

    var arena: QPACKByteArena
    var entries: [Entry]
    /// Ring slot of the oldest entry.
    var oldestSlot = 0
    /// Arena offset one past the newest entry's bytes.
    var head = 0

    public init(maxCapacity: Int) {
        precondition(maxCapacity >= 0, "QPACK dynamic table capacity must not be negative")
        self.maxCapacity = maxCapacity
        arena = QPACKByteArena(capacity: 2 * maxCapacity)
        entries = Array(repeating: Entry(), count: Swift.max(1, maxCapacity / Self.entryOverhead))
    }

    /// The absolute index of the oldest live entry: every entry below it was evicted.
    public var droppedCount: UInt64 { insertCount &- UInt64(count) }

    /// Whether `absoluteIndex` names a live entry.
    @inlinable
    public func contains(absoluteIndex: UInt64) -> Bool {
        absoluteIndex >= droppedCount && absoluteIndex < insertCount
    }

    @inline(__always)
    func slot(absoluteIndex: UInt64) -> Int {
        var slot = oldestSlot &+ Int(absoluteIndex &- droppedCount)
        if slot >= entries.count { slot &-= entries.count }
        return slot
    }

    /// The RFC 9204 §3.2.1 size of the entry at `absoluteIndex`.
    public func entrySize(absoluteIndex: UInt64) -> Int {
        precondition(contains(absoluteIndex: absoluteIndex), "QPACK absolute index \(absoluteIndex) is not live")
        return entries[slot(absoluteIndex: absoluteIndex)].size
    }

    /// Calls `body` with the name and value of the live entry at `absoluteIndex`.
    public func withEntry<R, E: Error>(
        absoluteIndex: UInt64,
        _ body: (_ name: UnsafeRawBufferPointer, _ value: UnsafeRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        let (offset, nameLength, valueLength) = location(absoluteIndex: absoluteIndex)
        return try arena.withBytes(offset: offset, count: nameLength &+ valueLength) { (bytes) throws(E) -> R in
            try body(UnsafeRawBufferPointer(rebasing: bytes[0..<nameLength]),
                     UnsafeRawBufferPointer(rebasing: bytes[nameLength...]))
        }
    }

    func location(absoluteIndex: UInt64) -> (offset: Int, nameLength: Int, valueLength: Int) {
        precondition(contains(absoluteIndex: absoluteIndex), "QPACK absolute index \(absoluteIndex) is not live")
        let entry = entries[slot(absoluteIndex: absoluteIndex)]
        return (entry.offset, entry.nameLength, entry.valueLength)
    }

    // MARK: Mutating

    /// Set Dynamic Table Capacity (§4.3.1): evicts the oldest entries until the table fits.
    ///
    /// - Throws: `QPACK_ENCODER_STREAM_ERROR` when `newCapacity` exceeds ``maxCapacity``.
    public mutating func setCapacity(_ newCapacity: UInt64) throws(QPACKError) {
        guard newCapacity <= UInt64(maxCapacity) else {
            throw QPACKError(.encoderStreamError, .tableCapacityExceeded)
        }
        capacity = Int(newCapacity)
        evict(toFit: 0)
    }

    /// Inserts a new entry (§3.2.2), evicting old entries to make room.
    ///
    /// - Throws: `QPACK_ENCODER_STREAM_ERROR` when the entry is larger than ``capacity``.
    public mutating func insert(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer) throws(QPACKError) {
        let offset = try reserve(length: name.count &+ value.count)
        makeArenaUnique()
        arena.write(name, at: offset)
        arena.write(value, at: offset &+ name.count)
        append(Entry(offset: offset, nameLength: name.count, valueLength: value.count))
    }

    /// Inserts an entry whose name is that of the live entry at `absoluteIndex`, which this
    /// insertion may evict (§3.2.2: the name is moved before its bytes can be reused).
    public mutating func insert(nameOfAbsoluteIndex absoluteIndex: UInt64, value: UnsafeRawBufferPointer) throws(QPACKError) {
        precondition(contains(absoluteIndex: absoluteIndex), "QPACK absolute index \(absoluteIndex) is not live")
        let source = entries[slot(absoluteIndex: absoluteIndex)]
        let offset = try reserve(length: source.nameLength &+ value.count)
        makeArenaUnique()
        // Eviction only moves indices, so the source bytes are intact; `move` is memmove.
        arena.move(from: source.offset, to: offset, count: source.nameLength)
        arena.write(value, at: offset &+ source.nameLength)
        append(Entry(offset: offset, nameLength: source.nameLength, valueLength: value.count))
    }

    /// Duplicate (§4.3.4): re-inserts the live entry at `absoluteIndex`.
    public mutating func duplicate(absoluteIndex: UInt64) throws(QPACKError) {
        precondition(contains(absoluteIndex: absoluteIndex), "QPACK absolute index \(absoluteIndex) is not live")
        let source = entries[slot(absoluteIndex: absoluteIndex)]
        let offset = try reserve(length: source.length)
        makeArenaUnique()
        arena.move(from: source.offset, to: offset, count: source.length)
        append(Entry(offset: offset, nameLength: source.nameLength, valueLength: source.valueLength))
    }

    /// Evicts to make room for `length` name + value bytes and returns where they go.
    private mutating func reserve(length: Int) throws(QPACKError) -> Int {
        let entrySize = length &+ Self.entryOverhead
        guard entrySize <= capacity else { throw QPACKError(.encoderStreamError, .insertExceedsCapacity) }
        evict(toFit: entrySize)
        guard count > 0 else {
            head = 0
            return 0
        }
        let oldestStart = entries[oldestSlot].offset
        if head >= oldestStart {
            if head &+ length <= arena.capacity { return head }
            precondition(length <= oldestStart, "QPACK arena invariant violated")
            return 0
        }
        precondition(head &+ length <= oldestStart, "QPACK arena invariant violated")
        return head
    }

    private mutating func append(_ entry: Entry) {
        var slot = oldestSlot &+ count
        if slot >= entries.count { slot &-= entries.count }
        entries[slot] = entry
        count &+= 1
        size &+= entry.size
        insertCount &+= 1
        head = entry.offset &+ entry.length
    }

    private mutating func makeArenaUnique() {
        if !isKnownUniquelyReferenced(&arena) { arena = arena.copy() }
    }

    /// Evicts the oldest entries until `additional` more bytes fit within ``capacity``.
    private mutating func evict(toFit additional: Int) {
        while count > 0 && size &+ additional > capacity {
            size &-= entries[oldestSlot].size
            oldestSlot &+= 1
            if oldestSlot == entries.count { oldestSlot = 0 }
            count &-= 1
        }
        if count == 0 {
            oldestSlot = 0
            head = 0
        }
    }
}

/// Fixed-capacity byte storage behind ``QPACKDynamicTable``.
///
/// It never grows. A reference type: the table copies it before mutating when it is shared,
/// which keeps the table's value semantics and makes `@unchecked Sendable` sound.
final class QPACKByteArena: @unchecked Sendable {
    let capacity: Int
    private let bytes: UnsafeMutableRawPointer

    init(capacity: Int) {
        self.capacity = capacity
        bytes = .allocate(byteCount: Swift.max(capacity, 1), alignment: 1)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: Swift.max(capacity, 1))
    }

    deinit {
        bytes.deallocate()
    }

    func copy() -> QPACKByteArena {
        let new = QPACKByteArena(capacity: capacity)
        new.bytes.copyMemory(from: bytes, byteCount: capacity)
        return new
    }

    @inline(__always)
    private func check(_ offset: Int, _ count: Int) {
        precondition(offset >= 0 && count >= 0 && offset <= capacity &- count,
                     "QPACKByteArena range \(offset)+\(count) outside 0..<\(capacity)")
    }

    func write(_ source: UnsafeRawBufferPointer, at offset: Int) {
        check(offset, source.count)
        guard let base = source.baseAddress, source.count > 0 else { return }
        (bytes + offset).copyMemory(from: base, byteCount: source.count)
    }

    /// Copies `count` bytes; the ranges may overlap (memmove).
    func move(from source: Int, to destination: Int, count: Int) {
        check(source, count)
        check(destination, count)
        guard count > 0, source != destination else { return }
        (bytes + destination).copyMemory(from: bytes + source, byteCount: count)
    }

    func withBytes<R, E: Error>(
        offset: Int, count: Int, _ body: (UnsafeRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        check(offset, count)
        return try body(UnsafeRawBufferPointer(start: bytes + offset, count: count))
    }
}
