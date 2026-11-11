import HTTPCore

/// Optional WebSockets (RFC 6455; RFC 8441/9220 via the tunnel hook).
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum WebSocketsModule {
    /// The module name.
    public static let name = "WebSockets"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
