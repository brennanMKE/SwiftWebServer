import HeaderCompression

/// A field section decoder the HTTP/3 layer can use in place of ``QPACKDecoder``.
public protocol QPACKSectionDecoder {
    /// Decodes a complete encoded field section, delivering each field to `sink`; returns the
    /// field section size (name + value + 32 per field).
    mutating func decode<Sink: QPACKFieldSink>(
        _ section: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QPACKError) -> Int
}

extension QPACKDecoder: QPACKSectionDecoder {}

/// The decoder side of a connection that advertised a non-zero
/// `SETTINGS_QPACK_MAX_TABLE_CAPACITY` (RFC 9204): the dynamic table, the peer's encoder
/// stream, field sections that reference the table, blocked streams, and our decoder stream.
///
/// A value type with no I/O and no `await`. The HTTP/3 layer keeps one per connection behind a
/// `Mutex` and calls it inside non-suspending critical sections:
///
/// - ``consumeEncoderStream(_:)`` applies Set Dynamic Table Capacity, Insert With Name
///   Reference (static or dynamic), Insert With Literal Name and Duplicate
///   (`QPACK_ENCODER_STREAM_ERROR` on any invalid instruction);
/// - ``admit(_:)`` reads a field section's Required Insert Count and says whether the stream
///   must wait for more inserts; a stream that would exceed ``maxBlockedStreams`` is
///   `QPACK_DECOMPRESSION_FAILED` (§2.1.2), and ``unblock()`` releases the slot;
/// - ``decode(_:requiredInsertCount:streamID:into:)`` decodes a section once its inserts have
///   arrived (Base, relative and post-Base indices, §4.5) and queues a Section Acknowledgment
///   when it referenced the table;
/// - ``cancelStream(_:)`` queues a Stream Cancellation; ``takeDecoderStreamOutput(into:)``
///   hands over the queued decoder stream bytes plus an Insert Count Increment for inserts not
///   yet acknowledged.
///
/// Static entries and raw strings reach the sink without copying; dynamic entries are passed
/// straight out of the table's arena; Huffman strings go through scratch storage kept between
/// calls, so a warmed-up decoder does not allocate.
public struct QPACKDynamicDecoder: Sendable {
    /// The dynamic table.
    public private(set) var table: QPACKDynamicTable
    /// Our `SETTINGS_QPACK_BLOCKED_STREAMS`.
    public let maxBlockedStreams: Int
    /// The largest decoded field section accepted (`SETTINGS_MAX_FIELD_SECTION_SIZE`).
    public var maxFieldSectionSize: Int
    /// Streams currently waiting for inserts (admitted as blocked, not yet unblocked).
    public private(set) var blockedStreams = 0
    /// The Insert Count the encoder knows we received: raised by Section Acknowledgments and
    /// Insert Count Increments we produced (§2.1.4).
    public private(set) var knownReceivedCount: UInt64 = 0

    /// Section Acknowledgments and Stream Cancellations not yet taken.
    var pending: [UInt8] = []
    var scratch: [UInt8] = []

    public init(maxTableCapacity: Int, maxBlockedStreams: Int, maxFieldSectionSize: Int = 16 * 1024) {
        precondition(maxBlockedStreams >= 0 && maxFieldSectionSize >= 0, "QPACK limits must not be negative")
        table = QPACKDynamicTable(maxCapacity: maxTableCapacity)
        self.maxBlockedStreams = maxBlockedStreams
        self.maxFieldSectionSize = maxFieldSectionSize
    }

    /// `MaxEntries` of RFC 9204 §3.2.2: the most entries the table can ever hold.
    public var maxEntries: UInt64 { UInt64(table.maxCapacity / QPACKDynamicTable.entryOverhead) }

    /// The longest string literal an encoder instruction may carry. An entry is at most the
    /// table capacity, and a Huffman code is at most 30 bits per byte, so a longer string can
    /// never make a valid insert; refusing it up front bounds what the caller buffers.
    public var maxInstructionStringLength: Int { table.maxCapacity &* 4 &+ 8 }

    // MARK: Encoder stream

