/// One header field as stored in an ``HTTPFieldIndex``: its name ID and where its name and
/// value bytes are in the arena.
public struct HTTPField: Sendable, Hashable {
    /// The well-known ID, or ``HTTPFieldName/unknown``.
    public var name: HTTPFieldName
    /// The name bytes in the arena as received. Empty for well-known names added to an
    /// owned ``HTTPFields``, whose name bytes are ``HTTPFieldName/canonicalName``.
    public var nameView: ByteView
    /// The value bytes in the arena, without surrounding whitespace.
    public var valueView: ByteView

    @inlinable
    public init(name: HTTPFieldName, nameView: ByteView, valueView: ByteView) {
        self.name = name
        self.nameView = nameView
        self.valueView = valueView
    }
}

/// Ordered, duplicate-preserving header field index: three parallel arrays (name ID, name
/// range, value range) over a byte arena owned by someone else (docs/ROADMAP.md §7, "data
/// layout: parallel arrays for headers").
///
/// The index never touches bytes except when resolving a name; lookups compare one-byte IDs.
/// A 128-bit presence mask answers "is this well-known name present?" without a scan, so a
/// miss costs a shift and a mask. ``removeAll(keepingCapacity:)`` keeps the storage so a
/// connection refills the same index for every request without allocating.
///
/// ## Storage
///
/// The three arrays live in one copy-on-write allocation (``Storage``) addressed through one
/// base pointer, and the count lives in the index. An append is one uniqueness check, one
/// capacity compare and three stores; growth and copying are out of line. The pointers never
/// leave the type: ``names``, ``nameViews`` and ``valueViews`` are bounds-checked
/// ``Column`` views that keep the storage alive.
public struct HTTPFieldIndex: Sendable {
    @usableFromInline var storage: Storage
    @usableFromInline var _count: Int
    /// Bit `id` is set when a field with well-known ID `id` is present (IDs below 128).
    @usableFromInline var presenceLow: UInt64
    @usableFromInline var presenceHigh: UInt64

    /// Creates an empty index without allocating.
    @inlinable
    public init() {
        storage = Storage.empty
        _count = 0
        presenceLow = 0
        presenceHigh = 0
    }

    /// Creates an empty index with room for `minimumCapacity` fields.
    @inlinable
    public init(minimumCapacity: Int) {
        self.init()
        reserveCapacity(minimumCapacity)
    }

    // MARK: Contents

    /// The name ID of each field, in order.
    @inlinable public var names: Column<HTTPFieldName> { Column(storage, storage.names, _count) }
    /// The name range of each field, in order.
    @inlinable public var nameViews: Column<ByteView> { Column(storage, storage.nameViews, _count) }
    /// The value range of each field, in order.
    @inlinable public var valueViews: Column<ByteView> { Column(storage, storage.valueViews, _count) }

    /// Number of fields, duplicates included.
    @inlinable public var count: Int { _count }

    /// True when there are no fields.
    @inlinable public var isEmpty: Bool { _count == 0 }

    /// Number of fields the index can hold without allocating.
    @inlinable public var capacity: Int { storage.capacity }

    /// The field at `position`.
    @inlinable
    public subscript(position: Int) -> HTTPField {
        checkIndex(position)
        return HTTPField(name: storage.names[position], nameView: storage.nameViews[position],
                         valueView: storage.valueViews[position])
    }

    @inlinable
    func checkIndex(_ position: Int) {
        precondition(UInt(bitPattern: position) < UInt(bitPattern: _count), "HTTPFieldIndex position out of range")
    }

    // MARK: Presence and lookup

    /// True when a field with the well-known `name` is present. Always false for
    /// ``HTTPFieldName/unknown``. O(1).
    @inlinable
    public func contains(_ name: HTTPFieldName) -> Bool {
        let id = name.rawValue
        guard id != 0 else { return false }
        let lane = id < 64 ? presenceLow : presenceHigh
        return (lane >> UInt64(id & 63)) & 1 == 1
    }

    /// Position of the first field with the well-known `name` at or after `start`, or `nil`.
    ///
    /// Each step is a one-byte compare; a name that is absent returns immediately from the
    /// presence mask.
    @inlinable
    public func firstIndex(of name: HTTPFieldName, from start: Int = 0) -> Int? {
        guard contains(name) else { return nil }
        let names = storage.names
        var i = Swift.max(start, 0)
        let end = _count
        while i < end {
            if names[i] == name { return i }
            i &+= 1
        }
        return nil
    }

    // MARK: Adding

