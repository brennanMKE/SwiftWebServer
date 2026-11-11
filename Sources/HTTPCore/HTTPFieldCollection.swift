/// Read access shared by ``HTTPFieldsView`` (request fields borrowed from per-connection
/// storage) and ``HTTPFields`` (owned response fields).
///
/// Both are an ``HTTPFieldIndex`` over a byte arena; conformers only provide
/// ``withFieldStorage(_:)`` and every lookup below is written once on top of it. Use the
/// protocol as a generic constraint (`some HTTPFieldCollection`), not as an existential.
public protocol HTTPFieldCollection {
    /// Calls `body` with the index and the arena its ranges point into.
    func withFieldStorage<R, E: Error>(_ body: (HTTPFieldIndex, ByteBuffer) throws(E) -> R) throws(E) -> R
}

/// The result of reading every `Content-Length` field (RFC 9110 §8.6, RFC 9112 §6.3).
public enum HTTPContentLength: Sendable, Hashable {
    /// No `Content-Length` field.
    case absent
    /// One value, possibly repeated identically in several fields or list elements.
    case value(UInt64)
    /// A value that is empty or not a decimal integer.
    case invalid
    /// Two or more different values (#0021): the message must be rejected.
    case conflicting
}

extension HTTPFieldCollection {
    // MARK: Fields by position

    /// Number of fields, duplicates included.
    @inlinable
    public var count: Int { withFieldStorage { index, _ in index.count } }

    /// True when there are no fields.
    @inlinable
    public var isEmpty: Bool { withFieldStorage { index, _ in index.isEmpty } }

    /// The field at `position`.
    @inlinable
    public subscript(position: Int) -> HTTPField {
        withFieldStorage { index, _ in index[position] }
    }

    /// Calls `body` with the name bytes of the field at `position`: the lowercase canonical
    /// name for a well-known ID, otherwise the bytes as received or added.
    @inlinable
    public func withName<R>(at position: Int, _ body: (Span<UInt8>) -> R) -> R {
        withFieldStorage { index, arena in
            let field = index[position]
            if field.name.isWellKnown {
                return field.name.canonicalName.withUTF8Buffer { body($0.span) }
            }
            return arena.withSpan(of: field.nameView, body)
        }
    }

    /// Calls `body` with the value bytes of the field at `position`.
    @inlinable
    public func withValue<R, E: Error>(at position: Int, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try withFieldStorage { (index, arena) throws(E) -> R in
            try arena.withSpan(of: index[position].valueView, body)
        }
    }

    /// Calls `body` with the bytes of `view`, a value or element range from this collection.
    @inlinable
    public func withSpan<R, E: Error>(of view: ByteView, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try withFieldStorage { (_, arena) throws(E) -> R in try arena.withSpan(of: view, body) }
    }

    /// The bytes of `view` decoded as UTF-8. Allocates; for edges, not the hot path.
    @inlinable
    public func string(of view: ByteView) -> String {
        withSpan(of: view) { ASCII.string(from: $0) }
    }

    /// The name of the field at `position` as a `String`. Allocates.
    @inlinable
    public func nameString(at position: Int) -> String {
        withName(at: position) { ASCII.string(from: $0) }
    }

    /// The value of the field at `position` as a `String`. Allocates.
    @inlinable
    public func valueString(at position: Int) -> String {
        withValue(at: position) { ASCII.string(from: $0) }
    }

    // MARK: Lookup by well-known ID

    /// True when a field with the well-known `name` is present. O(1).
    @inlinable
    public func contains(_ name: HTTPFieldName) -> Bool {
        withFieldStorage { index, _ in index.contains(name) }
    }

    /// The value range of the first field with the well-known `name`, or `nil`.
    @inlinable
    public func firstValue(for name: HTTPFieldName) -> ByteView? {
        withFieldStorage { index, _ in
            index.firstIndex(of: name).map { index.valueViews[$0] }
        }
    }

    /// Number of fields with the well-known `name`.
    @inlinable
    public func count(of name: HTTPFieldName) -> Int {
        withFieldStorage { index, _ in
            guard index.contains(name) else { return 0 }
            var n = 0
            for id in index.names where id == name { n &+= 1 }
            return n
        }
    }