    /// Applies every complete instruction at the start of `bytes`.
    ///
    /// - Returns: the bytes consumed (a trailing partial instruction is left for the next call)
    ///   and the number of instructions applied.
    /// - Throws: ``QPACKError`` with code `.encoderStreamError`.
    public mutating func consumeEncoderStream(
        _ bytes: UnsafeRawBufferPointer
    ) throws(QPACKError) -> (consumed: Int, instructions: Int) {
        var position = 0
        var instructions = 0
        while position < bytes.count {
            let rest = UnsafeRawBufferPointer(rebasing: bytes[position...])
            guard case .instruction(let instruction, let consumed) = try QPACKEncoderInstruction.parse(
                rest, maxStringLength: maxInstructionStringLength)
            else { break }
            try apply(instruction, in: rest)
            position &+= consumed
            instructions &+= 1
        }
        return (position, instructions)
    }

    /// Applies one parsed encoder instruction; `bytes` is the input it was parsed from.
    public mutating func apply(_ instruction: QPACKEncoderInstruction, in bytes: UnsafeRawBufferPointer) throws(QPACKError) {
        var scratch = self.scratch
        self.scratch = []
        defer { self.scratch = scratch }
        scratch.removeAll(keepingCapacity: true)
        switch instruction {
        case .setDynamicTableCapacity(let capacity):
            try table.setCapacity(capacity)

        case .insertWithNameReference(let isStatic, let index, let valueReference):
            let value = try Self.instructionString(valueReference, in: bytes, scratch: &scratch)
            var failure: QPACKError?
            if isStatic {
                guard index < UInt64(QPACKStaticTable.count) else {
                    throw QPACKError(.encoderStreamError, .staticIndexOutOfRange)
                }
                QPACKStaticTable.withEntry(Int(index)) { name, _ in
                    QPACKDecoder.withString(value, section: bytes, scratch: scratch) { value in
                        failure = Self.catching { () throws(QPACKError) in try table.insert(name: name, value: value) }
                    }
                }
            } else {
                let absolute = try relativeToAbsolute(index)
                QPACKDecoder.withString(value, section: bytes, scratch: scratch) { value in
                    failure = Self.catching { () throws(QPACKError) in
                        try table.insert(nameOfAbsoluteIndex: absolute, value: value)
                    }
                }
            }
            if let failure { throw failure }

        case .insertWithLiteralName(let nameReference, let valueReference):
            let name = try Self.instructionString(nameReference, in: bytes, scratch: &scratch)
            let value = try Self.instructionString(valueReference, in: bytes, scratch: &scratch)
            var failure: QPACKError?
            QPACKDecoder.withString(name, section: bytes, scratch: scratch) { name in
                QPACKDecoder.withString(value, section: bytes, scratch: scratch) { value in
                    failure = Self.catching { () throws(QPACKError) in try table.insert(name: name, value: value) }
                }
            }
            if let failure { throw failure }

        case .duplicate(let index):
            try table.duplicate(absoluteIndex: try relativeToAbsolute(index))
        }
    }

    /// An encoder-stream relative index (§3.2.5) as an absolute index.
    func relativeToAbsolute(_ relative: UInt64) throws(QPACKError) -> UInt64 {
        guard relative < UInt64(table.count) else { throw QPACKError(.encoderStreamError, .invalidDynamicIndex) }
        return table.insertCount &- 1 &- relative
    }

    /// Locates an instruction string in `bytes`, Huffman-decoding it into `scratch` if needed.
    static func instructionString(
        _ reference: QPACKStringReference, in bytes: UnsafeRawBufferPointer, scratch: inout [UInt8]
    ) throws(QPACKError) -> QPACKDecoder.StringLocation {
        guard reference.isHuffman else {
            return QPACKDecoder.StringLocation(start: reference.offset, count: reference.length, inScratch: false)
        }
        let start = scratch.count
        do throws(HeaderCompressionError) {
            try Huffman.decode(
                UnsafeRawBufferPointer(rebasing: bytes[reference.offset..<(reference.offset &+ reference.length)]),
                into: &scratch)
        } catch {
            throw QPACKError(.encoderStreamError, .huffman(error))
        }
        return QPACKDecoder.StringLocation(start: start, count: scratch.count &- start, inScratch: true)
    }

