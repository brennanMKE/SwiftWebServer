import HTTPCore

/// JSON configuration file to components (Foundation; CLI only).
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum ConfigFileModule {
    /// The module name.
    public static let name = "ConfigFile"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
