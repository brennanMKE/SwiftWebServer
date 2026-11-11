public import HeaderCompression

/// The error from encoding a QUIC variable-length integer.
public enum QUICVarintError: Error, Equatable, Sendable {
    /// The value is 2^62 or more, so no varint form can hold it.
    case valueOutOfRange(UInt64)
}

/// QUIC variable-length integers (RFC 9000 §16).
///
/// The two high bits of the first byte give the encoded length (1, 2, 4 or 8 bytes). The
/// remaining 6, 14, 30 or 62 bits hold the value in network byte order. The encoder always
/// writes the shortest form. Decoders accept any form, as §16 requires.
public enum QUICVarint {
    /// The largest encodable value, 2^62 − 1.
    public static let maxValue: UInt64 = (1 << 62) - 1

    /// The outcome of ``decode(_:)``.
    public enum DecodeResult: Equatable, Sendable {
        /// The value and the number of bytes it took up.
        case value(UInt64, consumed: Int)
        /// The input ends before the integer does. Retry with more bytes.
        case needsMoreData
    }

    /// The encoded length implied by a first byte: 1, 2, 4 or 8.
    @inlinable
    public static func length(firstByte: UInt8) -> Int {
        1 << Int(firstByte >> 6)
    }

    /// The number of bytes the minimal encoding of `value` takes up, or `nil` when `value`
    /// is 2^62 or more.
    @inlinable
    public static func encodedLength(_ value: UInt64) -> Int? {
        if value < (1 << 6) { return 1 }
        if value < (1 << 14) { return 2 }
        if value < (1 << 30) { return 4 }
        if value <= maxValue { return 8 }
        return nil
    }

    /// Appends the minimal encoding of `value`.
    ///
    /// - Throws: ``QUICVarintError/valueOutOfRange(_:)`` when `value` is 2^62 or more.
    ///   Nothing is written in that case.
    @inlinable
    public static func encode<Sink: ByteSink>(
        _ value: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        guard let length = encodedLength(value) else { throw .valueOutOfRange(value) }
        write(value, length: length, into: &sink)
    }

    /// Appends `value` in exactly `length` bytes (1, 2, 4 or 8), which may be longer than the
    /// minimal form. A length field that is patched in after its payload is written uses this.
    ///
    /// - Throws: ``QUICVarintError/valueOutOfRange(_:)`` when `value` does not fit in
    ///   `length` bytes.
    @inlinable
    public static func encode<Sink: ByteSink>(
        _ value: UInt64, length: Int, into sink: inout Sink
    ) throws(QUICVarintError) {
        precondition(length == 1 || length == 2 || length == 4 || length == 8, "varint length must be 1, 2, 4 or 8")
        guard let minimal = encodedLength(value), minimal <= length else { throw .valueOutOfRange(value) }
        write(value, length: length, into: &sink)
    }

    @inlinable
    static func write<Sink: ByteSink>(_ value: UInt64, length: Int, into sink: inout Sink) {
        let prefix: UInt64
        switch length {
        case 1: prefix = 0
        case 2: prefix = 1
        case 4: prefix = 2
        default: prefix = 3
        }
        let tagged = value | (prefix << UInt64(length * 8 - 2))
        if length > 1 { sink.reserveAdditionalCapacity(length) }
        var shift = (length - 1) * 8
        while shift >= 0 {
            sink.append(UInt8(truncatingIfNeeded: tagged >> UInt64(shift)))
            shift -= 8
        }
    }

    /// Decodes a varint starting at `bytes[0]`.
    @inlinable
    public static func decode(_ bytes: UnsafeRawBufferPointer) -> DecodeResult {
        guard let first = bytes.first else { return .needsMoreData }
        let length = length(firstByte: first)
        guard bytes.count >= length else { return .needsMoreData }
        var value = UInt64(first & 0x3f)
        var index = 1
        while index < length {
            value = (value << 8) | UInt64(bytes[index])
            index += 1
        }
        return .value(value, consumed: length)
    }
}

/// An incremental varint decoder that keeps its progress across input chunks.
///
/// It is a value type with no I/O. Feed it bytes with ``parse(_:)`` until it returns
/// ``Result/value(_:consumed:)``, then ``reset()`` it (or make a new one) for the next integer.
public struct VarintParser: Sendable {
    /// The outcome of ``parse(_:)``.
    public enum Result: Equatable, Sendable {
        /// The integer is complete. `consumed` bytes of this call's input belong to it.
        case value(UInt64, consumed: Int)
        /// Every input byte was consumed and the integer is still incomplete.
        case needsMoreData
    }

    @usableFromInline var accumulated: UInt64 = 0
    /// Bytes still expected. Zero means the first byte has not arrived yet.
    @usableFromInline var remaining: Int = 0

    public init() {}

    /// Whether the parser holds part of an integer.
    @inlinable
    public var isMidValue: Bool { remaining != 0 }

    /// Clears any partial integer.
    @inlinable
    public mutating func reset() {
        accumulated = 0
        remaining = 0
    }

    /// Consumes bytes from the start of `input` up to the end of the integer.
    @inlinable
    public mutating func parse(_ input: UnsafeRawBufferPointer) -> Result {
        var index = 0
        if remaining == 0 {
            guard let first = input.first else { return .needsMoreData }
            let length = QUICVarint.length(firstByte: first)
            // Fast path: the whole integer is in this chunk.
            if input.count >= length {
                if case .value(let value, let consumed) = QUICVarint.decode(input) {
                    return .value(value, consumed: consumed)
                }
            }
            accumulated = UInt64(first & 0x3f)
            remaining = length - 1
            index = 1
        }
        while remaining > 0 {
            guard index < input.count else { return .needsMoreData }
            accumulated = (accumulated << 8) | UInt64(input[index])
            index += 1
            remaining -= 1
        }
        let value = accumulated
        accumulated = 0
        return .value(value, consumed: index)
    }
}
