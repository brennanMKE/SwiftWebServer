/// Prefix integers and Huffman coding shared by HPACK and QPACK.
///
/// See `PrefixInteger` (RFC 7541 §5.1) and `Huffman` (RFC 7541 §5.2, Appendix B).
public enum HeaderCompressionModule {
    /// The module name.
    public static let name = "HeaderCompression"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = []
}
