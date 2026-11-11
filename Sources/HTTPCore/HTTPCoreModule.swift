/// Core types shared by every protocol: bytes, fields, request/response, handler and transport protocols. No Network import.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HTTPCoreModule {
    /// The module name.
    public static let name = "HTTPCore"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = []
}
