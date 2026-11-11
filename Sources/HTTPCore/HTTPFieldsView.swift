/// Reusable per-connection storage that ``HTTPRequest`` and ``HTTPFieldsView`` borrow.
///
/// A connection creates one `HTTPRequestStorage`, parses each request head into ``buffer``
/// and ``fields``, hands the handler a request that points into it, and calls
/// ``endRequest()`` when the handler returns. Nothing is copied per request and, once the
/// arrays and buffer have grown to fit, nothing is allocated (docs/ROADMAP.md §5.2, §7).
///
/// ## Lifetime rule
///
/// A request and its header view are valid only until ``endRequest()``. Every access checks
/// the storage's generation against the one captured when the view was made and traps in
/// debug builds on a mismatch, which catches a handler that keeps a request after returning.
/// Use ``HTTPRequest/snapshot()`` or ``HTTPFieldsView/snapshot()`` to keep a copy.
///
/// ## Concurrency
///
/// The storage is mutated only by the connection task between requests, and read by the
/// handler while it runs on that same task tree; there is no concurrent mutation while a
/// view is valid, which is what makes the `@unchecked Sendable` sound. A handler must not
/// read a request from a task that outlives `handle(_:context:)`.
public final class HTTPRequestStorage: @unchecked Sendable {
    /// The arena holding the request head bytes; the ranges in ``fields`` and the request's
    /// path, query, scheme and authority point into it. The HTTP/1.1 connection can use it as
    /// its receive buffer directly.
    @exclusivity(unchecked) public var buffer: ByteBuffer
    /// The header index for the current request.
    @exclusivity(unchecked) public var fields: HTTPFieldIndex
    /// Incremented by ``endRequest()``; views made before that are invalid.
    @exclusivity(unchecked) public private(set) var generation: UInt64

    /// Creates storage with room for `fieldCapacity` fields and `bufferCapacity` bytes.
    public init(bufferCapacity: Int = 0, fieldCapacity: Int = 0) {
        buffer = ByteBuffer(capacity: bufferCapacity)
        fields = HTTPFieldIndex(minimumCapacity: fieldCapacity)
        generation = 0
    }

    /// A header view of the current request.
    @inlinable
    public var fieldsView: HTTPFieldsView {
        HTTPFieldsView(storage: self, generation: generation)
    }

    /// Appends a field the parser scanned, resolving its name ID from the precomputed
    /// lowercased FNV-1a `hash` (see ``HTTPFieldIndex/append(nameView:hash:valueView:in:)``).
    @inlinable
    @discardableResult
    public func appendField(nameView: ByteView, hash: UInt32, valueView: ByteView) -> HTTPFieldName {
        let name = buffer.withSpan(of: nameView) { HTTPFieldName.lookup(hash: hash, name: $0) }
        fields.append(name, nameView: nameView, valueView: valueView)
        return name
    }

    /// Ends the current request: every request and view handed out so far becomes invalid.
    /// Clears the field index (keeping capacity); the buffer is left to the connection.
    public func endRequest() {
        generation &+= 1
        fields.removeAll(keepingCapacity: true)
    }
}

/// Borrowed, ordered request header fields with duplicates kept: a view of the
/// ``HTTPRequestStorage`` of the connection that parsed the request.
///
/// All reads come from ``HTTPFieldCollection``. Copying a view copies a reference; it never
/// copies fields. See ``HTTPRequestStorage`` for the lifetime rule.
public struct HTTPFieldsView: Sendable, HTTPFieldCollection {
    @usableFromInline let storage: HTTPRequestStorage
    @usableFromInline let generation: UInt64

    @inlinable
    init(storage: HTTPRequestStorage, generation: UInt64) {
        self.storage = storage
        self.generation = generation
    }

    /// An empty view over fresh storage (allocates; for tests and synthetic requests).
    public init() {
        let storage = HTTPRequestStorage()
        self.init(storage: storage, generation: storage.generation)
    }

    /// True while the request this view belongs to is still being handled.
    @inlinable
    public var isValid: Bool { storage.generation == generation }

    @inlinable
    func checkValid() {
        assert(storage.generation == generation,
               "HTTPRequest or HTTPFieldsView used after the handler returned; call snapshot() to keep it")
    }

    @inlinable
    public func withFieldStorage<R, E: Error>(_ body: (HTTPFieldIndex, ByteBuffer) throws(E) -> R) throws(E) -> R {
        checkValid()
        return try body(storage.fields, storage.buffer)
    }

    // Fast paths for the most frequent lookups: they read the storage's index in place
    // instead of passing copies of its arrays to a closure, which saves the retains.

    /// True when a field with the well-known `name` is present. O(1).
    @inlinable
    public func contains(_ name: HTTPFieldName) -> Bool {
        checkValid()
        return storage.fields.contains(name)
    }

    /// The value range of the first field with the well-known `name`, or `nil`.
    @inlinable
    public func firstValue(for name: HTTPFieldName) -> ByteView? {
        checkValid()
        guard let i = storage.fields.firstIndex(of: name) else { return nil }
        return storage.fields.valueViews[i]
    }

    /// Copies the fields into owned ``HTTPFields`` that outlive the request.
    public func snapshot() -> HTTPFields {
        withFieldStorage { index, arena in
            var bytes = 0
            for i in 0..<index.count { bytes &+= index.nameViews[i].length &+ index.valueViews[i].length }
            var copy = HTTPFields(minimumCapacity: index.count, arenaCapacity: bytes)
            for i in 0..<index.count { copy.append(i, of: self) }
            return copy
        }
    }
}
