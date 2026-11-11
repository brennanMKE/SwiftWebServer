/// Owned, ordered header fields with duplicates kept, for responses (and request snapshots).
///
/// Storage is an ``HTTPFieldIndex`` over a private byte arena. Adding a well-known name stores
/// only its one-byte ID (the serializer writes ``HTTPFieldName/canonicalName``); the value is
/// copied into the arena. A handler that reuses one `HTTPFields` and calls
/// ``removeAll(keepingCapacity:)`` between responses adds fields without allocating once the
/// arena and index have grown to fit.
///
/// Values are stored as given; the serializer rejects CR, LF and NUL (#0076).
public struct HTTPFields: Sendable, HTTPFieldCollection {
    @usableFromInline var index: HTTPFieldIndex
    @usableFromInline var arena: ByteBuffer

    /// Creates empty fields without allocating.
    @inlinable
    public init() {
        index = HTTPFieldIndex()
        arena = ByteBuffer()
    }

    /// Creates empty fields with room for `minimumCapacity` fields and `arenaCapacity` bytes.
    @inlinable
    public init(minimumCapacity: Int, arenaCapacity: Int) {
        index = HTTPFieldIndex(minimumCapacity: minimumCapacity)
        arena = ByteBuffer(capacity: arenaCapacity)
    }

    @inlinable
    public func withFieldStorage<R, E: Error>(_ body: (HTTPFieldIndex, ByteBuffer) throws(E) -> R) throws(E) -> R {
        try body(index, arena)
    }

    /// The index, for serializers and header encoders that walk the fields in order.
    @inlinable public var fieldIndex: HTTPFieldIndex { index }

    // MARK: Appending

    /// Appends a well-known name with a static value. Copies only the value bytes.
    @inlinable
    public mutating func append(_ name: HTTPFieldName, _ value: StaticString) {
        precondition(name.isWellKnown, "use append(name:value:) for names that are not well known")
        let start = arena.writerIndex
        arena.append(value)
        index.append(name, nameView: .empty, valueView: ByteView(offset: start, length: arena.writerIndex &- start))
    }

    /// Appends a well-known name with value bytes.
    @inlinable
    public mutating func append(_ name: HTTPFieldName, value: Span<UInt8>) {
        precondition(name.isWellKnown, "use append(name:value:) for names that are not well known")
        let start = arena.writerIndex
        arena.append(contentsOf: value)
        index.append(name, nameView: .empty, valueView: ByteView(offset: start, length: arena.writerIndex &- start))
    }

    /// Appends a well-known name with a decimal integer value, such as `content-length`.
    /// No `String` is created.
    @inlinable
    public mutating func append<T: FixedWidthInteger>(_ name: HTTPFieldName, decimal value: T) {
        precondition(name.isWellKnown, "use append(name:value:) for names that are not well known")
        let start = arena.writerIndex
        arena.append(decimal: value)
        index.append(name, nameView: .empty, valueView: ByteView(offset: start, length: arena.writerIndex &- start))
    }

    /// Appends a well-known name with a `String` value. Convenience for edges; the hot path
    /// uses the static and span forms.
    @inlinable
    public mutating func append(_ name: HTTPFieldName, string value: String) {
        var value = value
        value.withUTF8 { append(name, value: $0.span) }
    }

    /// Appends a field by name bytes. A well-known name (any case) is stored as its ID;
    /// any other name keeps its bytes as given.
    @inlinable
    public mutating func append(name: Span<UInt8>, value: Span<UInt8>) {
        let id = HTTPFieldName.lookup(name)
        if id.isWellKnown {
            append(id, value: value)
            return
        }
        let nameStart = arena.writerIndex
        arena.append(contentsOf: name)
        let valueStart = arena.writerIndex
        arena.append(contentsOf: value)
        index.append(.unknown,
                     nameView: ByteView(offset: nameStart, length: valueStart &- nameStart),
                     valueView: ByteView(offset: valueStart, length: arena.writerIndex &- valueStart))
    }

    /// Appends a field with a static name and value.
    @inlinable
    public mutating func append(name: StaticString, value: StaticString) {
        name.withUTF8Buffer { nameBytes in
            value.withUTF8Buffer { valueBytes in append(name: nameBytes.span, value: valueBytes.span) }
        }
    }

    /// Appends a field with `String` name and value. Allocates; for edges only.
    @inlinable
    public mutating func append(name: String, value: String) {
        var name = name
        var value = value
        name.withUTF8 { nameBytes in
            value.withUTF8 { valueBytes in append(name: nameBytes.span, value: valueBytes.span) }
        }
    }

    /// Appends the field at `position` of another collection (a request view, for example).
    @inlinable
    public mutating func append(_ position: Int, of other: some HTTPFieldCollection) {
        other.withFieldStorage { otherIndex, otherArena in
            let field = otherIndex[position]
            otherArena.withSpan(of: field.valueView) { value in
                if field.name.isWellKnown {
                    append(field.name, value: value)
                } else {
                    otherArena.withSpan(of: field.nameView) { name in append(name: name, value: value) }
                }
            }
        }
    }

    // MARK: Replacing and removing

    /// Replaces every field with the well-known `name` by one field with `value`, appended
    /// at the end.
    @inlinable
    public mutating func set(_ name: HTTPFieldName, _ value: StaticString) {
        index.removeAll(name)
        append(name, value)
    }

    /// Replaces every field with the well-known `name` by one field with a decimal value.
    @inlinable
    public mutating func set<T: FixedWidthInteger>(_ name: HTTPFieldName, decimal value: T) {
        index.removeAll(name)
        append(name, decimal: value)
    }

    /// Removes every field with the well-known `name`. The arena bytes stay until
    /// ``removeAll(keepingCapacity:)``.
    @inlinable
    public mutating func removeAll(_ name: HTTPFieldName) {
        index.removeAll(name)
    }

    /// Removes the field at `position`.
    @inlinable
    public mutating func remove(at position: Int) {
        index.remove(at: position)
    }

    /// Removes every field and the arena bytes. With `keepingCapacity` (the default) the
    /// storage is reused.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        index.removeAll(keepingCapacity: keepingCapacity)
        arena.clear(keepingCapacity: keepingCapacity)
    }

    /// Number of fields and arena bytes the storage can hold without allocating.
    @inlinable
    public var capacity: (fields: Int, bytes: Int) { (index.capacity, arena.capacity) }
}

extension HTTPFields: CustomDebugStringConvertible {
    public var debugDescription: String {
        var parts: [String] = []
        for i in 0..<count {
            parts.append("\(nameString(at: i)): \(valueString(at: i))")
        }
        return "HTTPFields([\(parts.joined(separator: ", "))])"
    }
}