    // MARK: Field sections

    /// Decodes the encoded Required Insert Count (RFC 9204 §4.5.1.1).
    ///
    /// - Throws: `QPACK_DECOMPRESSION_FAILED` for a value no encoder could have produced.
    public static func requiredInsertCount(
        encoded: UInt64, maxEntries: UInt64, totalInserts: UInt64
    ) throws(QPACKError) -> UInt64 {
        guard encoded != 0 else { return 0 }
        let fullRange = 2 &* maxEntries
        guard maxEntries > 0, encoded <= fullRange else { throw .decompression(.invalidRequiredInsertCount) }
        let maxValue = totalInserts &+ maxEntries
        let maxWrapped = (maxValue / fullRange) &* fullRange
        var count = maxWrapped &+ encoded &- 1
        if count > maxValue {
            guard count > fullRange else { throw .decompression(.invalidRequiredInsertCount) }
            count &-= fullRange
        }
        guard count != 0 else { throw .decompression(.invalidRequiredInsertCount) }
        return count
    }

    /// The Required Insert Count of `section`, decoded against the inserts received so far.
    public func requiredInsertCount(of section: UnsafeRawBufferPointer) throws(QPACKError) -> UInt64 {
        var position = 0
        let encoded = try QPACKDecoder.integer(section, at: &position, prefixBits: 8)
        return try Self.requiredInsertCount(encoded: encoded, maxEntries: maxEntries, totalInserts: table.insertCount)
    }

    /// Whether a field section can be decoded now.
    public enum Admission: Equatable, Sendable {
        /// Every insert it needs has arrived.
        case ready(requiredInsertCount: UInt64)
        /// It needs inserts that have not arrived: the stream now counts as blocked until
        /// ``unblock()``.
        case blocked(requiredInsertCount: UInt64)
    }

    /// Reads `section`'s Required Insert Count and, when the stream must wait for inserts,
    /// counts it as blocked (§2.1.2).
    ///
    /// - Throws: `QPACK_DECOMPRESSION_FAILED` for an invalid Required Insert Count, or when
    ///   blocking would exceed ``maxBlockedStreams``.
    public mutating func admit(_ section: UnsafeRawBufferPointer) throws(QPACKError) -> Admission {
        let count = try requiredInsertCount(of: section)
        guard count > table.insertCount else { return .ready(requiredInsertCount: count) }
        guard blockedStreams < maxBlockedStreams else { throw .decompression(.blockedStreamsExceeded) }
        blockedStreams &+= 1
        return .blocked(requiredInsertCount: count)
    }

    /// Releases a blocked stream's slot (its inserts arrived, or it was abandoned).
    public mutating func unblock() {
        precondition(blockedStreams > 0, "unblock without a blocked stream")
        blockedStreams &-= 1
    }

