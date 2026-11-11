public import HTTPCore
import HeaderCompression

/// How a decoded field was represented in the header block (RFC 7541 §6).
public enum HPACKRepresentation: Sendable, Equatable {
    /// An indexed field (§6.1).
    case indexed
    /// A literal with incremental indexing (§6.2.1); the field is now the newest table entry.
    case incrementalIndexing
    /// A literal without indexing (§6.2.2).
    case withoutIndexing
    /// A literal never indexed (§6.2.3). An intermediary must re-encode it the same way.
    case neverIndexed
}

/// Receives decoded header fields in block order.
///
/// The spans are valid only during the call: they point into the header block, the dynamic
/// table, or the decoder's scratch buffer. Copy what must outlive it.
public protocol HPACKFieldSink {
    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation)
}

/// Decodes complete HPACK header blocks (RFC 7541 §3, §6) into a caller-provided sink.
///
/// A value type with no I/O (docs/ROADMAP.md §5.4). The dynamic table and a scratch buffer for
/// Huffman-decoded strings are allocated once; decoding a block allocates nothing unless a
/// Huffman string is longer than any seen before. Raw literals are handed to the sink straight
/// from the block.
///
/// Any error is a connection-level `COMPRESSION_ERROR`; after one the decoder throws
/// ``HPACKError/decoderUnusable`` for every later block.
public struct HPACKDecoder: Sendable {
    /// The table the peer's encoder indexes into.
    public private(set) var dynamicTable: HPACKDynamicTable

    /// Our advertised (and acknowledged) `SETTINGS_HEADER_TABLE_SIZE`; size updates above it
    /// are errors.
    public private(set) var maxTableSizeLimit: Int

    /// The largest header list accepted, counting name + value + 32 per field. Enforced field by
    /// field, so an HPACK bomb fails at the first field over the limit.
    public var maxHeaderListSize: Int

    /// The largest encoded string literal accepted, in bytes.
    public var maxStringLength: Int

    /// True after any decoding error.
    public private(set) var isUnusable = false

    /// Set when ``maxTableSizeLimit`` drops below the table's size: the next block must begin
    /// with a size update.
    var requiresSizeUpdate = false
    var scratch: [UInt8]

    /// - Parameters:
    ///   - maxTableSize: our `SETTINGS_HEADER_TABLE_SIZE`; also the table's fixed capacity.
    ///   - maxHeaderListSize: our `SETTINGS_MAX_HEADER_LIST_SIZE` (docs/HTTP2.md default 16,384).
    ///   - maxStringLength: defaults to `maxHeaderListSize`.
    public init(maxTableSize: Int = 4096, maxHeaderListSize: Int = 16_384, maxStringLength: Int? = nil) {
        dynamicTable = HPACKDynamicTable(capacity: maxTableSize)
        maxTableSizeLimit = maxTableSize
        self.maxHeaderListSize = maxHeaderListSize
        self.maxStringLength = maxStringLength ?? maxHeaderListSize
        scratch = []
        scratch.reserveCapacity(Swift.min(Swift.max(self.maxStringLength, 64), 4096))
    }

    /// Applies a new advertised `SETTINGS_HEADER_TABLE_SIZE` once the peer has acknowledged it
    /// (RFC 9113 §6.5.3). It must not exceed the capacity given at creation.
    ///
    /// If it is below the table's current maximum size, the next block must start with a size
    /// update that brings the table within it.
    public mutating func setMaxTableSizeLimit(_ limit: Int) {
        precondition(limit >= 0 && limit <= dynamicTable.capacity,
                     "table size limit \(limit) outside 0...\(dynamicTable.capacity)")
        maxTableSizeLimit = limit
        if limit < dynamicTable.maxSize { requiresSizeUpdate = true }
    }

    /// Decodes one complete header block (HEADERS plus any CONTINUATION payloads, joined).
    public mutating func decode<Sink: HPACKFieldSink>(
        _ block: Span<UInt8>, into sink: inout Sink
    ) throws(HPACKError) {
        guard !isUnusable else { throw .decoderUnusable }
        do throws(HPACKError) {
            var state = BlockState(
                limit: maxTableSizeLimit, maxListSize: maxHeaderListSize,
                maxStringLength: maxStringLength, requiresSizeUpdate: requiresSizeUpdate)
            try Self.decodeBlock(block, state: &state, table: &dynamicTable, scratch: &scratch, sink: &sink)
            requiresSizeUpdate = state.requiresSizeUpdate
        } catch {
            isUnusable = true
            throw error
        }
    }

