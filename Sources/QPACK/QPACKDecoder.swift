public import HeaderCompression

/// Receives the fields of a decoded field section, in order.
///
/// The buffers are valid only for the duration of the call: they point into the encoded
/// section, the static table, or the decoder's reused scratch storage.
public protocol QPACKFieldSink {
    mutating func field(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool)
}

/// Decodes field sections for a connection that advertised
/// `SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0` (RFC 9204 §4.5).
///
/// Any reference to the dynamic table, and any non-zero Required Insert Count, is
/// `QPACK_DECOMPRESSION_FAILED`: with capacity 0 the table is always empty. Because nothing
/// can block, a field section decodes in one pass over the complete HEADERS frame payload.
///
/// Raw strings and static entries reach the sink without copying; Huffman-coded strings are
/// decoded into scratch storage that is kept between calls, so a warmed-up decoder does not
/// allocate. Field section size (name + value + 32 per field, RFC 9114 §4.2.2) is checked
/// before each field is delivered.
public struct QPACKDecoder: Sendable {
    /// The largest decoded field section accepted, as advertised in
    /// `SETTINGS_MAX_FIELD_SECTION_SIZE`.
    public var maxFieldSectionSize: Int

    /// Holds Huffman-decoded strings for the field being delivered.
    @usableFromInline var scratch: [UInt8]

    public init(maxFieldSectionSize: Int = 16 * 1024) {
        precondition(maxFieldSectionSize >= 0, "maxFieldSectionSize must not be negative")
        self.maxFieldSectionSize = maxFieldSectionSize
        self.scratch = []
    }

    /// Decodes a complete encoded field section, delivering each field to `sink`.
    ///
    /// - Returns: the field section size (sum of name + value + 32 over all fields).
    /// - Throws: ``QPACKError`` with code `.decompressionFailed`. Fields before the failure
    ///   have already reached `sink`.
    @inlinable
    @discardableResult
    public mutating func decode<Sink: QPACKFieldSink>(
        _ section: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QPACKError) -> Int {
        // Encoded Field Section Prefix: Required Insert Count (8+), then S and Delta Base (7+).
        var position = 0
        let requiredInsertCount = try Self.integer(section, at: &position, prefixBits: 8)
        guard requiredInsertCount == 0 else { throw .decompression(.requiredInsertCountNotZero) }
        guard position < section.count else { throw .decompression(.truncated) }
        // With Required Insert Count 0, a Sign bit of 1 always makes Base negative (§4.5.1.2).
        guard section[position] & 0x80 == 0 else { throw .decompression(.negativeBase) }
        // Delta Base is otherwise irrelevant: nothing can be referenced relative to it.
        _ = try Self.integer(section, at: &position, prefixBits: 7)

        var size = 0
        while position < section.count {
            let first = section[position]
            if first & 0x80 != 0 {
                // Indexed Field Line: 1 T Index(6+).
                guard first & 0x40 != 0 else { throw .decompression(.dynamicTableReference) }
                let index = try Self.staticIndex(section, at: &position, prefixBits: 6)
                try Self.deliverStatic(index, size: &size, max: maxFieldSectionSize, into: &sink)
            } else if first & 0x40 != 0 {
                // Literal Field Line with Name Reference: 0 1 N T NameIndex(4+), value (7+).
                guard first & 0x10 != 0 else { throw .decompression(.dynamicTableReference) }
                let neverIndexed = first & 0x20 != 0
                let index = try Self.staticIndex(section, at: &position, prefixBits: 4)
                scratch.removeAll(keepingCapacity: true)
                let entry = staticTable.entries[index]
                let nameLength = Int(entry.nameEnd &- entry.nameStart)
                let budget = maxFieldSectionSize &- size &- 32 &- nameLength
                let value = try Self.string(section, at: &position, prefixBits: 7, budget: budget, scratch: &scratch)
                try Self.account(nameLength &+ value.count, size: &size, max: maxFieldSectionSize)
                staticTable.bytes.withUnsafeBytes { table in
                    let name = UnsafeRawBufferPointer(
                        rebasing: table[Int(entry.nameStart)..<Int(entry.nameEnd)])
                    Self.withString(value, section: section, scratch: scratch) { value in
                        sink.field(name: name, value: value, neverIndexed: neverIndexed)
                    }
                }
            } else if first & 0x20 != 0 {
                // Literal Field Line with Literal Name: 0 0 1 N H NameLength(3+), name, value (7+).
                let neverIndexed = first & 0x10 != 0
                scratch.removeAll(keepingCapacity: true)
                let budget = maxFieldSectionSize &- size &- 32
                let name = try Self.string(section, at: &position, prefixBits: 3, budget: budget, scratch: &scratch)
                let value = try Self.string(
                    section, at: &position, prefixBits: 7, budget: budget &- name.count, scratch: &scratch)
                try Self.account(name.count &+ value.count, size: &size, max: maxFieldSectionSize)
                Self.withString(name, section: section, scratch: scratch) { name in
                    Self.withString(value, section: section, scratch: scratch) { value in
                        sink.field(name: name, value: value, neverIndexed: neverIndexed)
                    }
                }
            } else {
                // 0001xxxx Indexed Field Line with Post-Base Index, or
                // 0000Nxxx Literal Field Line with Post-Base Name Reference.
                throw .decompression(.dynamicTableReference)
            }
        }
        return size
    }

