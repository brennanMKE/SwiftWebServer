import HTTPCore

/// HTTP/1.1 parser, serializer, chunked codec, connection state machine and runner.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HTTP1Module {
    /// The module name.
    public static let name = "HTTP1"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
