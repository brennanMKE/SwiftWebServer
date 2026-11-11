import HeaderCompression

// Encoder and decoder stream instructions (RFC 9204 §4.3, §4.4). Pure parsing: the HTTP/3
// layer reads the unidirectional streams and offers the bytes here.

/// A string literal inside an encoder stream instruction, as a byte range of the parsed input.
public struct QPACKStringReference: Equatable, Sendable {
    /// Offset of the string's payload from the start of the instruction.
    public var offset: Int
    /// Encoded length in bytes.
    public var length: Int
    /// Whether the payload is Huffman-coded.
    public var isHuffman: Bool

    public init(offset: Int, length: Int, isHuffman: Bool) {
        self.offset = offset
        self.length = length
        self.isHuffman = isHuffman
    }
}

/// An instruction on the peer's encoder stream (RFC 9204 §4.3).
public enum QPACKEncoderInstruction: Equatable, Sendable {
    /// `001` Capacity(5+).
    case setDynamicTableCapacity(UInt64)
    /// `1 T` NameIndex(6+), then the value (7+). `isStatic` is the T bit.
    case insertWithNameReference(isStatic: Bool, nameIndex: UInt64, value: QPACKStringReference)
    /// `01 H` NameLength(5+), the name, then the value (7+).
    case insertWithLiteralName(name: QPACKStringReference, value: QPACKStringReference)
    /// `000` Index(5+).
    case duplicate(index: UInt64)

    /// Parses the instruction at the start of `bytes`, structurally only.
    ///
    /// - Parameter maxStringLength: string literals longer than this fail with
    ///   `.stringTooLong` before their bytes are waited for.
    /// - Throws: ``QPACKError`` with code `.encoderStreamError`.
    public static func parse(
        _ bytes: UnsafeRawBufferPointer, maxStringLength: Int = 64 * 1024
    ) throws(QPACKError) -> QPACKInstructionParseResult<QPACKEncoderInstruction> {
        guard let first = bytes.first else { return .needsMoreData }
        var reader = InstructionReader(bytes: bytes, error: .encoderStreamError)
        let instruction: QPACKEncoderInstruction
        if first & 0x80 != 0 {
            guard let index = try reader.integer(prefixBits: 6),
                let value = try reader.string(prefixBits: 7, maxLength: maxStringLength)
            else { return .needsMoreData }
            instruction = .insertWithNameReference(isStatic: first & 0x40 != 0, nameIndex: index, value: value)
        } else if first & 0x40 != 0 {
            guard let name = try reader.string(prefixBits: 5, maxLength: maxStringLength),
                let value = try reader.string(prefixBits: 7, maxLength: maxStringLength)
            else { return .needsMoreData }
            instruction = .insertWithLiteralName(name: name, value: value)
        } else if first & 0x20 != 0 {
            guard let capacity = try reader.integer(prefixBits: 5) else { return .needsMoreData }
            instruction = .setDynamicTableCapacity(capacity)
        } else {
            guard let index = try reader.integer(prefixBits: 5) else { return .needsMoreData }
            instruction = .duplicate(index: index)
        }
        return .instruction(instruction, consumed: reader.position)
    }
}

/// An instruction on the peer's decoder stream (RFC 9204 §4.4).
public enum QPACKDecoderInstruction: Equatable, Sendable {
    /// `1` StreamID(7+).
    case sectionAcknowledgment(streamID: UInt64)
    /// `01` StreamID(6+).
    case streamCancellation(streamID: UInt64)
    /// `00` Increment(6+).
    case insertCountIncrement(UInt64)

    /// Parses the instruction at the start of `bytes`, structurally only.
    ///
    /// - Throws: ``QPACKError`` with code `.decoderStreamError`.
    public static func parse(
        _ bytes: UnsafeRawBufferPointer
    ) throws(QPACKError) -> QPACKInstructionParseResult<QPACKDecoderInstruction> {
        guard let first = bytes.first else { return .needsMoreData }
        var reader = InstructionReader(bytes: bytes, error: .decoderStreamError)
        let instruction: QPACKDecoderInstruction
        if first & 0x80 != 0 {
            guard let id = try reader.integer(prefixBits: 7) else { return .needsMoreData }
            instruction = .sectionAcknowledgment(streamID: id)
        } else if first & 0x40 != 0 {
            guard let id = try reader.integer(prefixBits: 6) else { return .needsMoreData }
            instruction = .streamCancellation(streamID: id)
        } else {
            guard let increment = try reader.integer(prefixBits: 6) else { return .needsMoreData }
            instruction = .insertCountIncrement(increment)
        }
        return .instruction(instruction, consumed: reader.position)
    }
}

