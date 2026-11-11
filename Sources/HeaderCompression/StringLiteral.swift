/// String literals (RFC 7541 §5.2; RFC 9204 §4.1.2): an H flag, a prefix-integer length, then
/// the string as raw octets (H = 0) or Huffman-coded (H = 1).
///
/// The H flag is the bit immediately above the length prefix: bit 7 of the first byte for
/// HPACK's 7-bit prefix, lower for QPACK's 3- and 5-bit prefixes. Bits above H are flags that
/// belong to the enclosing representation.
public enum StringLiteral {
    /// When ``encode(_:prefixBits:flags:huffman:into:)`` Huffman-codes the string.
    public enum HuffmanPolicy: Sendable {
        /// Huffman-code only when that is strictly shorter (the usual encoder choice).
        case whenShorter
        /// Always Huffman-code.
        case always
        /// Never Huffman-code.
        case never
    }

    /// Outcome of a successful ``decode(_:prefixBits:maxLength:into:)``.
    public enum DecodeResult: Equatable, Sendable {
        /// The string was appended to the sink; the literal occupied `consumed` bytes.
        case decoded(consumed: Int)
        /// The input ends before the literal does; nothing was appended.
        case needsMoreData
    }

    /// The H flag for a length with an `prefixBits`-bit prefix.
    @inlinable
    public static func huffmanFlag(prefixBits: Int) -> UInt8 {
        precondition((1...7).contains(prefixBits), "string literal prefixBits must be 1...7")
        return UInt8(truncatingIfNeeded: 1 << prefixBits)
    }

    /// The bytes the literal occupies when encoded under `huffman`.
    @inlinable
    public static func encodedLength(
        _ string: UnsafeRawBufferPointer, prefixBits: Int, huffman: HuffmanPolicy = .whenShorter
    ) -> Int {
        let length = payloadLength(string, huffman: huffman).length
        return PrefixInteger.encodedLength(UInt64(length), prefixBits: prefixBits) + length
    }

    /// Appends `string` as a literal with an `prefixBits`-bit length prefix (1...7). `flags`
    /// supplies the bits above the H flag; bits at or below it are ignored.
    @inlinable
    public static func encode<Sink: ByteSink>(
        _ string: UnsafeRawBufferPointer, prefixBits: Int, flags: UInt8 = 0,
        huffman: HuffmanPolicy = .whenShorter, into sink: inout Sink
    ) {
        let h = huffmanFlag(prefixBits: prefixBits)
        let (length, useHuffman) = payloadLength(string, huffman: huffman)
        let firstFlags = (flags & ~(h | (h &- 1))) | (useHuffman ? h : 0)
        sink.reserveAdditionalCapacity(
            PrefixInteger.encodedLength(UInt64(length), prefixBits: prefixBits) + length)
        PrefixInteger.encode(UInt64(length), prefixBits: prefixBits, flags: firstFlags, into: &sink)
        if useHuffman {
            Huffman.encode(string, into: &sink)
        } else {
            for byte in string { sink.append(byte) }
        }
    }

    /// Decodes a literal whose first byte is `bytes[0]` and appends the string to `sink`.
    ///
    /// - Parameters:
    ///   - maxLength: the largest encoded string length accepted, in bytes; longer literals
    ///     throw ``HeaderCompressionError/stringTooLong`` before any input is waited for.
    ///     A Huffman-coded string decodes to at most 8/5 of this.
    /// - Throws: ``HeaderCompressionError``. On a Huffman error `sink` may hold a partial string.
    @inlinable
    public static func decode<Sink: ByteSink>(
        _ bytes: UnsafeRawBufferPointer, prefixBits: Int, maxLength: Int,
        into sink: inout Sink
    ) throws(HeaderCompressionError) -> DecodeResult {
        let h = huffmanFlag(prefixBits: prefixBits)
        let length: UInt64
        let headerLength: Int
        switch PrefixInteger.decode(bytes, prefixBits: prefixBits) {
        case .needsMoreData:
            return .needsMoreData
        case .overflow:
            throw .integerOverflow
        case .value(let value, let consumed):
            length = value
            headerLength = consumed
        }
        guard length <= UInt64(maxLength) else { throw .stringTooLong }
        let end = headerLength + Int(length)
        guard end <= bytes.count else { return .needsMoreData }
        let payload = UnsafeRawBufferPointer(rebasing: bytes[headerLength..<end])
        if bytes[0] & h != 0 {
            try Huffman.decode(payload, into: &sink)
        } else {
            sink.reserveAdditionalCapacity(payload.count)
            for byte in payload { sink.append(byte) }
        }
        return .decoded(consumed: end)
    }

    @inlinable
    static func payloadLength(
        _ string: UnsafeRawBufferPointer, huffman: HuffmanPolicy
    ) -> (length: Int, huffman: Bool) {
        switch huffman {
        case .never:
            return (string.count, false)
        case .always:
            return (Huffman.encodedLength(string), true)
        case .whenShorter:
            let coded = Huffman.encodedLength(string)
            return coded < string.count ? (coded, true) : (string.count, false)
        }
    }
}
