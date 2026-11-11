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
/// miss costs a shift and a mask. ``removeAll(keepingCapacity:)`` keeps the array storage so a
/// connection refills the same index for every request without allocating.
public struct HTTPFieldIndex: Sendable {
    @usableFromInline var _names: [HTTPFieldName]
    @usableFromInline var _nameViews: [ByteView]
    @usableFromInline var _valueViews: [ByteView]
    /// Bit `id` is set when a field with well-known ID `id` is present (IDs below 128).
    @usableFromInline var presenceLow: UInt64
    @usableFromInline var presenceHigh: UInt64

    /// Creates an empty index without allocating.
    @inlinable
    public init() {
        _names = []
        _nameViews = []
        _valueViews = []
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
    @inlinable public var names: [HTTPFieldName] { _names }
    /// The name range of each field, in order.
    @inlinable public var nameViews: [ByteView] { _nameViews }
    /// The value range of each field, in order.
    @inlinable public var valueViews: [ByteView] { _valueViews }

    /// Number of fields, duplicates included.
    @inlinable public var count: Int { _names.count }

    /// True when there are no fields.
    @inlinable public var isEmpty: Bool { _names.isEmpty }

    /// Number of fields the index can hold without allocating.
    @inlinable public var capacity: Int { Swift.min(_names.capacity, _nameViews.capacity, _valueViews.capacity) }

    /// The field at `position`.
    @inlinable
    public subscript(position: Int) -> HTTPField {
        HTTPField(name: _names[position], nameView: _nameViews[position], valueView: _valueViews[position])
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
        var i = start
        let end = _names.count
        while i < end {
            if _names[i] == name { return i }
            i &+= 1
        }
        return nil
    }

    // MARK: Adding

    /// Ensures room for `minimumCapacity` fields.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        _names.reserveCapacity(minimumCapacity)
        _nameViews.reserveCapacity(minimumCapacity)
        _valueViews.reserveCapacity(minimumCapacity)
    }

    /// Appends a field whose name ID the caller already resolved.
    @inlinable
    public mutating func append(_ name: HTTPFieldName, nameView: ByteView, valueView: ByteView) {
        _names.append(name)
        _nameViews.append(nameView)
        _valueViews.append(valueView)
        markPresent(name)
    }

    /// Appends a field, resolving its name from the lowercased FNV-1a `hash` the parser
    /// computed while scanning the name (``HTTPFieldName/lookup(hash:name:)``).
    ///
    /// - Returns: The resolved name ID.
    @inlinable
    @discardableResult
    public mutating func append(nameView: ByteView, hash: UInt32, valueView: ByteView, in arena: ByteBuffer) -> HTTPFieldName {
        let name = arena.withSpan(of: nameView) { HTTPFieldName.lookup(hash: hash, name: $0) }
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

    // MARK: Removing

    /// Removes every field. With `keepingCapacity` (the default) the array storage is kept for
    /// the next request.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        _names.removeAll(keepingCapacity: keepingCapacity)
        _nameViews.removeAll(keepingCapacity: keepingCapacity)
        _valueViews.removeAll(keepingCapacity: keepingCapacity)
        presenceLow = 0
        presenceHigh = 0
    }

    /// Removes the field at `position`, keeping the order of the rest. O(n).
    @inlinable
    public mutating func remove(at position: Int) {
        _names.remove(at: position)
        _nameViews.remove(at: position)
        _valueViews.remove(at: position)
        rebuildPresence()
    }

    /// Removes every field with the well-known `name`, keeping the order of the rest. O(n).
    @inlinable
    public mutating func removeAll(_ name: HTTPFieldName) {
        guard contains(name) else { return }
        var write = 0
        for read in 0..<_names.count where _names[read] != name {
            if write != read {
                _names[write] = _names[read]
                _nameViews[write] = _nameViews[read]
                _valueViews[write] = _valueViews[read]
            }
            write &+= 1
        }
        let removed = _names.count &- write
        _names.removeLast(removed)
        _nameViews.removeLast(removed)
        _valueViews.removeLast(removed)
        rebuildPresence()
    }

    @inlinable
    mutating func rebuildPresence() {
        presenceLow = 0
        presenceHigh = 0
        for name in _names { markPresent(name) }
    }
}