    /// Where a decoded string lives: in the encoded section (raw) or in scratch (Huffman).
    @usableFromInline
    struct StringLocation {
        @usableFromInline var start: Int
        @usableFromInline var count: Int
        @usableFromInline var inScratch: Bool

        @inlinable
        init(start: Int, count: Int, inScratch: Bool) {
            self.start = start
            self.count = count
            self.inScratch = inScratch
        }
    }

    @inlinable
    static func withString(
        _ location: StringLocation, section: UnsafeRawBufferPointer, scratch: [UInt8],
        _ body: (UnsafeRawBufferPointer) -> Void
    ) {
        let range = location.start..<(location.start &+ location.count)
        if location.inScratch {
            scratch.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[range])) }
        } else {
            body(UnsafeRawBufferPointer(rebasing: section[range]))
        }
    }

    @inlinable
    static func integer(
        _ section: UnsafeRawBufferPointer, at position: inout Int, prefixBits: Int
    ) throws(QPACKError) -> UInt64 {
        guard position < section.count else { throw .decompression(.truncated) }
        switch PrefixInteger.decode(
            UnsafeRawBufferPointer(rebasing: section[position...]), prefixBits: prefixBits)
        {
        case .value(let value, let consumed):
            position &+= consumed
            return value
        case .needsMoreData:
            throw .decompression(.truncated)
        case .overflow:
            throw .decompression(.integerOverflow)
        }
    }

    @inlinable
    static func staticIndex(
        _ section: UnsafeRawBufferPointer, at position: inout Int, prefixBits: Int
    ) throws(QPACKError) -> Int {
        let index = try integer(section, at: &position, prefixBits: prefixBits)
        guard index < UInt64(QPACKStaticTable.count) else { throw .decompression(.staticIndexOutOfRange) }
        return Int(index)
    }

    /// Reads a string literal whose H flag sits just above a `prefixBits`-bit length.
    /// `budget` is the most decoded bytes the field section can still take.
    @inlinable
    static func string(
        _ section: UnsafeRawBufferPointer, at position: inout Int, prefixBits: Int, budget: Int,
        scratch: inout [UInt8]
    ) throws(QPACKError) -> StringLocation {
        guard position < section.count else { throw .decompression(.truncated) }
        let huffman = section[position] & StringLiteral.huffmanFlag(prefixBits: prefixBits) != 0
        let length = try integer(section, at: &position, prefixBits: prefixBits)
        // A Huffman code is at least 5 bits per byte, so the decoded string is at least
        // as long as 5/8 of the coded length: checking that lower bound up front bounds the work.
        let minimumDecoded = huffman ? (length >> 3) &* 5 : length
        guard budget >= 0, minimumDecoded <= UInt64(budget) else {
            throw .decompression(.fieldSectionTooLarge)
        }
        guard length <= UInt64(section.count &- position) else { throw .decompression(.truncated) }
        let start = position
        position &+= Int(length)
        guard huffman else { return StringLocation(start: start, count: Int(length), inScratch: false) }
        let scratchStart = scratch.count
        do throws(HeaderCompressionError) {
            try Huffman.decode(UnsafeRawBufferPointer(rebasing: section[start..<position]), into: &scratch)
        } catch {
            throw .decompression(.huffman(error))
        }
        return StringLocation(start: scratchStart, count: scratch.count &- scratchStart, inScratch: true)
    }

    @inlinable
    static func account(_ fieldBytes: Int, size: inout Int, max: Int) throws(QPACKError) {
        let total = size &+ fieldBytes &+ 32
        guard total <= max else { throw .decompression(.fieldSectionTooLarge) }
        size = total
    }

    @inlinable
    static func deliverStatic<Sink: QPACKFieldSink>(
        _ index: Int, size: inout Int, max: Int, into sink: inout Sink
    ) throws(QPACKError) {
        let entry = staticTable.entries[index]
        try account(Int(entry.valueEnd &- entry.nameStart), size: &size, max: max)
        staticTable.bytes.withUnsafeBytes { table in
            sink.field(
                name: UnsafeRawBufferPointer(rebasing: table[Int(entry.nameStart)..<Int(entry.nameEnd)]),
                value: UnsafeRawBufferPointer(rebasing: table[Int(entry.nameEnd)..<Int(entry.valueEnd)]),
                neverIndexed: false)
        }
    }
}
