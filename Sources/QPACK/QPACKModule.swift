import HeaderCompression
import HTTPCore

/// QPACK header compression for HTTP/3 (RFC 9204).
///
/// Static-table-only encoder and decoder (`QPACKEncoder`, `QPACKDecoder`), encoder and
/// decoder stream instruction parsing, and the decoder side of the dynamic table
/// (`QPACKDynamicTable`, `QPACKDynamicDecoder`, #0106). The encoder never inserts.
public enum QPACKModule {
    /// The module name.
    public static let name = "QPACK"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HeaderCompressionModule.name, HTTPCoreModule.name]
}
