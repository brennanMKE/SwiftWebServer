public import HeaderCompression

/// Encodes field sections using only the static table (RFC 9204 §4.5), so a field section
/// never depends on encoder-stream state: Required Insert Count and Base are always 0.
///
/// Per field the encoder picks, in order:
/// 1. an Indexed Field Line (static) when the static table holds the exact name and value;
/// 2. a Literal Field Line with Name Reference (static) when it holds the name;
/// 3. a Literal Field Line with Literal Name otherwise.
///
/// Strings follow ``huffman`` (Huffman-coded only when shorter by default). Fields named
/// `authorization`, `cookie` or `set-cookie` are always literals with the never-indexed (N)
/// bit set, so intermediaries never put them in a dynamic table.
///
/// Field names must already be lowercase (RFC 9114 §4.2); the encoder does not fold case.
public struct QPACKEncoder: Sendable {
    /// When strings are Huffman-coded.
    public var huffman: StringLiteral.HuffmanPolicy

    public init(huffman: StringLiteral.HuffmanPolicy = .whenShorter) {
        self.huffman = huffman
    }

    /// Appends the encoded field section prefix: Required Insert Count 0, Sign 0, Delta Base 0.
    @inlinable
    public func encodePrefix<Sink: ByteSink>(into sink: inout Sink) {
        sink.append(0x00)
        sink.append(0x00)
    }

    /// Appends one field line.
    ///
    /// - Parameter neverIndexed: forces the N bit (and a literal representation) on. The
    ///   built-in sensitive names get it regardless.
    @inlinable
    public func encodeField<Sink: ByteSink>(
        name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool = false,
        into sink: inout Sink
    ) {
        switch QPACKStaticTable.lookup(name: name, value: value) {
        case .field(let index) where !neverIndexed && !Self.isSensitive(staticIndex: index):
            // Indexed Field Line: 1 T=1 Index(6+).
            PrefixInteger.encode(UInt64(index), prefixBits: 6, flags: 0xC0, into: &sink)
        case .field(let index), .name(let index):
            // Literal Field Line with Name Reference: 0 1 N T=1 NameIndex(4+), then the value.
            let n: UInt8 = neverIndexed || Self.isSensitive(staticIndex: index) ? 0x20 : 0
            PrefixInteger.encode(UInt64(index), prefixBits: 4, flags: 0x50 | n, into: &sink)
            StringLiteral.encode(value, prefixBits: 7, huffman: huffman, into: &sink)
        case .none:
            // Literal Field Line with Literal Name: 0 0 1 N H NameLength(3+), name, then the value.
            // No sensitive name is missing from the static table, so only the caller sets N here.
            let n: UInt8 = neverIndexed ? 0x10 : 0
            StringLiteral.encode(name, prefixBits: 3, flags: 0x20 | n, huffman: huffman, into: &sink)
            StringLiteral.encode(value, prefixBits: 7, huffman: huffman, into: &sink)
        }
    }

    /// Appends a complete field section: the prefix and then every field in order.
    public func encode<Sink: ByteSink>(_ fields: [(name: [UInt8], value: [UInt8])], into sink: inout Sink) {
        encodePrefix(into: &sink)
        for field in fields {
            field.name.withUnsafeBytes { name in
                field.value.withUnsafeBytes { value in
                    encodeField(name: name, value: value, into: &sink)
                }
            }
        }
    }

    /// Whether `name` is one of the names the encoder always sends never-indexed.
    @inlinable
    public static func isSensitive(name: UnsafeRawBufferPointer) -> Bool {
        guard let index = QPACKStaticTable.index(name: name) else { return false }
        return isSensitive(staticIndex: index)
    }

    /// `cookie` (5), `set-cookie` (14) and `authorization` (84). Every static entry with these
    /// names is the single name-only entry, so the index identifies the name.
    @inlinable
    static func isSensitive(staticIndex index: Int) -> Bool {
        index == 5 || index == 14 || index == 84
    }
}