    /// Decodes the block held in `view` of `buffer`.
    public mutating func decode<Sink: HPACKFieldSink>(
        _ view: ByteView, in buffer: ByteBuffer, into sink: inout Sink
    ) throws(HPACKError) {
        try buffer.withSpan(of: view) { (block) throws(HPACKError) in
            try decode(block, into: &sink)
        }
    }

    // MARK: Block decoding

    struct BlockState {
        let limit: Int
        let maxListSize: Int
        let maxStringLength: Int
        var requiresSizeUpdate: Bool
        var listSize = 0
        var sawField = false
    }

    /// Where a decoded string's bytes are.
    enum StringRef {
        case block(Range<Int>)
        case scratch(Range<Int>)

        var count: Int {
            switch self {
            case .block(let range), .scratch(let range): range.count
            }
        }
    }

    /// A literal's name: a table index or a string.
    enum NameRef {
        case index(UInt64)
        case string(StringRef)
    }

    static func decodeBlock<Sink: HPACKFieldSink>(
        _ block: Span<UInt8>, state: inout BlockState, table: inout HPACKDynamicTable,
        scratch: inout [UInt8], sink: inout Sink
    ) throws(HPACKError) {
        var position = 0
        while position < block.count {
            let first = block[position]
            if first & 0x80 != 0 {
                // §6.1 Indexed header field.
                let index = try readInteger(block, &position, prefixBits: 7)
                try beginField(&state)
                try table.withField(atIndex: index) { (name, value) throws(HPACKError) in
                    try account(name.count, value.count, &state)
                    sink.field(name: name, value: value, representation: .indexed)
                }
            } else if first & 0xE0 == 0x20 {
                // §6.3 Dynamic table size update.
                guard !state.sawField else { throw .tableSizeUpdateNotAtStart }
                let size = try readInteger(block, &position, prefixBits: 5)
                guard size <= UInt64(state.limit) else {
                    throw .tableSizeUpdateTooLarge(requested: size, limit: state.limit)
                }
                table.setMaxSize(Int(size))
                state.requiresSizeUpdate = false
            } else {
                let representation: HPACKRepresentation
                let prefixBits: Int
                if first & 0x40 != 0 {
                    representation = .incrementalIndexing
                    prefixBits = 6
                } else {
                    representation = first & 0x10 != 0 ? .neverIndexed : .withoutIndexing
                    prefixBits = 4
                }
                try beginField(&state)
                try decodeLiteral(
                    block, &position, prefixBits: prefixBits, representation: representation,
                    state: &state, table: &table, scratch: &scratch, sink: &sink)
            }
        }
    }

    @inline(__always)
    static func beginField(_ state: inout BlockState) throws(HPACKError) {
        guard !state.requiresSizeUpdate else { throw .missingTableSizeUpdate }
        state.sawField = true
    }

    @inline(__always)
    static func account(_ nameLength: Int, _ valueLength: Int, _ state: inout BlockState) throws(HPACKError) {
        state.listSize += nameLength + valueLength + HPACKDynamicTable.entryOverhead
        guard state.listSize <= state.maxListSize else { throw .headerListTooLarge(limit: state.maxListSize) }
    }