    /// The value ranges of every field with the well-known `name`, in order (duplicates kept).
    @inlinable
    public func values(for name: HTTPFieldName) -> HTTPFieldValues {
        withFieldStorage { index, _ in HTTPFieldValues(index: index, name: name) }
    }

    /// The first value of `name` as a `String`, or `nil`. Allocates.
    @inlinable
    public func firstValueString(for name: HTTPFieldName) -> String? {
        firstValue(for: name).map { string(of: $0) }
    }

    /// True when the first value of `name` equals `literal` case-insensitively.
    @inlinable
    public func firstValue(for name: HTTPFieldName, equalsCaseInsensitive literal: StaticString) -> Bool {
        guard let view = firstValue(for: name) else { return false }
        return withSpan(of: view) { ASCII.equalsCaseInsensitive($0, literal) }
    }

    // MARK: Lookup by name bytes

    /// Position of the first field whose name equals `name` case-insensitively, or `nil`.
    ///
    /// A well-known `name` is resolved to its ID first and found by ID compare; any other name
    /// is compared byte by byte against the unknown fields only.
    @inlinable
    public func firstIndex(named name: Span<UInt8>) -> Int? {
        let id = HTTPFieldName.lookup(name)
        return withFieldStorage { index, arena in
            if id.isWellKnown { return index.firstIndex(of: id) }
            for i in 0..<index.count where index.names[i] == .unknown {
                let nameView = index.nameViews[i]
                guard nameView.length == name.count else { continue }
                let equal = arena.withSpan(of: nameView) { candidate in
                    for j in candidate.indices where ASCII.lowercased(candidate[j]) != ASCII.lowercased(name[j]) {
                        return false
                    }
                    return true
                }
                if equal { return i }
            }
            return nil
        }
    }

    /// Position of the first field whose name equals `name` case-insensitively, or `nil`.
    @inlinable
    public func firstIndex(named name: StaticString) -> Int? {
        name.withUTF8Buffer { firstIndex(named: $0.span) }
    }

    /// The value range of the first field named `name` (any case), or `nil`.
    @inlinable
    public func firstValue(named name: StaticString) -> ByteView? {
        guard let i = firstIndex(named: name) else { return nil }
        return self[i].valueView
    }

    // MARK: List-valued fields (RFC 9110 §5.6.1)

    /// Calls `body` with each element of the comma-separated lists in every field with the
    /// well-known `name`, in order. Elements are trimmed of optional whitespace, empty
    /// elements are skipped, and commas inside quoted strings do not split.
    @inlinable
    public func forEachListElement(of name: HTTPFieldName, _ body: (ByteView) -> Void) {
        _ = forEachListElementWhile(of: name) { body($0); return true }
    }

    /// True when any list element of `name` equals `token` case-insensitively, for fields
    /// such as `Connection: close`, `Transfer-Encoding: chunked` or `Upgrade: websocket`.
    @inlinable
    public func containsListElement(_ token: StaticString, in name: HTTPFieldName) -> Bool {
        withFieldStorage { _, arena in
            !forEachListElementWhile(of: name) { element in
                !arena.withSpan(of: element) { ASCII.equalsCaseInsensitive($0, token) }
            }
        }
    }

    /// The last list element of `name` (for `Transfer-Encoding`, where the final coding
    /// decides framing), or `nil`.
    @inlinable
    public func lastListElement(of name: HTTPFieldName) -> ByteView? {
        var last: ByteView?
        forEachListElement(of: name) { last = $0 }
        return last
    }

    /// Iterates list elements until `body` returns `false`; returns `false` if stopped early.
    @inlinable
    func forEachListElementWhile(of name: HTTPFieldName, _ body: (ByteView) -> Bool) -> Bool {
        withFieldStorage { index, arena in
            var position = 0
            while let i = index.firstIndex(of: name, from: position) {
                let keepGoing = HTTPFieldListSplitter.forEachElement(of: index.valueViews[i], in: arena, body)
                if !keepGoing { return false }
                position = i &+ 1
            }
            return true
        }
    }

