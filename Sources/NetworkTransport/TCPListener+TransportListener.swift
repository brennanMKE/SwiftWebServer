public import HTTPCore

/// `TCPListener` is the production listener for `HTTPServer.Server` (#0079).
extension TCPListener: TransportListener {
    /// Binds and starts listening; returns the bound loopback (or configured) address.
    public func listen() async throws -> TransportAddress {
        let port = try await start()
        return TransportAddress(host: configuration.host, port: port)
    }
}