    static func decodeLiteral<Sink: HPACKFieldSink>(
        _ block: Span<UInt8>, _ position: inout Int, prefixBits: Int,
        representation: HPACKRepresentation, state: inout BlockState,
        table: inout HPACKDynamicTable, scratch: inout [UInt8], sink: inout Sink
    ) throws(HPACKError) {
        scratch.removeAll(keepingCapacity: true)
        let nameIndex = try readInteger(block, &position, prefixBits: prefixBits)
        let name: NameRef
        let nameLength: Int
        if nameIndex == 0 {
            let ref = try readString(block, &position, maxLength: state.maxStringLength, scratch: &scratch)
            name = .string(ref)
            nameLength = ref.count
        } else {
            try table.checkIndex(nameIndex)
            name = .index(nameIndex)
            nameLength = try table.withField(atIndex: nameIndex) { (name, _) throws(HPACKError) in name.count }
        }
        let value = try readString(block, &position, maxLength: state.maxStringLength, scratch: &scratch)
        try account(nameLength, value.count, &state)

        guard representation == .incrementalIndexing,
              nameLength + value.count + HPACKDynamicTable.entryOverhead <= table.maxSize
        else {
            try withName(name, table: table, block: block, scratch: scratch) { (n) throws(HPACKError) in
                withBytes(value, block: block, scratch: scratch) { v in
                    sink.field(name: n, value: v, representation: representation)
                }
            }
            // §4.4: an entry larger than the table empties it.
            if representation == .incrementalIndexing { table.removeAll() }
            return
        }

        switch name {
        case .index(let index) where index >= UInt64(HPACKDynamicTable.firstIndex):
            let source = Int(index) - HPACKDynamicTable.firstIndex
            withBytes(value, block: block, scratch: scratch) { v in
                _ = table.insert(nameOfEntryAt: source, value: v)
            }
        case .index(let index):
            HPACKStaticTable.withEntry(at: Int(index)) { n, _ in
                withBytes(value, block: block, scratch: scratch) { v in
                    _ = table.insert(name: n, value: v)
                }
            }
        case .string(let ref):
            withBytes(ref, block: block, scratch: scratch) { n in
                withBytes(value, block: block, scratch: scratch) { v in
                    _ = table.insert(name: n, value: v)
                }
            }
        }
        table.withEntry(at: 0) { n, v in
            sink.field(name: n, value: v, representation: .incrementalIndexing)
        }
    }

    @inline(__always)
    static func withBytes<R>(
        _ ref: StringRef, block: Span<UInt8>, scratch: [UInt8], _ body: (Span<UInt8>) -> R
    ) -> R {
        switch ref {
        case .block(let range):
            return body(block.extracting(range))
        case .scratch(let range):
            return UnsafeBridge.withSpan(of: scratch, range, body)
        }
    }

    @inline(__always)
    static func withName<R>(
        _ name: NameRef, table: HPACKDynamicTable, block: Span<UInt8>, scratch: [UInt8],
        _ body: (Span<UInt8>) throws(HPACKError) -> R
    ) throws(HPACKError) -> R {
        switch name {
        case .index(let index):
            return try table.withField(atIndex: index) { (n, _) throws(HPACKError) in try body(n) }
        case .string(let ref):
            switch ref {
            case .block(let range):
                return try body(block.extracting(range))
            case .scratch(let range):
                return try UnsafeBridge.withSpan(of: scratch, range, body)
            }
        }
    }

    /// Reads a prefix integer at `position` (RFC 7541 §5.1) and advances past it.
    @inline(__always)
    static func readInteger(
        _ block: Span<UInt8>, _ position: inout Int, prefixBits: Int
    ) throws(HPACKError) -> UInt64 {
        let rest = block.extracting(position..<block.count)
        let result = UnsafeBridge.withRawBytes(rest) {
            PrefixInteger.decode($0, prefixBits: prefixBits, maxValue: PrefixInteger.maxHPACKValue)
        }
        switch result {
        case .value(let value, let consumed):
            position += consumed
            return value
        case .needsMoreData:
            throw .truncatedBlock
        case .overflow:
            throw .integerOverflow
        }
    }

    /// Reads a string literal (RFC 7541 §5.2). Raw strings stay in the block; Huffman strings
    /// are decoded onto the end of `scratch`.
    static func readString(
        _ block: Span<UInt8>, _ position: inout Int, maxLength: Int, scratch: inout [UInt8]
    ) throws(HPACKError) -> StringRef {
        guard position < block.count else { throw .truncatedBlock }
        if block[position] & 0x80 == 0 {
            let length = try readInteger(block, &position, prefixBits: 7)
            guard length <= UInt64(maxLength) else { throw .stringTooLong }
            let count = Int(length)
            guard count <= block.count - position else { throw .truncatedBlock }
            defer { position += count }
            return .block(position..<position + count)
        }
        let start = scratch.count
        let rest = block.extracting(position..<block.count)
        let result: StringLiteral.DecodeResult
        do throws(HeaderCompressionError) {
            result = try UnsafeBridge.withRawBytes(rest) { (raw) throws(HeaderCompressionError) in
                try StringLiteral.decode(raw, prefixBits: 7, maxLength: maxLength, into: &scratch)
            }
        } catch {
            switch error {
            case .integerOverflow: throw .integerOverflow
            case .stringTooLong: throw .stringTooLong
            default: throw .invalidHuffman(error)
            }
        }
        switch result {
        case .decoded(let consumed):
            position += consumed
            return .scratch(start..<scratch.count)
        case .needsMoreData:
            throw .truncatedBlock
        }
    }
}
