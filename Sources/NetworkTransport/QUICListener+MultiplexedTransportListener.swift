public import HTTPCore

/// `QUICListener` is the production multiplexed listener for `HTTPServer.Server` (#0089).
extension QUICListener: MultiplexedTransportListener {
    /// Binds and starts listening; returns the bound address (a UDP port).
    public func listen() async throws -> TransportAddress {
        let port = try await start()
        return TransportAddress(host: configuration.host, port: port)
    }

    public func connectionInfo(_ connection: QUICConnection) -> ConnectionInfo {
        connection.info
    }

    /// Closes the connection with ``Configuration/closeApplicationError`` (`H3_NO_ERROR`).
    public func refuse(_ connection: QUICConnection) async {
        await connection.close(applicationError: configuration.closeApplicationError)
    }
}
