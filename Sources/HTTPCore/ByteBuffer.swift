/// A growable byte buffer with separate read and write positions.
///
/// `ByteBuffer` is the per-connection reusable buffer (docs/ROADMAP.md §5.3, §7). Bytes are
/// appended at `writerIndex` and consumed from `readerIndex`; consuming bytes only moves an
/// index and never copies the remaining bytes to the front. `discardReadBytes()` reclaims the
/// consumed prefix when doing so is cheap.
///
/// Layout invariant: `0 <= readerIndex <= writerIndex <= capacity`.
///
/// ## Value semantics
///
/// `ByteBuffer` is a copy-on-write value type, so it can be stored in `HTTPRequestBody`
/// sequences and sent across tasks (it is `Sendable`). A copy shares storage until either copy
/// is mutated. On a non-hot path a copy costs one allocation and one `memcpy`.
///
/// ## Index stability
///
/// Indices are absolute positions in the storage. Growth and copy-on-write keep every byte in
/// `0..<writerIndex` at the same index, so a ``ByteView`` taken from a buffer stays valid while
/// more bytes are appended (for example, request body bytes read while a handler runs). Only
/// ``discardReadBytes()`` and ``clear(keepingCapacity:)`` move bytes or invalidate views; call
/// them at safe points, such as between requests.
///
/// ## Unsafe code
///
/// All pointer manipulation in `HTTPCore` lives in this file and `ByteBuffer+Writer.swift`.
/// Everything else reads bytes through `Span<UInt8>` / `RawSpan` closures, which are
/// bounds-checked.
public struct ByteBuffer: Sendable {
    /// Heap storage. Mutated only while uniquely referenced (checked by
    /// `isKnownUniquelyReferenced`), which is what makes the `@unchecked Sendable` sound.
    @usableFromInline
    final class Storage: @unchecked Sendable {
        @usableFromInline let bytes: UnsafeMutablePointer<UInt8>
        @usableFromInline let capacity: Int

        @usableFromInline
        init(capacity: Int) {
            precondition(capacity >= 0, "ByteBuffer capacity must not be negative")
            self.capacity = capacity
            self.bytes = .allocate(capacity: Swift.max(capacity, 1))
        }

        deinit {
            bytes.deallocate()
        }

        /// Shared zero-capacity storage so that `ByteBuffer()` does not allocate.
        @usableFromInline static let empty = Storage(capacity: 0)
    }

    /// Smallest capacity allocated when a buffer first grows.
    @usableFromInline static let minimumGrowthCapacity = 64

    @usableFromInline var storage: Storage
    @usableFromInline var _readerIndex: Int
    @usableFromInline var _writerIndex: Int

    // MARK: Initialization

    /// Creates an empty buffer without allocating.
    @inlinable
    public init() {
        storage = .empty
        _readerIndex = 0
        _writerIndex = 0
    }

    /// Creates an empty buffer with room for at least `capacity` bytes.
    @inlinable
    public init(capacity: Int) {
        storage = capacity == 0 ? .empty : Storage(capacity: capacity)
        _readerIndex = 0
        _writerIndex = 0
    }

    /// Creates a buffer whose readable bytes are the UTF-8 bytes of `literal`.
    @inlinable
    public init(_ literal: StaticString) {
        self.init(capacity: literal.utf8CodeUnitCount)
        append(literal)
    }

    /// Creates a buffer whose readable bytes are `bytes`.
    @inlinable
    public init(bytes: some Sequence<UInt8>) {
        self.init()
        append(contentsOf: bytes)
    }

    // MARK: Indices and sizes

    /// Index of the first readable byte.
    @inlinable public var readerIndex: Int { _readerIndex }

    /// Index one past the last readable byte; new bytes are written here.
    @inlinable public var writerIndex: Int { _writerIndex }

    /// Number of bytes the storage can hold without growing.
    @inlinable public var capacity: Int { storage.capacity }