    /// Ensures room for `minimumCapacity` fields.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        if minimumCapacity > storage.capacity || !isKnownUniquelyReferenced(&storage) {
            replaceStorage(capacity: Swift.max(minimumCapacity, storage.capacity))
        }
    }

    /// Appends a field whose name ID the caller already resolved.
    @inlinable
    public mutating func append(_ name: HTTPFieldName, nameView: ByteView, valueView: ByteView) {
        let position = _count
        if _slowPath(position == storage.capacity || !isKnownUniquelyReferenced(&storage)) {
            replaceStorage(capacity: Swift.max(storage.capacity &* 2, position &+ 1, 8))
        }
        let storage = self.storage
        (storage.names + position).initialize(to: name)
        (storage.nameViews + position).initialize(to: nameView)
        (storage.valueViews + position).initialize(to: valueView)
        _count = position &+ 1
        markPresent(name)
    }

    /// Appends a field, resolving its name from its bytes in `arena`
    /// (``HTTPFieldName/lookup(_:)``). `hash` is ignored: name resolution no longer needs the
    /// FNV-1a hash older callers computed while scanning (#0112).
    ///
    /// - Returns: The resolved name ID.
    @inlinable
    @discardableResult
    public mutating func append(nameView: ByteView, hash: UInt32, valueView: ByteView, in arena: ByteBuffer) -> HTTPFieldName {
        let name = arena.withSpan(of: nameView) { HTTPFieldName.lookup($0) }
        append(name, nameView: nameView, valueView: valueView)
        return name
    }

    @inlinable
    mutating func markPresent(_ name: HTTPFieldName) {
        let id = name.rawValue
        guard id != 0 else { return }
        let bit = UInt64(1) << UInt64(id & 63)
        if id < 64 { presenceLow |= bit } else { presenceHigh |= bit }
    }

    /// Moves the fields into new storage of `capacity` (at least ``count``).
    @usableFromInline @inline(never)
    mutating func replaceStorage(capacity: Int) {
        let new = Storage(capacity: Swift.max(capacity, _count))
        new.names.initialize(from: storage.names, count: _count)
        new.nameViews.initialize(from: storage.nameViews, count: _count)
        new.valueViews.initialize(from: storage.valueViews, count: _count)
        storage = new
    }

    // MARK: Removing

    /// Removes every field. With `keepingCapacity` (the default) the storage is kept for the
    /// next request.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            if !isKnownUniquelyReferenced(&storage) {
                storage = Storage(capacity: storage.capacity)
            }
        } else {
            storage = Storage.empty
        }
        _count = 0
        presenceLow = 0
        presenceHigh = 0
    }

    /// Removes the field at `position`, keeping the order of the rest. O(n).
    @inlinable
    public mutating func remove(at position: Int) {
        checkIndex(position)
        makeUnique()
        let s = storage
        // Forward copy: each destination is read before it is overwritten.
        for i in position..<(_count &- 1) {
            s.names[i] = s.names[i &+ 1]
            s.nameViews[i] = s.nameViews[i &+ 1]
            s.valueViews[i] = s.valueViews[i &+ 1]
        }
        _count &-= 1
        rebuildPresence()
    }

    /// Removes every field with the well-known `name`, keeping the order of the rest. O(n).
    @inlinable
    public mutating func removeAll(_ name: HTTPFieldName) {
        guard contains(name) else { return }
        makeUnique()
        let s = storage
        var write = 0
        for read in 0..<_count where s.names[read] != name {
            if write != read {
                s.names[write] = s.names[read]
                s.nameViews[write] = s.nameViews[read]
                s.valueViews[write] = s.valueViews[read]
            }
            write &+= 1
        }
        _count = write
        rebuildPresence()
    }

    @inlinable
    mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            replaceStorage(capacity: storage.capacity)
        }
    }

    @inlinable
    mutating func rebuildPresence() {
        presenceLow = 0
        presenceHigh = 0
        let names = storage.names
        for i in 0..<_count { markPresent(names[i]) }
    }
}

extension HTTPFieldIndex {
    /// The three parallel arrays in one allocation: `capacity` name ranges, then `capacity`
    /// value ranges, then `capacity` one-byte name IDs. Elements are trivial, so nothing is
    /// deinitialized. Shared between copies of an index and copied before a write when it is
    /// not uniquely referenced, so it is never mutated while shared.
    @usableFromInline
    final class Storage: @unchecked Sendable {
        @usableFromInline let capacity: Int
        @usableFromInline let nameViews: UnsafeMutablePointer<ByteView>
        @usableFromInline let valueViews: UnsafeMutablePointer<ByteView>
        @usableFromInline let names: UnsafeMutablePointer<HTTPFieldName>

        @usableFromInline static let empty = Storage(capacity: 0)

        @usableFromInline
        init(capacity: Int) {
            precondition(capacity >= 0, "HTTPFieldIndex capacity must not be negative")
            self.capacity = capacity
            let viewBytes = capacity &* MemoryLayout<ByteView>.stride
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Swift.max(2 &* viewBytes &+ capacity &* MemoryLayout<HTTPFieldName>.stride, 1),
                alignment: MemoryLayout<ByteView>.alignment)
            nameViews = raw.bindMemory(to: ByteView.self, capacity: capacity)
            valueViews = (raw + viewBytes).bindMemory(to: ByteView.self, capacity: capacity)
            names = (raw + 2 &* viewBytes).bindMemory(to: HTTPFieldName.self, capacity: capacity)
        }

        deinit {
            UnsafeMutableRawPointer(nameViews).deallocate()
        }
    }

    /// A read-only, bounds-checked view of one of the index's parallel arrays, valid as long
    /// as you hold it (it keeps the storage alive and does not see later appends).
    public struct Column<Element>: RandomAccessCollection {
        @usableFromInline let storage: Storage
        @usableFromInline let base: UnsafeMutablePointer<Element>
        public let count: Int

        @inlinable
        init(_ storage: Storage, _ base: UnsafeMutablePointer<Element>, _ count: Int) {
            self.storage = storage
            self.base = base
            self.count = count
        }

        @inlinable public var startIndex: Int { 0 }
        @inlinable public var endIndex: Int { count }

        @inlinable
        public subscript(position: Int) -> Element {
            precondition(UInt(bitPattern: position) < UInt(bitPattern: count), "HTTPFieldIndex.Column position out of range")
            return withExtendedLifetime(storage) { base[position] }
        }
    }
}

extension HTTPFieldIndex.Column: @unchecked Sendable where Element: Sendable {}