/// Validates the peer's encoder stream against our advertised
/// `SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0`.
///
/// The only legal instruction is Set Dynamic Table Capacity with capacity 0. Any other
/// instruction is `QPACK_ENCODER_STREAM_ERROR`: a capacity above 0 exceeds our maximum, no
/// insert fits in an empty-capacity table, and no entry exists to duplicate. Each is
/// rejected from its first byte, so a hostile stream never makes the caller buffer.
public struct QPACKEncoderStreamReader: Sendable {
    public init() {}

    /// Parses and validates the instruction at the start of `bytes`.
    ///
    /// Call repeatedly, dropping `consumed` bytes each time, until `.needsMoreData`.
    public mutating func next(
        _ bytes: UnsafeRawBufferPointer
    ) throws(QPACKError) -> QPACKInstructionParseResult<QPACKEncoderInstruction> {
        guard let first = bytes.first else { return .needsMoreData }
        if first & 0xC0 != 0 { throw QPACKError(.encoderStreamError, .insertExceedsCapacity) }
        guard first & 0x20 != 0 else { throw QPACKError(.encoderStreamError, .invalidDynamicIndex) }
        // Set Dynamic Table Capacity: any non-zero prefix bit means a capacity of at least 1.
        guard first & 0x1F == 0 else { throw QPACKError(.encoderStreamError, .tableCapacityExceeded) }
        return .instruction(.setDynamicTableCapacity(0), consumed: 1)
    }

    /// Validates every complete instruction in `bytes`.
    ///
    /// - Returns: the bytes consumed. With capacity 0 every legal instruction is one byte, so
    ///   this is always `bytes.count`.
    public mutating func consume(_ bytes: UnsafeRawBufferPointer) throws(QPACKError) -> Int {
        var position = 0
        while position < bytes.count {
            guard case .instruction(_, let consumed) = try next(
                UnsafeRawBufferPointer(rebasing: bytes[position...]))
            else { break }
            position += consumed
        }
        return position
    }
}

/// Validates the peer's decoder stream for an encoder that never references the dynamic table.
///
/// Stream Cancellation is legal (and reported, so the caller can log it). Section
/// Acknowledgment and Insert Count Increment are `QPACK_DECODER_STREAM_ERROR`: we never send a
/// field section with a non-zero Required Insert Count, and never insert (RFC 9204 §4.4.1, §4.4.3).
/// Both are rejected from their first byte.
public struct QPACKDecoderStreamReader: Sendable {
    public init() {}

    /// Parses and validates the instruction at the start of `bytes`.
    ///
    /// Call repeatedly, dropping `consumed` bytes each time, until `.needsMoreData`.
    public mutating func next(
        _ bytes: UnsafeRawBufferPointer
    ) throws(QPACKError) -> QPACKInstructionParseResult<QPACKDecoderInstruction> {
        guard let first = bytes.first else { return .needsMoreData }
        if first & 0x80 != 0 {
            throw QPACKError(.decoderStreamError, .unexpectedSectionAcknowledgment)
        }
        if first & 0x40 == 0 {
            throw QPACKError(.decoderStreamError, .invalidInsertCountIncrement)
        }
        return try QPACKDecoderInstruction.parse(bytes)
    }
}

/// Sequential reads over one instruction; `nil` means the input ended early.
struct InstructionReader {
    let bytes: UnsafeRawBufferPointer
    let error: QPACKError.Code
    var position = 0

    init(bytes: UnsafeRawBufferPointer, error: QPACKError.Code) {
        self.bytes = bytes
        self.error = error
    }

    mutating func integer(prefixBits: Int) throws(QPACKError) -> UInt64? {
        guard position < bytes.count else { return nil }
        switch PrefixInteger.decode(UnsafeRawBufferPointer(rebasing: bytes[position...]), prefixBits: prefixBits) {
        case .value(let value, let consumed):
            position += consumed
            return value
        case .needsMoreData:
            return nil
        case .overflow:
            throw QPACKError(error, .integerOverflow)
        }
    }

    mutating func string(prefixBits: Int, maxLength: Int) throws(QPACKError) -> QPACKStringReference? {
        guard position < bytes.count else { return nil }
        let huffman = bytes[position] & StringLiteral.huffmanFlag(prefixBits: prefixBits) != 0
        guard let length = try integer(prefixBits: prefixBits) else { return nil }
        guard length <= UInt64(maxLength) else { throw QPACKError(error, .stringTooLong) }
        guard Int(length) <= bytes.count - position else { return nil }
        let reference = QPACKStringReference(offset: position, length: Int(length), isHuffman: huffman)
        position += Int(length)
        return reference
    }
}
