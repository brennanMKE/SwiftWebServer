import HeaderCompression
import HTTPCore

/// QPACK header compression for HTTP/3 (RFC 9204).
///
/// Static-table-only encoder and decoder (`QPACKEncoder`, `QPACKDecoder`) plus encoder and
/// decoder stream instruction parsing; the dynamic table capacity is always 0.
public enum QPACKModule {
    /// The module name.
    public static let name = "QPACK"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HeaderCompressionModule.name, HTTPCoreModule.name]
}
