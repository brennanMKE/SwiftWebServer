import HTTPCore
import HTTP1

/// Test support: in-memory transports and a reference parser.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum HTTPTestSupportModule {
    /// The module name.
    public static let name = "HTTPTestSupport"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name, HTTP1Module.name]
}
