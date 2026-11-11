public import HeaderCompression

/// How the encoder represents one field (RFC 7541 §6).
public enum HPACKIndexingPolicy: Sendable, Equatable {
    /// Indexed when the table has the exact field. Otherwise never-indexed for sensitive names
    /// (`authorization`, `cookie`, `proxy-authorization`, `set-cookie`); a literal with
    /// incremental indexing when the entry is cacheable (its name is not one whose value changes
    /// per message, such as `:path`, `content-length` or `etag`, and it fills at most 3/4 of
    /// the table); else a literal without indexing.
    case automatic
    /// Indexed when the table has the exact field, else a literal with incremental indexing.
    case incremental
    /// Indexed when the table has the exact field, else a literal without indexing.
    case withoutIndexing
    /// Always a never-indexed literal (RFC 7541 §7.1.3); use for any field the caller
    /// considers sensitive. The name may still come from the table.
    case neverIndexed
}

/// Encodes header blocks (RFC 7541 §6) for the connection's single frame writer.
///
/// A value type with no I/O. The dynamic table is allocated once. A block is
/// ``beginHeaderBlock(into:)`` followed by one ``encode(name:value:indexing:into:)`` per field;
/// the begin call emits any table size updates owed since the last block.
///
/// Names are matched byte for byte; HTTP/2 field names are lowercase (RFC 9113 §8.2.1).
public struct HPACKEncoder: Sendable {
    /// The encoder's copy of the table the peer decodes with.
    public private(set) var dynamicTable: HPACKDynamicTable

    /// When string literals are Huffman-coded.
    public var huffman: StringLiteral.HuffmanPolicy

    /// The smallest table size set since the last block, when an update is owed.
    var pendingMinimum: Int?

    /// - Parameters:
    ///   - tableCapacity: the most table memory this encoder will use, whatever the peer allows.
    ///   - peerMaxTableSize: the peer's `SETTINGS_HEADER_TABLE_SIZE` the peer's decoder starts
    ///     with (4,096 until its SETTINGS say otherwise). If `tableCapacity` is smaller, the
    ///     first block starts with a size update.
    ///   - huffman: defaults to Huffman-coding a string only when that is shorter.
    public init(
        tableCapacity: Int = 4096, peerMaxTableSize: Int = 4096,
        huffman: StringLiteral.HuffmanPolicy = .whenShorter
    ) {
        dynamicTable = HPACKDynamicTable(capacity: tableCapacity)
        self.huffman = huffman
        let size = Swift.min(tableCapacity, peerMaxTableSize)
        dynamicTable.setMaxSize(size)
        if size != peerMaxTableSize { pendingMinimum = size }
    }

    /// Applies the peer's `SETTINGS_HEADER_TABLE_SIZE`. The table shrinks now; the next block
    /// starts with the size update(s) that tell the peer (RFC 7541 §4.2: the smallest size
    /// since the last block, then the final one).
    public mutating func setPeerMaxTableSize(_ peerMaxTableSize: Int) {
        precondition(peerMaxTableSize >= 0, "table size must not be negative")
        let size = Swift.min(peerMaxTableSize, dynamicTable.capacity)
        guard size != dynamicTable.maxSize || pendingMinimum != nil else { return }
        pendingMinimum = Swift.min(pendingMinimum ?? size, size)
        dynamicTable.setMaxSize(size)
    }

    /// True when the next block starts with a table size update.
    public var hasPendingTableSizeUpdate: Bool { pendingMinimum != nil }

    /// Starts a header block: emits any pending dynamic table size updates (§6.3).
    public mutating func beginHeaderBlock<Sink: ByteSink>(into sink: inout Sink) {
        guard let minimum = pendingMinimum else { return }
        if minimum < dynamicTable.maxSize {
            PrefixInteger.encode(UInt64(minimum), prefixBits: 5, flags: 0x20, into: &sink)
        }
        PrefixInteger.encode(UInt64(dynamicTable.maxSize), prefixBits: 5, flags: 0x20, into: &sink)
        pendingMinimum = nil
    }

    /// Encodes one field of the current block.
    public mutating func encode<Sink: ByteSink>(
        name: Span<UInt8>, value: Span<UInt8>, indexing: HPACKIndexingPolicy = .automatic,
        into sink: inout Sink
    ) {
        let staticMatch = HPACKStaticTable.search(name: name, value: value)
        var policy = indexing
        if policy == .automatic, case .name(let index) = staticMatch, HPACKStaticTable.isSensitiveName(at: index) {
            policy = .neverIndexed
        }

        // An exact match is a one-or-two-byte indexed field.
        var nameIndex = 0
        switch staticMatch {
        case .field(let index):
            if policy != .neverIndexed {
                PrefixInteger.encode(UInt64(index), prefixBits: 7, flags: 0x80, into: &sink)
                return
            }
            nameIndex = HPACKStaticTable.firstIndex(name: name) ?? index
        case .name(let index):
            nameIndex = index
        case .none:
            break
        }
        if policy != .neverIndexed || nameIndex == 0 {
            switch dynamicTable.searchDynamic(name: name, value: value) {
            case .field(let position) where policy != .neverIndexed:
                let index = HPACKDynamicTable.firstIndex + position
                PrefixInteger.encode(UInt64(index), prefixBits: 7, flags: 0x80, into: &sink)
                return
            case .field(let position), .name(let position):
                // The static name is preferred: its index is stable and usually shorter.
                if nameIndex == 0 { nameIndex = HPACKDynamicTable.firstIndex + position }
            case .none:
                break
            }
        }

        if policy == .automatic {
            let entrySize = name.count + value.count + HPACKDynamicTable.entryOverhead
            let volatile = nameIndex >= 1 && nameIndex <= HPACKStaticTable.count
                && HPACKStaticTable.isVolatileName(at: nameIndex)
            policy = !volatile && entrySize * 4 <= dynamicTable.maxSize * 3 ? .incremental : .withoutIndexing
        }

        let prefixBits: Int
        let flags: UInt8
        switch policy {
        case .incremental: (prefixBits, flags) = (6, 0x40)
        case .neverIndexed: (prefixBits, flags) = (4, 0x10)
        case .withoutIndexing, .automatic: (prefixBits, flags) = (4, 0x00)
        }
        PrefixInteger.encode(UInt64(nameIndex), prefixBits: prefixBits, flags: flags, into: &sink)
        let huffman = huffman
        if nameIndex == 0 {
            UnsafeBridge.withRawBytes(name) {
                StringLiteral.encode($0, prefixBits: 7, huffman: huffman, into: &sink)
            }
        }
        UnsafeBridge.withRawBytes(value) {
            StringLiteral.encode($0, prefixBits: 7, huffman: huffman, into: &sink)
        }
        if policy == .incremental {
            dynamicTable.insert(name: name, value: value)
        }
    }
}
