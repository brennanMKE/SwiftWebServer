import HTTPCore

/// Optional request router component.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum RouterModule {
    /// The module name.
    public static let name = "Router"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
