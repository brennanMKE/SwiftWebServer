import HTTP1
import HTTPCore
import HTTPServer
import StaticFiles

/// JSON configuration file to components (Foundation; CLI only, #0086).
///
/// ``ConfigFile`` parses `http-config.json` into ``ServerSettings``; the settings map to the
/// server's configuration values and middleware chain (`ServerSettings+Components.swift`).
public enum ConfigFileModule {
    /// The module name.
    public static let name = "ConfigFile"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [
        HTTPCoreModule.name, HTTP1Module.name, HTTPServerModule.name, StaticFilesModule.name,
    ]
}
