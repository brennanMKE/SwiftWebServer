import HeaderCompression
import HTTPCore

/// HPACK header compression for HTTP/2 (RFC 7541).
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HPACKModule {
    /// The module name.
    public static let name = "HPACK"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HeaderCompressionModule.name, HTTPCoreModule.name]
}
