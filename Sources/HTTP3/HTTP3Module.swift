import QPACK
import HTTPCore

/// Optional HTTP/3 protocol support (RFC 9114).
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HTTP3Module {
    /// The module name.
    public static let name = "HTTP3"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [QPACKModule.name, HTTPCoreModule.name]
}