    /// Number of bytes between `readerIndex` and `writerIndex`.
    @inlinable public var readableBytes: Int { _writerIndex &- _readerIndex }

    /// Number of bytes that can be written after `writerIndex` without growing.
    @inlinable public var writableBytes: Int { storage.capacity &- _writerIndex }

    /// True when there are no readable bytes.
    @inlinable public var isEmpty: Bool { _writerIndex == _readerIndex }

    /// A view of the readable bytes.
    @inlinable public var readableView: ByteView {
        ByteView(offset: _readerIndex, length: readableBytes)
    }

    @inlinable
    func assertInvariants() {
        assert(_readerIndex >= 0 && _readerIndex <= _writerIndex && _writerIndex <= storage.capacity,
               "ByteBuffer invariant violated: reader \(_readerIndex) writer \(_writerIndex) capacity \(storage.capacity)")
    }

    // MARK: Capacity

    /// Ensures the buffer is uniquely owned and that at least `minimumWritableBytes` bytes can be
    /// written without further allocation.
    ///
    /// Growth is geometric (at least doubling), so repeated reservations and appends are
    /// amortized O(1) per byte.
    @inlinable
    public mutating func reserveCapacity(minimumWritableBytes: Int) {
        prepareForWriting(minimumWritableBytes)
    }

    /// Makes the storage unique and ensures `minimumWritable` bytes after `writerIndex`.
    @inlinable
    mutating func prepareForWriting(_ minimumWritable: Int) {
        if _fastPath(isKnownUniquelyReferenced(&storage) && storage.capacity &- _writerIndex >= minimumWritable) {
            return
        }
        reallocate(minimumWritable: minimumWritable)
    }

    /// Slow path: grows and/or unshares the storage, keeping every byte in `0..<writerIndex` at
    /// the same index (see "Index stability").
    @usableFromInline
    mutating func reallocate(minimumWritable: Int) {
        precondition(minimumWritable >= 0, "minimumWritableBytes must not be negative")
        let (required, overflow) = _writerIndex.addingReportingOverflow(minimumWritable)
        precondition(!overflow, "ByteBuffer capacity overflow")
        let old = storage
        var newCapacity = old.capacity
        if required > newCapacity {
            let doubled = old.capacity <= Int.max / 2 ? old.capacity * 2 : Int.max
            newCapacity = Swift.max(required, doubled, Self.minimumGrowthCapacity)
        }
        let new = Storage(capacity: newCapacity)
        // Bytes before readerIndex are copied too so that views into consumed bytes (a request
        // head the reader has moved past) stay valid. The copy is bounded by the old capacity,
        // so growth stays amortized O(1) per byte.
        if _writerIndex > 0 {
            new.bytes.initialize(from: old.bytes, count: _writerIndex)
        }
        storage = new
        assertInvariants()
    }

    // MARK: Appending

    /// Appends one byte.
    @inlinable
    public mutating func append(_ byte: UInt8) {
        prepareForWriting(1)
        storage.bytes[_writerIndex] = byte
        _writerIndex &+= 1
    }

    /// Appends the UTF-8 bytes of a static string.
    @inlinable
    public mutating func append(_ literal: StaticString) {
        literal.withUTF8Buffer { appendBytes($0) }
    }

    /// Appends the readable bytes of another buffer.
    @inlinable
    public mutating func append(_ other: ByteBuffer) {
        other.withUnsafeReadableBytes { appendBytes($0.assumingMemoryBound(to: UInt8.self)) }
    }

    /// Appends the bytes of a span.
    @inlinable
    public mutating func append(contentsOf bytes: Span<UInt8>) {
        bytes.withUnsafeBufferPointer { appendBytes($0) }
    }

    /// Appends the bytes of a raw span.
    @inlinable
    public mutating func append(contentsOf bytes: RawSpan) {
        bytes.withUnsafeBytes { appendBytes($0.assumingMemoryBound(to: UInt8.self)) }
    }

