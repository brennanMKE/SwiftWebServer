import HTTPCore
import Network

/// TCP socket options shared by ``TCPListener`` (applied to every accepted connection) and
/// ``TCPTransport/connect(host:port:configuration:)``.
public struct TCPConfiguration: Sendable, Hashable {
    /// TCP keep-alive probing (`SO_KEEPALIVE` with `TCP_KEEPALIVE`, `TCP_KEEPINTVL`,
    /// `TCP_KEEPCNT`).
    public struct KeepAlive: Sendable, Hashable {
        /// Seconds of idleness before the first probe.
        public var idle: Int
        /// Seconds between unanswered probes.
        public var interval: Int
        /// Unanswered probes before the connection is dropped.
        public var count: Int

        public init(idle: Int = 60, interval: Int = 10, count: Int = 6) {
            precondition(idle > 0 && interval > 0 && count > 0, "keep-alive values must be positive")
            self.idle = idle
            self.interval = interval
            self.count = count
        }
    }

    /// `TCP_NODELAY`: send small segments immediately instead of coalescing them (Nagle).
    /// On by default; the HTTP layers already batch writes per pipelined response set.
    public var noDelay: Bool
    /// Keep-alive probing, or `nil` to leave it off.
    public var keepAlive: KeepAlive?
    /// Seconds an outbound connect may take before it fails, or `nil` for the system default.
    /// Has no effect on accepted connections.
    public var connectionTimeout: Int?
    /// Allows binding a local port that is still in `TIME_WAIT` (`SO_REUSEADDR`).
    public var allowLocalEndpointReuse: Bool

    public init(
        noDelay: Bool = true,
        keepAlive: KeepAlive? = nil,
        connectionTimeout: Int? = nil,
        allowLocalEndpointReuse: Bool = true
    ) {
        if let connectionTimeout { precondition(connectionTimeout > 0, "connectionTimeout must be positive") }
        self.noDelay = noDelay
        self.keepAlive = keepAlive
        self.connectionTimeout = connectionTimeout
        self.allowLocalEndpointReuse = allowLocalEndpointReuse
    }

    /// Network.framework parameters for plain TCP with these options. `localEndpoint` becomes
    /// `requiredLocalEndpoint` (the listener's bind address).
    func makeParameters(localEndpoint: NWEndpoint? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = noDelay
        if let keepAlive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = keepAlive.idle
            tcp.keepaliveInterval = keepAlive.interval
            tcp.keepaliveCount = keepAlive.count
        }
        if let connectionTimeout {
            tcp.connectionTimeout = connectionTimeout
        }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = allowLocalEndpointReuse
        parameters.includePeerToPeer = false
        if let localEndpoint {
            parameters.requiredLocalEndpoint = localEndpoint
        }
        return parameters
    }
}

// MARK: - Mapping Network.framework values

extension TransportError {
    /// Maps a Network.framework error to the transport vocabulary.
    init(_ error: NWError) {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNRESET, .EPIPE, .ECONNABORTED, .ENOTCONN, .ENETRESET:
                self = .connectionReset
            case .ETIMEDOUT:
                self = .timedOut
            case .ECANCELED:
                self = .closed
            default:
                self = .failed(code: code.rawValue)
            }
        case .dns(let code):
            self = .failed(code: Int32(truncatingIfNeeded: code))
        case .tls(let status):
            self = .failed(code: status)
        default:
            self = .failed(code: -1)
        }
    }
}

extension TransportAddress {
    /// The numeric host and port of an `NWEndpoint.hostPort`, or `nil` for other endpoints.
    init?(_ endpoint: NWEndpoint?) {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        let name: String
        switch host {
        case .ipv4(let address):
            name = "\(address)"
        case .ipv6(let address):
            // Drop a scope suffix such as `%lo0`; ConnectionInfo carries numeric addresses.
            let text = "\(address)"
            name = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        case .name(let value, _):
            name = value
        @unknown default:
            name = "\(host)"
        }
        self.init(host: name, port: port.rawValue)
    }
}
