import HeaderCompression
import HTTPCore

/// QPACK header compression for HTTP/3 (RFC 9204).
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum QPACKModule {
    /// The module name.
    public static let name = "QPACK"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HeaderCompressionModule.name, HTTPCoreModule.name]
}
