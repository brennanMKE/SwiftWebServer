import HTTPCore

/// Network.framework adapters: TCP, TLS with ALPN, and QUIC.
///
/// TCP: ``TCPListener``, ``TCPTransport``, ``TCPConfiguration`` (#0078). QUIC: ``QUICListener``,
/// ``QUICConnection``, ``QUICStreamTransport`` (#0098). TLS identities: ``TLSIdentity`` (#0072).
/// TLS over TCP follows (#0087).
public enum NetworkTransportModule {
    /// The module name.
    public static let name = "NetworkTransport"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [HTTPCoreModule.name]
}