    /// Decodes a complete field section whose `requiredInsertCount` (from ``admit(_:)``) has
    /// been reached, delivering each field to `sink`. When the section references the dynamic
    /// table, a Section Acknowledgment for `streamID` is queued.
    ///
    /// - Returns: the field section size (name + value + 32 per field).
    /// - Throws: `QPACK_DECOMPRESSION_FAILED`. Fields before the failure have reached `sink`.
    @discardableResult
    public mutating func decode<Sink: QPACKFieldSink>(
        _ section: UnsafeRawBufferPointer, requiredInsertCount: UInt64, streamID: UInt64, into sink: inout Sink
    ) throws(QPACKError) -> Int {
        precondition(requiredInsertCount <= table.insertCount, "decode a blocked field section only after its inserts")
        var scratch = self.scratch
        self.scratch = []
        defer { self.scratch = scratch }
        let table = self.table
        let max = maxFieldSectionSize

        // Encoded Field Section Prefix: Required Insert Count (8+), then S and Delta Base (7+).
        var position = 0
        _ = try QPACKDecoder.integer(section, at: &position, prefixBits: 8)
        guard position < section.count else { throw .decompression(.truncated) }
        let negative = section[position] & 0x80 != 0
        let delta = try QPACKDecoder.integer(section, at: &position, prefixBits: 7)
        let base: UInt64
        if negative {
            guard requiredInsertCount > delta else { throw .decompression(.negativeBase) }
            base = requiredInsertCount &- delta &- 1
        } else {
            // Both are below 2^62, so the sum cannot overflow.
            base = requiredInsertCount &+ delta
        }

        // One past the largest absolute index referenced.
        var referenced: UInt64 = 0
        func absolute(_ index: UInt64) throws(QPACKError) -> UInt64 {
            guard index < requiredInsertCount, table.contains(absoluteIndex: index) else {
                throw .decompression(.invalidDynamicIndex)
            }
            if index >= referenced { referenced = index &+ 1 }
            return index
        }
        func relative(_ index: UInt64) throws(QPACKError) -> UInt64 {
            guard index < base else { throw .decompression(.invalidDynamicIndex) }
            return try absolute(base &- 1 &- index)
        }
        func postBase(_ index: UInt64) throws(QPACKError) -> UInt64 {
            guard index < requiredInsertCount else { throw .decompression(.invalidDynamicIndex) }
            return try absolute(base &+ index)
        }

        var size = 0
        while position < section.count {
            let first = section[position]
            if first & 0xC0 == 0xC0 {
                // Indexed Field Line, static: 1 1 Index(6+).
                let index = try QPACKDecoder.staticIndex(section, at: &position, prefixBits: 6)
                try QPACKDecoder.deliverStatic(index, size: &size, max: max, into: &sink)
            } else if first & 0x80 != 0 {
                // Indexed Field Line, dynamic: 1 0 Index(6+), relative to Base.
                let index = try relative(QPACKDecoder.integer(section, at: &position, prefixBits: 6))
                try Self.deliverDynamic(index, table: table, size: &size, max: max, into: &sink)
            } else if first & 0x40 != 0 {
                // Literal Field Line with Name Reference: 0 1 N T NameIndex(4+), value (7+).
                let neverIndexed = first & 0x20 != 0
                if first & 0x10 != 0 {
                    let index = try QPACKDecoder.staticIndex(section, at: &position, prefixBits: 4)
                    let failure: QPACKError? = QPACKStaticTable.withEntry(index) { name, _ in
                        Self.catching { () throws(QPACKError) in
                            try Self.deliverLiteral(
                                name: name, section: section, at: &position, neverIndexed: neverIndexed,
                                size: &size, max: max, scratch: &scratch, into: &sink)
                        }
                    }
                    if let failure { throw failure }
                } else {
                    let index = try relative(QPACKDecoder.integer(section, at: &position, prefixBits: 4))
                    try table.withEntry(absoluteIndex: index) { (name, _) throws(QPACKError) in
                        try Self.deliverLiteral(
                            name: name, section: section, at: &position, neverIndexed: neverIndexed,
                            size: &size, max: max, scratch: &scratch, into: &sink)
                    }
                }
            } else if first & 0x20 != 0 {
                // Literal Field Line with Literal Name: 0 0 1 N H NameLength(3+), name, value (7+).
                let neverIndexed = first & 0x10 != 0
                scratch.removeAll(keepingCapacity: true)
                let budget = max &- size &- 32
                let name = try QPACKDecoder.string(section, at: &position, prefixBits: 3, budget: budget, scratch: &scratch)
                let value = try QPACKDecoder.string(
                    section, at: &position, prefixBits: 7, budget: budget &- name.count, scratch: &scratch)
                try QPACKDecoder.account(name.count &+ value.count, size: &size, max: max)
                QPACKDecoder.withString(name, section: section, scratch: scratch) { name in
                    QPACKDecoder.withString(value, section: section, scratch: scratch) { value in
                        sink.field(name: name, value: value, neverIndexed: neverIndexed)
                    }
                }
            } else if first & 0x10 != 0 {
                // Indexed Field Line with Post-Base Index: 0 0 0 1 Index(4+).
                let index = try postBase(QPACKDecoder.integer(section, at: &position, prefixBits: 4))
                try Self.deliverDynamic(index, table: table, size: &size, max: max, into: &sink)
            } else {
                // Literal Field Line with Post-Base Name Reference: 0 0 0 0 N NameIndex(3+), value (7+).
                let neverIndexed = first & 0x08 != 0
                let index = try postBase(QPACKDecoder.integer(section, at: &position, prefixBits: 3))
                try table.withEntry(absoluteIndex: index) { (name, _) throws(QPACKError) in
                    try Self.deliverLiteral(
                        name: name, section: section, at: &position, neverIndexed: neverIndexed,
                        size: &size, max: max, scratch: &scratch, into: &sink)
                }
            }
        }
        if requiredInsertCount > 0 {
            // The Required Insert Count must be exactly what the section needed (§4.5.1.1).
            guard referenced == requiredInsertCount else { throw .decompression(.invalidRequiredInsertCount) }
            acknowledge(streamID: streamID, requiredInsertCount: requiredInsertCount)
        }
        return size
    }