    /// Appends a sequence of bytes, copying in one step when the sequence has contiguous storage.
    @inlinable
    public mutating func append(contentsOf bytes: some Sequence<UInt8>) {
        let copied: Void? = bytes.withContiguousStorageIfAvailable { appendBytes($0) }
        if copied != nil { return }
        prepareForWriting(bytes.underestimatedCount)
        for byte in bytes {
            append(byte)
        }
    }

    /// Appends the bytes in `view` of `source` (which may be this buffer's own contents).
    @inlinable
    public mutating func append(_ view: ByteView, from source: ByteBuffer) {
        source.withUnsafeBytes(of: view) { appendBytes($0.assumingMemoryBound(to: UInt8.self)) }
    }

    @inlinable
    mutating func appendBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        let count = bytes.count
        guard count > 0, let source = bytes.baseAddress else { return }
        prepareForWriting(count)
        // `source` may point into this buffer's old storage when appending a buffer to itself;
        // prepareForWriting keeps the old storage alive through `bytes`' owner, and the
        // destination range starts at writerIndex, past every readable byte, so it cannot overlap.
        (storage.bytes + _writerIndex).update(from: source, count: count)
        _writerIndex &+= count
        assertInvariants()
    }

    /// Appends `value` as ASCII decimal digits, with a leading `-` for negative values.
    /// No `String` is created.
    @inlinable
    public mutating func append<T: FixedWidthInteger>(decimal value: T) {
        precondition(T.bitWidth <= 64, "append(decimal:) supports integers up to 64 bits")
        if value < 0 {
            append(UInt8(ascii: "-"))
            appendDecimalMagnitude(UInt64(truncatingIfNeeded: value.magnitude))
        } else {
            appendDecimalMagnitude(UInt64(truncatingIfNeeded: value))
        }
    }

    @inlinable
    mutating func appendDecimalMagnitude(_ value: UInt64) {
        let digits = ASCII.decimalDigitCount(value)
        prepareForWriting(digits)
        var remaining = value
        var position = _writerIndex &+ digits
        let base = storage.bytes
        repeat {
            position &-= 1
            let (quotient, digit) = remaining.quotientAndRemainder(dividingBy: 10)
            base[position] = 0x30 &+ UInt8(truncatingIfNeeded: digit)
            remaining = quotient
        } while remaining != 0
        assert(position == _writerIndex)
        _writerIndex &+= digits
        assertInvariants()
    }

    /// Appends `value` as lowercase hexadecimal digits without a prefix (`0` for zero), as used
    /// for chunk sizes.
    @inlinable
    public mutating func append(hex value: UInt64) {
        let digits = ASCII.hexDigitCount(value)
        prepareForWriting(digits)
        var remaining = value
        var position = _writerIndex &+ digits
        let base = storage.bytes
        repeat {
            position &-= 1
            base[position] = ASCII.lowercaseHexDigit(UInt8(truncatingIfNeeded: remaining & 0xF))
            remaining >>= 4
        } while remaining != 0
        assert(position == _writerIndex)
        _writerIndex &+= digits
        assertInvariants()
    }

    // MARK: Integers in network byte order

    /// Appends `value` in network (big-endian) byte order, as used by HTTP/2 and HTTP/3 framing.
    @inlinable
    public mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        let size = MemoryLayout<T>.size
        prepareForWriting(size)
        UnsafeMutableRawPointer(storage.bytes + _writerIndex).storeBytes(of: value.bigEndian, as: T.self)
        _writerIndex &+= size
        assertInvariants()
    }

    /// The big-endian integer at absolute index `index` without moving `readerIndex`, or `nil`
    /// if fewer than `MemoryLayout<T>.size` bytes are written there.
    @inlinable
    public func getInteger<T: FixedWidthInteger>(at index: Int, as type: T.Type = T.self) -> T? {
        let size = MemoryLayout<T>.size
        guard index >= 0, index <= _writerIndex &- size else { return nil }
        let raw = UnsafeRawPointer(storage.bytes + index).loadUnaligned(as: T.self)
        return T(bigEndian: raw)
    }

    /// Reads a big-endian integer at `readerIndex` and consumes it, or returns `nil` without
    /// consuming anything if fewer than `MemoryLayout<T>.size` bytes are readable.
    @inlinable
    public mutating func readInteger<T: FixedWidthInteger>(as type: T.Type = T.self) -> T? {
        guard let value = getInteger(at: _readerIndex, as: T.self) else { return nil }
        _readerIndex &+= MemoryLayout<T>.size
        return value
    }

    // MARK: Reading

    /// Calls `body` with a pointer to the readable bytes. The pointer must not escape `body`.
    @inlinable
    public func withUnsafeReadableBytes<R, E: Error>(
        _ body: (UnsafeRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        try body(UnsafeRawBufferPointer(start: storage.bytes + _readerIndex, count: readableBytes))
    }

    /// Calls `body` with a bounds-checked span of the readable bytes.
    @inlinable
    public func withReadableSpan<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        let buffer = UnsafeBufferPointer(start: storage.bytes + _readerIndex, count: readableBytes)
        return try body(buffer.span)
    }

    /// Calls `body` with a bounds-checked raw span of the readable bytes.
    @inlinable
    public func withReadableRawSpan<R, E: Error>(_ body: (RawSpan) throws(E) -> R) throws(E) -> R {
        let buffer = UnsafeRawBufferPointer(start: storage.bytes + _readerIndex, count: readableBytes)
        return try body(buffer.bytes)
    }

    /// Calls `body` with a bounds-checked span of the bytes in `view`.
    ///
    /// `view` may cover bytes before `readerIndex` (already consumed but not discarded); it must
    /// end at or before `writerIndex`.
    @inlinable
    public func withSpan<R, E: Error>(of view: ByteView, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        checkView(view)
        let buffer = UnsafeBufferPointer(start: storage.bytes + view.offset, count: view.length)
        return try body(buffer.span)
    }

    @inlinable
    func withUnsafeBytes<R, E: Error>(of view: ByteView, _ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
        checkView(view)
        return try body(UnsafeRawBufferPointer(start: storage.bytes + view.offset, count: view.length))
    }

    @inlinable
    func checkView(_ view: ByteView) {
        precondition(view.offset >= 0 && view.length >= 0 && view.offset <= _writerIndex &- view.length,
                     "ByteView \(view.offset)+\(view.length) is outside written bytes 0..<\(_writerIndex)")
    }

    /// The byte at absolute index `index`, which must be in `0..<writerIndex`.
    @inlinable
    public func byte(at index: Int) -> UInt8 {
        precondition(index >= 0 && index < _writerIndex, "ByteBuffer index \(index) out of range 0..<\(_writerIndex)")
        return storage.bytes[index]
    }

    // MARK: Consuming

    /// Marks `count` readable bytes as consumed.
    @inlinable
    public mutating func moveReaderIndex(forwardBy count: Int) {
        precondition(count >= 0 && count <= readableBytes,
                     "moveReaderIndex(forwardBy: \(count)) with \(readableBytes) readable bytes")
        _readerIndex &+= count
    }

    /// Sets `readerIndex` to an absolute index in `0...writerIndex` (moving backwards re-reads bytes).
    @inlinable
    public mutating func moveReaderIndex(to index: Int) {
        precondition(index >= 0 && index <= _writerIndex,
                     "moveReaderIndex(to: \(index)) outside 0...\(_writerIndex)")
        _readerIndex = index
    }

    /// Reclaims the consumed prefix when it is worth it, and returns whether indices changed.
    ///
    /// - When every byte has been read, both indices reset to zero (no copy).
    /// - Otherwise the readable bytes are moved to the front only if they are no larger than the
    ///   consumed prefix, so the copy never exceeds the space it frees (amortized O(1) per byte)
    ///   and source and destination never overlap.
    ///
    /// When this returns `true`, every ``ByteView`` taken from this buffer is invalid.
    @inlinable
    @discardableResult
    public mutating func discardReadBytes() -> Bool {
        guard _readerIndex > 0 else { return false }
        let readable = readableBytes
        if readable == 0 {
            _readerIndex = 0
            _writerIndex = 0
            return true
        }
        guard readable <= _readerIndex else { return false }
        if isKnownUniquelyReferenced(&storage) {
            storage.bytes.update(from: storage.bytes + _readerIndex, count: readable)
        } else {
            let new = Storage(capacity: storage.capacity)
            new.bytes.initialize(from: storage.bytes + _readerIndex, count: readable)
            storage = new
        }
        _readerIndex = 0
        _writerIndex = readable
        assertInvariants()
        return true
    }

    /// Removes all bytes. With `keepingCapacity` (the default) the storage is reused, which is
    /// how a connection recycles its buffer; otherwise the storage is released.
    @inlinable
    public mutating func clear(keepingCapacity: Bool = true) {
        if !keepingCapacity {
            storage = .empty
        }
        // When the storage is shared, the next write unshares it at the same capacity and,
        // with writerIndex at zero, copies nothing.
        _readerIndex = 0
        _writerIndex = 0
    }

    // MARK: Receiving into the tail

    /// Calls `body` with the writable tail (`writerIndex..<capacity`) so that bytes can be
    /// received directly into the buffer; then call ``commitWritten(_:)`` with the number of
    /// bytes written. The storage is made unique and grown to at least `minimumWritableBytes`
    /// first. The pointer must not escape `body`, and nothing else may mutate the buffer between
    /// `body` returning and the matching `commitWritten`.
    @inlinable
    public mutating func withUnsafeMutableWritableBytes<R, E: Error>(
        minimumWritableBytes: Int = 0,
        _ body: (UnsafeMutableRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        prepareForWriting(minimumWritableBytes)
        return try body(UnsafeMutableRawBufferPointer(start: storage.bytes + _writerIndex, count: writableBytes))
    }

    /// Makes `count` bytes written into the tail by ``withUnsafeMutableWritableBytes(minimumWritableBytes:_:)`` readable.
    @inlinable
    public mutating func commitWritten(_ count: Int) {
        precondition(count >= 0 && count <= writableBytes,
                     "commitWritten(\(count)) with \(writableBytes) writable bytes")
        _writerIndex &+= count
    }
}

extension ByteBuffer: Equatable {
    /// Two buffers are equal when their readable bytes are equal; indices and capacity are ignored.
    @inlinable
    public static func == (lhs: ByteBuffer, rhs: ByteBuffer) -> Bool {
        guard lhs.readableBytes == rhs.readableBytes else { return false }
        return lhs.withUnsafeReadableBytes { a in
            rhs.withUnsafeReadableBytes { b in a.elementsEqual(b) }
        }
    }
}

extension ByteBuffer: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ByteBuffer(readerIndex: \(_readerIndex), writerIndex: \(_writerIndex), capacity: \(capacity))"
    }
}

// MARK: - Pointer-backed ASCII helpers

extension ASCII {
    /// Decodes `bytes` as UTF-8, replacing invalid sequences with U+FFFD. Allocates; for
    /// edges such as logging and handler convenience, not the hot path.
    @inlinable
    public static func string(from bytes: Span<UInt8>) -> String {
        bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    }

    /// Calls `body` with a span of the UTF-8 bytes of `literal`.
    @inlinable
    static func withSpan<R>(of literal: StaticString, _ body: (Span<UInt8>) -> R) -> R {
        literal.withUTF8Buffer { body($0.span) }
    }
}
