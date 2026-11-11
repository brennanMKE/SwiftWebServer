/// Why encoded header data was rejected.
///
/// HPACK maps every case to `COMPRESSION_ERROR` (RFC 9113 §4.3); QPACK maps
/// every case to `QPACK_DECOMPRESSION_FAILED` (RFC 9204 §6).
public enum HeaderCompressionError: Error, Equatable, Sendable {
    /// A Huffman-coded string contains the EOS symbol (RFC 7541 §5.2).
    case endOfStringSymbol
    /// A Huffman-coded string's trailing padding is the EOS prefix but 8 bits or longer.
    case paddingTooLong
    /// A Huffman-coded string's trailing bits are not a prefix of EOS (they contain a zero bit).
    case invalidPadding
    /// A prefix integer exceeds its bound (RFC 7541 §5.1).
    case integerOverflow
    /// A string literal's length exceeds the caller's limit.
    case stringTooLong
}

/// The static Huffman code of HPACK (RFC 7541 §5.2, Appendix B), also used by QPACK.
public enum Huffman {
    /// The number of bytes ``encode(_:into:)`` writes for `input`.
    @inlinable
    public static func encodedLength(_ input: UnsafeRawBufferPointer) -> Int {
        huffmanCodeLengths.withUnsafeBufferPointer { lengths in
            var bits = 0
            for byte in input {
                bits &+= Int(lengths[Int(byte)])
            }
            return (bits &+ 7) >> 3
        }
    }

    /// Appends the Huffman coding of `input`, padded to a byte boundary with the EOS prefix.
    @inlinable
    public static func encode<Sink: ByteSink>(_ input: UnsafeRawBufferPointer, into sink: inout Sink) {
        sink.reserveAdditionalCapacity(encodedLength(input))
        huffmanCodes.withUnsafeBufferPointer { codes in
            huffmanCodeLengths.withUnsafeBufferPointer { lengths in
                // `bits` low bits of `accumulator` are pending output; bits above them are stale.
                // Codes are at most 30 bits and we flush at 32, so `bits` stays ≤ 61.
                var accumulator: UInt64 = 0
                var bits = 0
                for byte in input {
                    let length = Int(lengths[Int(byte)])
                    accumulator = (accumulator &<< UInt64(length)) | UInt64(codes[Int(byte)])
                    bits &+= length
                    if bits >= 32 {
                        bits &-= 32
                        let word = UInt32(truncatingIfNeeded: accumulator &>> UInt64(bits))
                        sink.append(UInt8(truncatingIfNeeded: word &>> 24))
                        sink.append(UInt8(truncatingIfNeeded: word &>> 16))
                        sink.append(UInt8(truncatingIfNeeded: word &>> 8))
                        sink.append(UInt8(truncatingIfNeeded: word))
                    }
                }
                let padding = (8 &- (bits & 7)) & 7
                accumulator = (accumulator &<< UInt64(padding)) | ((1 &<< UInt64(padding)) &- 1)
                bits &+= padding
                while bits > 0 {
                    bits &-= 8
                    sink.append(UInt8(truncatingIfNeeded: accumulator &>> UInt64(bits)))
                }
            }
        }
    }

