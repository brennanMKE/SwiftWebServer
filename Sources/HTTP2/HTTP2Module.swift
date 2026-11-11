import HPACK
import HTTPCore

/// Optional HTTP/2 protocol support (RFC 9113).
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HTTP2Module {
    /// The module name.
    public static let name = "HTTP2"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HPACKModule.name, HTTPCoreModule.name]
}