    /// Appends the values of every field with `name` to `output`, joined by `separator`
    /// (RFC 9110 §5.3; use `"; "` for `cookie` crumbs, RFC 9113 §8.2.3).
    ///
    /// - Returns: The number of fields joined.
    @inlinable
    @discardableResult
    public func combinedValue(for name: HTTPFieldName, separator: StaticString = ", ", into output: inout ByteBuffer) -> Int {
        withFieldStorage { index, arena in
            var joined = 0
            var position = 0
            while let i = index.firstIndex(of: name, from: position) {
                if joined > 0 { output.append(separator) }
                output.append(index.valueViews[i], from: arena)
                joined &+= 1
                position = i &+ 1
            }
            return joined
        }
    }

    // MARK: Framing

    /// Reads every `Content-Length` field and list element.
    ///
    /// Identical repeated values are accepted as one value (RFC 9110 §8.6); differing values
    /// return ``HTTPContentLength/conflicting`` so the parser can answer 400 (#0021).
    @inlinable
    public func contentLength() -> HTTPContentLength {
        withFieldStorage { index, arena in
            guard index.contains(.contentLength) else { return .absent }
            var result: UInt64?
            var invalid = false
            var conflicting = false
            var position = 0
            while let i = index.firstIndex(of: .contentLength, from: position) {
                var sawElement = false
                _ = HTTPFieldListSplitter.forEachElement(of: index.valueViews[i], in: arena) { element in
                    sawElement = true
                    guard let value = element.decimalValue(in: arena) else {
                        invalid = true
                        return false
                    }
                    if let previous = result, previous != value { conflicting = true }
                    result = value
                    return true
                }
                if !sawElement || invalid { return .invalid }
                position = i &+ 1
            }
            if conflicting { return .conflicting }
            return result.map { .value($0) } ?? .invalid
        }
    }
}

/// The value ranges of every field with one well-known name, in field order.
public struct HTTPFieldValues: Sequence, Sendable {
    @usableFromInline let index: HTTPFieldIndex
    @usableFromInline let name: HTTPFieldName

    @inlinable
    init(index: HTTPFieldIndex, name: HTTPFieldName) {
        self.index = index
        self.name = name
    }

    public struct Iterator: IteratorProtocol, Sendable {
        @usableFromInline let index: HTTPFieldIndex
        @usableFromInline let name: HTTPFieldName
        @usableFromInline var position: Int

        @inlinable
        init(index: HTTPFieldIndex, name: HTTPFieldName) {
            self.index = index
            self.name = name
            position = 0
        }

        @inlinable
        public mutating func next() -> ByteView? {
            guard let i = index.firstIndex(of: name, from: position) else {
                position = index.count
                return nil
            }
            position = i &+ 1
            return index.valueViews[i]
        }
    }

    @inlinable
    public func makeIterator() -> Iterator {
        Iterator(index: index, name: name)
    }
}

/// Splits a field value into list elements (RFC 9110 §5.6.1).
@usableFromInline
enum HTTPFieldListSplitter {
    /// Calls `body` with each non-empty, OWS-trimmed element of `value`; stops and returns
    /// `false` when `body` does. Commas inside a quoted string (with `\` escapes) do not split.
    @inlinable
    static func forEachElement(of value: ByteView, in arena: ByteBuffer, _ body: (ByteView) -> Bool) -> Bool {
        let count = value.length
        // Find element boundaries while borrowing the bytes, then call body outside the span
        // closure so body may read the arena itself.
        var start = 0
        while start <= count {
            let (end, trimmedStart, trimmedEnd) = arena.withSpan(of: value) { bytes -> (Int, Int, Int) in
                var i = start
                var quoted = false
                while i < count {
                    let byte = bytes[i]
                    if quoted {
                        if byte == UInt8(ascii: "\\") {
                            i &+= 1
                        } else if byte == UInt8(ascii: "\"") {
                            quoted = false
                        }
                    } else if byte == UInt8(ascii: "\"") {
                        quoted = true
                    } else if byte == UInt8(ascii: ",") {
                        break
                    }
                    i &+= 1
                }
                let end = Swift.min(i, count)
                var lo = start
                var hi = end
                while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 { lo &+= 1 }
                while hi > lo, bytes[hi &- 1] == 0x20 || bytes[hi &- 1] == 0x09 { hi &-= 1 }
                return (end, lo, hi)
            }
            if trimmedEnd > trimmedStart {
                if !body(value.subview(trimmedStart..<trimmedEnd)) { return false }
            }
            start = end &+ 1
        }
        return true
    }
}
