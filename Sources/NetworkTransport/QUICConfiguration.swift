import HTTPCore
import Dispatch
import Foundation
import Network
import Security

/// QUIC transport settings shared by ``QUICListener`` (every accepted connection) and
/// ``QUICConnection/connect(host:port:configuration:)`` (issue #0098).
///
/// The flow-control windows bound what the *peer* can make us buffer: at most
/// `initialMaxData` bytes per connection, and at most `maxStreamsBidirectional` +
/// `maxStreamsUnidirectional` peer streams open at once, because stream credit (MAX_STREAMS)
/// is only granted back when a peer stream finishes.
public struct QUICConfiguration: Sendable, Hashable {
    /// ALPN protocols offered (client) or accepted (server). HTTP/3 is `"h3"`.
    public var alpn: [String]
    /// Peer-initiated bidirectional streams that may be open at once. Sent as
    /// `initial_max_streams_bidi`; the adapter raises the cumulative limit by one each time a
    /// peer bidirectional stream finishes (Network.framework does not, spike gotcha 5).
    public var maxStreamsBidirectional: Int
    /// Peer-initiated unidirectional streams that may be open at once (`initial_max_streams_uni`),
    /// replenished the same way. HTTP/3 needs at least 3.
    public var maxStreamsUnidirectional: Int
    /// Connection-wide receive window (`initial_max_data`).
    public var initialMaxData: Int
    /// Receive window of each peer-opened bidirectional stream
    /// (`initial_max_stream_data_bidi_remote`).
    public var initialMaxStreamDataBidirectionalRemote: Int
    /// Receive window of each locally opened bidirectional stream
    /// (`initial_max_stream_data_bidi_local`).
    public var initialMaxStreamDataBidirectionalLocal: Int
    /// Receive window of each peer-opened unidirectional stream
    /// (`initial_max_stream_data_uni`).
    public var initialMaxStreamDataUnidirectional: Int
    /// Idle timeout in milliseconds (`max_idle_timeout`).
    public var idleTimeoutMilliseconds: Int
    /// The most bytes one `send` hands to Network.framework before waiting for its completion.
    ///
    /// Network.framework accepts about 2–6 MiB per stream beyond the peer's flow-control window
    /// before send completions stall (spike Q7), and that buffer is not configurable. A larger
    /// `send` is split into chunks of this size and each chunk waits for `.contentProcessed`,
    /// so the adapter itself never holds more than one chunk per stream beyond what
    /// Network.framework has accepted.
    public var sendChunkSize: Int
    /// The most peer streams held per connection that ``QUICConnection/inboundStreams`` has not
    /// yet taken (still opening, or ready and waiting). A stream beyond it is reset with
    /// ``rejectedStreamErrorCode``. `nil` means the stream limits plus 2 (Network.framework
    /// clients open one implicit stream that never becomes ready, spike gotcha 8).
    public var pendingStreamLimit: Int?
    /// RESET_STREAM / STOP_SENDING code for streams refused because the pending queue is full
    /// (default `H3_REQUEST_REJECTED`, 0x10b).
    public var rejectedStreamErrorCode: UInt64

    public init(
        alpn: [String] = ["h3"],
        maxStreamsBidirectional: Int = 100,
        maxStreamsUnidirectional: Int = 8,
        initialMaxData: Int = 4 << 20,
        initialMaxStreamDataBidirectionalRemote: Int = 256 << 10,
        initialMaxStreamDataBidirectionalLocal: Int = 256 << 10,
        initialMaxStreamDataUnidirectional: Int = 64 << 10,
        idleTimeoutMilliseconds: Int = 30_000,
        sendChunkSize: Int = 64 << 10,
        pendingStreamLimit: Int? = nil,
        rejectedStreamErrorCode: UInt64 = 0x10b
    ) {
        precondition(!alpn.isEmpty, "alpn must not be empty")
        precondition(maxStreamsBidirectional >= 0 && maxStreamsUnidirectional >= 0, "stream limits must not be negative")
        precondition(sendChunkSize > 0, "sendChunkSize must be positive")
        if let pendingStreamLimit { precondition(pendingStreamLimit > 0, "pendingStreamLimit must be positive") }
        self.alpn = alpn
        self.maxStreamsBidirectional = maxStreamsBidirectional
        self.maxStreamsUnidirectional = maxStreamsUnidirectional
        self.initialMaxData = initialMaxData
        self.initialMaxStreamDataBidirectionalRemote = initialMaxStreamDataBidirectionalRemote
        self.initialMaxStreamDataBidirectionalLocal = initialMaxStreamDataBidirectionalLocal
        self.initialMaxStreamDataUnidirectional = initialMaxStreamDataUnidirectional
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        self.sendChunkSize = sendChunkSize
        self.pendingStreamLimit = pendingStreamLimit
        self.rejectedStreamErrorCode = rejectedStreamErrorCode
    }