    /// Appends the decoding of the Huffman-coded `input`.
    ///
    /// Decoding consumes a nibble per step through a precomputed 256-state × 16-entry table.
    /// Rejects EOS anywhere in the input, padding of 8 bits or more, and padding that is not
    /// all ones. On error, `sink` may hold a partial result.
    @inlinable
    public static func decode<Sink: ByteSink>(
        _ input: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(HeaderCompressionError) {
        // The shortest code is 5 bits, so the output is at most 8/5 of the input.
        sink.reserveAdditionalCapacity((input.count &* 8) / 5)
        let failure: HeaderCompressionError? = huffmanDecodeTable.withUnsafeBufferPointer { table in
            var state = 0
            var entry = HuffmanDecodeEntry.initial
            for byte in input {
                entry = table[(state &<< 4) | Int(byte &>> 4)]
                if entry & HuffmanDecodeEntry.failed != 0 { return .endOfStringSymbol }
                if entry & HuffmanDecodeEntry.emits != 0 {
                    sink.append(UInt8(truncatingIfNeeded: entry))
                }
                state = Int((entry &>> 8) & 0xFF)

                entry = table[(state &<< 4) | Int(byte & 0x0F)]
                if entry & HuffmanDecodeEntry.failed != 0 { return .endOfStringSymbol }
                if entry & HuffmanDecodeEntry.emits != 0 {
                    sink.append(UInt8(truncatingIfNeeded: entry))
                }
                state = Int((entry &>> 8) & 0xFF)
            }
            if entry & HuffmanDecodeEntry.accepting != 0 { return nil }
            return entry & HuffmanDecodeEntry.onesPrefix != 0 ? .paddingTooLong : .invalidPadding
        }
        if let failure { throw failure }
    }
}

/// Bit layout of a ``huffmanDecodeTable`` entry, indexed by `state << 4 | nibble`.
///
/// Bits 0–7: the emitted symbol. Bits 8–15: the next state (an internal node of the code tree;
/// 0 is the root). Flags above. At most one symbol completes per nibble because the shortest
/// code is 5 bits.
@usableFromInline
enum HuffmanDecodeEntry {
    /// A symbol completed; it is in bits 0–7.
    @usableFromInline static let emits: UInt32 = 1 << 16
    /// The nibble completed EOS.
    @usableFromInline static let failed: UInt32 = 1 << 17
    /// Input may end here: the bits since the last symbol are ≤ 7 ones.
    @usableFromInline static let accepting: UInt32 = 1 << 18
    /// The bits since the last symbol are all ones (an EOS prefix) of any length.
    @usableFromInline static let onesPrefix: UInt32 = 1 << 19
    /// The entry an empty input ends on: at the root, so accepting.
    @usableFromInline static let initial: UInt32 = accepting | onesPrefix
}

/// The nibble-at-a-time decoding state machine derived from the code table.
@usableFromInline
let huffmanDecodeTable: [UInt32] = buildHuffmanDecodeTable()

func buildHuffmanDecodeTable() -> [UInt32] {
    // Code tree: internal nodes are states; children >= 0 are internal, < 0 are leaf ~symbol.
    var children: [(Int, Int)] = [(0, 0)]
    var depth: [Int] = [0]
    var allOnes: [Bool] = [true]
    for symbol in 0...256 {
        let code = huffmanCodes[symbol]
        let length = Int(huffmanCodeLengths[symbol])
        var node = 0
        for position in stride(from: length - 1, through: 0, by: -1) {
            let bit = (code >> UInt32(position)) & 1
            if position == 0 {
                if bit == 0 { children[node].0 = ~symbol } else { children[node].1 = ~symbol }
                break
            }
            var next = bit == 0 ? children[node].0 : children[node].1
            if next == 0 {
                next = children.count
                children.append((0, 0))
                depth.append(depth[node] + 1)
                allOnes.append(allOnes[node] && bit == 1)
                if bit == 0 { children[node].0 = next } else { children[node].1 = next }
            }
            node = next
        }
    }
    precondition(children.count == 256, "RFC 7541 code tree has 256 internal nodes")

    var table = [UInt32](repeating: 0, count: 256 * 16)
    for state in 0..<256 {
        for nibble in 0..<16 {
            var node = state
            var entry: UInt32 = 0
            for position in stride(from: 3, through: 0, by: -1) {
                let bit = (nibble >> position) & 1
                let child = bit == 0 ? children[node].0 : children[node].1
                if child >= 0 {
                    node = child
                    continue
                }
                let symbol = ~child
                if symbol == 256 {
                    entry |= HuffmanDecodeEntry.failed
                    break
                }
                precondition(entry & HuffmanDecodeEntry.emits == 0, "two symbols in one nibble")
                entry |= HuffmanDecodeEntry.emits | UInt32(symbol)
                node = 0
            }
            entry |= UInt32(node) << 8
            if allOnes[node] {
                entry |= HuffmanDecodeEntry.onesPrefix
                if depth[node] <= 7 { entry |= HuffmanDecodeEntry.accepting }
            }
            table[state << 4 | nibble] = entry
        }
    }
    return table
}
