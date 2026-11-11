import HTTPCore
import HTTP1

/// Server, configuration, lifecycle state machine and protocol registry.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HTTPServerModule {
    /// The module name.
    public static let name = "HTTPServer"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name, HTTP1Module.name]
}
