extension ByteBuffer {
    /// Reserves room once, then lets `body` append through a ``Writer`` that only compares
    /// against the reserved end on each write: no uniqueness check, no growth path.
    ///
    /// For serializers that write many small pieces (a response head is about 40), where the
    /// per-append bookkeeping of ``append(_:)-(StaticString)`` would dominate. Every write is
    /// still bounds-checked in release builds: writing past the buffer's capacity traps.
    ///
    /// The writer must not escape `body`. While `body` runs the buffer itself is exclusively
    /// accessed, so it cannot be read or appended to except through the writer.
    @inlinable
    public mutating func withWriter<R, E: Error>(
        reservingCapacity minimumWritableBytes: Int, _ body: (inout Writer) throws(E) -> R
    ) throws(E) -> R {
        prepareForWriting(minimumWritableBytes)
        var writer = Writer(base: storage.bytes, position: _writerIndex, limit: storage.capacity)
        defer {
            _writerIndex = writer.position
            assertInvariants()
        }
        return try body(&writer)
    }

    /// Appends to a ``ByteBuffer`` inside ``ByteBuffer/withWriter(reservingCapacity:_:)``.
    public struct Writer {
        @usableFromInline let base: UnsafeMutablePointer<UInt8>
        @usableFromInline var position: Int
        @usableFromInline let limit: Int

        @inlinable
        init(base: UnsafeMutablePointer<UInt8>, position: Int, limit: Int) {
            self.base = base
            self.position = position
            self.limit = limit
        }

        /// Bytes that can still be written.
        @inlinable public var writableBytes: Int { limit &- position }

        /// Claims `count` bytes and returns where they start.
        @inlinable
        mutating func claim(_ count: Int) -> UnsafeMutablePointer<UInt8> {
            precondition(count >= 0 && count <= limit &- position,
                         "ByteBuffer.Writer: writing \(count) bytes with \(limit &- position) reserved")
            let start = base + position
            position &+= count
            return start
        }

        /// Appends one byte.
        @inlinable
        public mutating func append(_ byte: UInt8) {
            claim(1).pointee = byte
        }

        /// Appends two bytes, such as CR LF or `: `.
        @inlinable
        public mutating func append(_ first: UInt8, _ second: UInt8) {
            let start = claim(2)
            start[0] = first
            start[1] = second
        }

        /// Appends the UTF-8 bytes of a static string.
        @inlinable
        public mutating func append(_ literal: StaticString) {
            literal.withUTF8Buffer { appendBytes($0) }
        }

        /// Appends the bytes in `view` of `source`.
        @inlinable
        public mutating func append(_ view: ByteView, from source: ByteBuffer) {
            source.withUnsafeBytes(of: view) { appendBytes($0.assumingMemoryBound(to: UInt8.self)) }
        }

        /// Appends the readable bytes of `other`.
        @inlinable
        public mutating func append(_ other: ByteBuffer) {
            other.withUnsafeReadableBytes { appendBytes($0.assumingMemoryBound(to: UInt8.self)) }
        }

        /// Appends the bytes of a span.
        @inlinable
        public mutating func append(contentsOf bytes: Span<UInt8>) {
            bytes.withUnsafeBufferPointer { appendBytes($0) }
        }

        /// Copies with inline overlapping word moves up to 32 bytes (header names and values are
        /// mostly shorter), avoiding a `memcpy` call per piece; longer copies use `memcpy`.
        /// Every load happens before any store, and sources never alias the writer's buffer
        /// (it is exclusively accessed while the writer exists).
        @inlinable
        mutating func appendBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
            let count = bytes.count
            guard count > 0, let source = bytes.baseAddress else { return }
            let destination = claim(count)
            let from = UnsafeRawPointer(source)
            let to = UnsafeMutableRawPointer(destination)
            if count >= 8 {
                if count <= 16 {
                    let head = from.loadUnaligned(as: UInt64.self)
                    let tail = from.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self)
                    to.storeBytes(of: head, as: UInt64.self)
                    to.storeBytes(of: tail, toByteOffset: count &- 8, as: UInt64.self)
                } else if count <= 32 {
                    let head0 = from.loadUnaligned(as: UInt64.self)
                    let head1 = from.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                    let tail0 = from.loadUnaligned(fromByteOffset: count &- 16, as: UInt64.self)
                    let tail1 = from.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self)
                    to.storeBytes(of: head0, as: UInt64.self)
                    to.storeBytes(of: head1, toByteOffset: 8, as: UInt64.self)
                    to.storeBytes(of: tail0, toByteOffset: count &- 16, as: UInt64.self)
                    to.storeBytes(of: tail1, toByteOffset: count &- 8, as: UInt64.self)
                } else {
                    destination.update(from: source, count: count)
                }
            } else if count >= 4 {
                let head = from.loadUnaligned(as: UInt32.self)
                let tail = from.loadUnaligned(fromByteOffset: count &- 4, as: UInt32.self)
                to.storeBytes(of: head, as: UInt32.self)
                to.storeBytes(of: tail, toByteOffset: count &- 4, as: UInt32.self)
            } else {
                let first = source[0]
                let middle = source[count >> 1]
                let last = source[count &- 1]
                destination[0] = first
                destination[count >> 1] = middle
                destination[count &- 1] = last
            }
        }

        /// Appends a non-negative integer as ASCII decimal digits.
        @inlinable
        public mutating func append(decimal value: Int) {
            precondition(value >= 0, "ByteBuffer.Writer.append(decimal:) takes a non-negative value")
            var remaining = UInt64(value)
            let digits = ASCII.decimalDigitCount(remaining)
            let start = claim(digits)
            var position = digits
            repeat {
                position &-= 1
                let (quotient, digit) = remaining.quotientAndRemainder(dividingBy: 10)
                start[position] = 0x30 &+ UInt8(truncatingIfNeeded: digit)
                remaining = quotient
            } while remaining != 0
        }

        /// Appends `value` (`0...99`) as exactly two decimal digits.
        @inlinable
        public mutating func append(twoDigits value: Int) {
            precondition(value >= 0 && value < 100, "append(twoDigits:) takes 0...99")
            let start = claim(2)
            start[0] = 0x30 &+ UInt8(truncatingIfNeeded: value / 10)
            start[1] = 0x30 &+ UInt8(truncatingIfNeeded: value % 10)
        }
    }
}