    /// The effective pending-stream bound.
    var effectivePendingStreamLimit: Int {
        pendingStreamLimit ?? (maxStreamsBidirectional + maxStreamsUnidirectional + 2)
    }

    /// QUIC options with these transport parameters (bidirectional, the group default).
    func makeOptions() -> NWProtocolQUIC.Options {
        let quic = NWProtocolQUIC.Options(alpn: alpn)
        quic.initialMaxStreamsBidirectional = maxStreamsBidirectional
        quic.initialMaxStreamsUnidirectional = maxStreamsUnidirectional
        quic.initialMaxData = initialMaxData
        quic.initialMaxStreamDataBidirectionalRemote = initialMaxStreamDataBidirectionalRemote
        quic.initialMaxStreamDataBidirectionalLocal = initialMaxStreamDataBidirectionalLocal
        quic.initialMaxStreamDataUnidirectional = initialMaxStreamDataUnidirectional
        quic.idleTimeout = idleTimeoutMilliseconds
        return quic
    }

    /// Options for a locally opened unidirectional stream (`NWConnection(from:using:)`).
    func makeUnidirectionalStreamOptions() -> NWProtocolQUIC.Options {
        let quic = NWProtocolQUIC.Options(alpn: alpn)
        quic.direction = .unidirectional
        return quic
    }
}

/// How a QUIC client checks the server's certificate.
public enum QUICPeerVerification: Sendable, Hashable {
    /// The system's default trust evaluation.
    case system
    /// Accept exactly this leaf certificate (DER), without any trust evaluation. For tests
    /// against the self-signed test identity: no keychain or trust-settings change is needed.
    case pinnedCertificate([UInt8])
}

/// Settings for ``QUICConnection/connect(host:port:configuration:)``.
public struct QUICClientConfiguration: Sendable, Hashable {
    public var quic: QUICConfiguration
    public var peerVerification: QUICPeerVerification
    /// TLS server name (SNI), or `nil` for none.
    public var serverName: String?
    /// How long the handshake may take before `connect` throws ``TransportError/timedOut``.
    public var connectTimeout: Duration

    public init(
        quic: QUICConfiguration = QUICConfiguration(),
        peerVerification: QUICPeerVerification = .system,
        serverName: String? = nil,
        connectTimeout: Duration = .seconds(10)
    ) {
        self.quic = quic
        self.peerVerification = peerVerification
        self.serverName = serverName
        self.connectTimeout = connectTimeout
    }

    func makeParameters() -> NWParameters {
        let quic = self.quic.makeOptions()
        let security = quic.securityProtocolOptions
        if let serverName {
            sec_protocol_options_set_tls_server_name(security, serverName)
        }
        if case .pinnedCertificate(let expected) = peerVerification {
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                complete(Self.leafCertificate(of: trust) == expected)
            }, DispatchQueue.global())
        }
        let parameters = NWParameters(quic: quic)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// The DER bytes of the peer's leaf certificate. Reads the chain only; no evaluation.
    private static func leafCertificate(of trust: sec_trust_t) -> [UInt8]? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return [UInt8](SecCertificateCopyData(leaf) as Data)
    }
}

extension TransportError {
    /// Maps a Network.framework error on a QUIC stream or connection. Besides the TCP mapping,
    /// the errors seen when the peer closes the connection (`ENETDOWN`, `ECONNREFUSED`,
    /// `EINVAL` on the group, spike gotcha 10) count as ``connectionReset``.
    init(quic error: NWError) {
        if case .posix(let code) = error {
            switch code {
            case .ENETDOWN, .ECONNREFUSED, .EINVAL, .EHOSTDOWN, .ENETUNREACH:
                self = .connectionReset
                return
            default:
                break
            }
        }
        self.init(error)
    }
}

/// `streamApplicationErrorCode` before any reset (UInt64.max) means "no code".
func quicCode(_ value: UInt64) -> UInt64? {
    value == .max ? nil : value
}

extension NWConnection {
    var quicMetadata: NWProtocolQUIC.Metadata? {
        metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
    }
}

extension NWConnectionGroup {
    var quicMetadata: NWProtocolQUIC.Metadata? {
        metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
    }
}
