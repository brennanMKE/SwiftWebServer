import HTTPCore

/// Optional virtual host routing component.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum VirtualHostsModule {
    /// The module name.
    public static let name = "VirtualHosts"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
