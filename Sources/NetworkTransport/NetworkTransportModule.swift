import HTTPCore

/// Network.framework adapters: TCP, TLS with ALPN, and QUIC.
///
/// Placeholder namespace declared by the M0 package restructure (docs/ROADMAP.md §5.1).
public enum NetworkTransportModule {
    /// The module name.
    public static let name = "NetworkTransport"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
