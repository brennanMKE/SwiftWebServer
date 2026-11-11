public import HeaderCompression

/// A QPACK failure, carrying the HTTP/3 error code to close the connection with (RFC 9204 §6)
/// and the specific reason.
public struct QPACKError: Error, Equatable, Sendable {
    /// The QPACK error codes registered for HTTP/3 (RFC 9204 §6).
    public enum Code: UInt64, Sendable {
        /// `QPACK_DECOMPRESSION_FAILED`: an encoded field section could not be interpreted.
        case decompressionFailed = 0x0200
        /// `QPACK_ENCODER_STREAM_ERROR`: the peer's encoder stream sent an invalid instruction.
        case encoderStreamError = 0x0201
        /// `QPACK_DECODER_STREAM_ERROR`: the peer's decoder stream sent an invalid instruction.
        case decoderStreamError = 0x0202
    }

    /// Why the input was rejected.
    public enum Reason: Equatable, Sendable {
        /// The field section prefix declares a non-zero Required Insert Count, but our
        /// dynamic table capacity is 0 so nothing can ever have been inserted.
        case requiredInsertCountNotZero
        /// The field section prefix has the Sign bit set, which makes Base negative (RFC 9204 §4.5.1.2).
        case negativeBase
        /// A field line references the dynamic table (relative or post-Base index).
        case dynamicTableReference
        /// A static table index is 99 or more.
        case staticIndexOutOfRange
        /// The input ends inside a prefix, field line or instruction.
        case truncated
        /// A prefix integer exceeds 2^62 − 1 or its encoding is overlong.
        case integerOverflow
        /// An instruction string literal is longer than the caller's limit.
        case stringTooLong
        /// A Huffman-coded string is invalid.
        case huffman(HeaderCompressionError)
        /// The decoded field section exceeds the configured maximum size (name + value + 32
        /// per field, RFC 9114 §4.2.2). The HTTP/3 layer may answer this with a 431 instead.
        case fieldSectionTooLarge
        /// Set Dynamic Table Capacity asks for more than the capacity we advertised (0).
        case tableCapacityExceeded
        /// An Insert instruction adds an entry that cannot fit in the dynamic table.
        case insertExceedsCapacity
        /// A Duplicate instruction references an entry that does not exist.
        case invalidDynamicIndex
        /// A Section Acknowledgment for a stream with no unacknowledged field section that
        /// references the dynamic table (we never send one).
        case unexpectedSectionAcknowledgment
        /// An Insert Count Increment of zero, or one beyond the inserts we sent (none).
        case invalidInsertCountIncrement
    }

    public var code: Code
    public var reason: Reason

    public init(_ code: Code, _ reason: Reason) {
        self.code = code
        self.reason = reason
    }

    @inlinable
    static func decompression(_ reason: Reason) -> QPACKError { QPACKError(.decompressionFailed, reason) }
}

/// Outcome of parsing one encoder or decoder stream instruction.
public enum QPACKInstructionParseResult<Instruction: Sendable>: Sendable {
    /// A complete instruction that occupied the first `consumed` bytes.
    case instruction(Instruction, consumed: Int)
    /// The input ends inside the instruction; offer it again with more bytes.
    case needsMoreData
}

extension QPACKInstructionParseResult: Equatable where Instruction: Equatable {}