    static func catching(_ body: () throws(QPACKError) -> Void) -> QPACKError? {
        do throws(QPACKError) {
            try body()
            return nil
        } catch {
            return error
        }
    }

    static func deliverDynamic<Sink: QPACKFieldSink>(
        _ index: UInt64, table: QPACKDynamicTable, size: inout Int, max: Int, into sink: inout Sink
    ) throws(QPACKError) {
        try QPACKDecoder.account(table.entrySize(absoluteIndex: index) &- QPACKDynamicTable.entryOverhead,
                                 size: &size, max: max)
        table.withEntry(absoluteIndex: index) { name, value in
            sink.field(name: name, value: value, neverIndexed: false)
        }
    }

    static func deliverLiteral<Sink: QPACKFieldSink>(
        name: UnsafeRawBufferPointer, section: UnsafeRawBufferPointer, at position: inout Int, neverIndexed: Bool,
        size: inout Int, max: Int, scratch: inout [UInt8], into sink: inout Sink
    ) throws(QPACKError) {
        scratch.removeAll(keepingCapacity: true)
        let budget = max &- size &- 32 &- name.count
        let value = try QPACKDecoder.string(section, at: &position, prefixBits: 7, budget: budget, scratch: &scratch)
        try QPACKDecoder.account(name.count &+ value.count, size: &size, max: max)
        QPACKDecoder.withString(value, section: section, scratch: scratch) { value in
            sink.field(name: name, value: value, neverIndexed: neverIndexed)
        }
    }

    // MARK: Decoder stream

    /// Queues a Section Acknowledgment (§4.4.1).
    mutating func acknowledge(streamID: UInt64, requiredInsertCount: UInt64) {
        PrefixInteger.encode(streamID, prefixBits: 7, flags: 0x80, into: &pending)
        if requiredInsertCount > knownReceivedCount { knownReceivedCount = requiredInsertCount }
    }

    /// Queues a Stream Cancellation (§4.4.2) for a stream that was reset or abandoned before
    /// all its field sections were decoded.
    public mutating func cancelStream(_ streamID: UInt64) {
        PrefixInteger.encode(streamID, prefixBits: 6, flags: 0x40, into: &pending)
    }

    /// Whether ``takeDecoderStreamOutput(into:)`` has anything to hand over.
    public var hasDecoderStreamOutput: Bool { !pending.isEmpty || table.insertCount > knownReceivedCount }

    /// Bytes queued for the decoder stream (not counting the Insert Count Increment).
    public var pendingDecoderStreamBytes: Int { pending.count }

    /// Appends the queued decoder stream instructions to `output`, then an Insert Count
    /// Increment (§4.4.3) for the inserts the encoder does not yet know we received.
    public mutating func takeDecoderStreamOutput(into output: inout [UInt8]) {
        output.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if table.insertCount > knownReceivedCount {
            PrefixInteger.encode(table.insertCount &- knownReceivedCount, prefixBits: 6, flags: 0x00, into: &output)
            knownReceivedCount = table.insertCount
        }
    }
}
