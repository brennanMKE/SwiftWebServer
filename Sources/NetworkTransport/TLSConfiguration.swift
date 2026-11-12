public import HTTPCore
import Dispatch
import Foundation
import Network
import Security

/// Server-side TLS settings for a ``TCPListener`` (#0087, legacy #0057).
///
/// TLS runs inside Network.framework (`NWProtocolTLS` over TCP, docs/ROADMAP.md §2): the
/// listener's accepted connections are handed over only after the handshake, with the
/// negotiated ALPN token and TLS version in ``TCPTransport/info``.
///
/// The identity is a ``TLSIdentity``, imported from PKCS#12 **in memory only**
/// (`kSecImportToMemoryOnly`); nothing here reads or changes keychain items or trust settings
/// (AGENTS.md).
public struct TLSConfiguration: Sendable {
    /// Verifies client certificates (mutual TLS). Off unless set.
    public struct ClientAuthentication: Sendable {
        /// Whether a client must present a certificate. When false, a client without one is
        /// accepted and ``verify`` runs only for clients that send one.
        public var required: Bool
        /// Decides whether to accept a client's certificate chain (DER, leaf first). Called on
        /// a Network.framework queue during the handshake; must not block.
        public var verify: @Sendable (_ chainDER: [[UInt8]]) -> Bool

        public init(required: Bool = true, verify: @escaping @Sendable (_ chainDER: [[UInt8]]) -> Bool) {
            self.required = required
            self.verify = verify
        }
    }

    /// The server certificate and private key.
    public var identity: TLSIdentity
    /// The lowest TLS version accepted. TLS 1.2 by default; Network.framework negotiates the
    /// highest version both sides support, so TLS 1.3 is used whenever the client offers it.
    public var minimumVersion: TLSVersion
    /// The highest TLS version offered, or `nil` for the system's highest (TLS 1.3).
    public var maximumVersion: TLSVersion?
    /// ALPN tokens accepted, in server preference order. Build it from the server's protocol
    /// registry (`ProtocolRegistry.alpnTokens` in HTTPServer) so every registered protocol is
    /// offered; HTTP/1.1 alone is `["http/1.1"]`.
    public var alpn: [String]
    /// Client certificate checking; `nil` (the default) asks for no client certificate.
    public var clientAuthentication: ClientAuthentication?
    /// How long an accepted connection may spend in the TCP and TLS handshakes before it is
    /// reset. Bounds clients that connect and never finish the handshake, which would otherwise
    /// hold a slot of the listener's pending-connection queue.
    public var handshakeTimeout: Duration

    public init(
        identity: TLSIdentity,
        minimumVersion: TLSVersion = .v1_2,
        maximumVersion: TLSVersion? = nil,
        alpn: [String] = ["http/1.1"],
        clientAuthentication: ClientAuthentication? = nil,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        precondition(handshakeTimeout > .zero, "handshakeTimeout must be positive")
        self.identity = identity
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.alpn = alpn
        self.clientAuthentication = clientAuthentication
        self.handshakeTimeout = handshakeTimeout
    }

    /// Loads the identity from a PKCS#12 file (in memory only). Throws
    /// ``TLSIdentityError/fileUnreadable(path:)`` for a missing file and
    /// ``TLSIdentityError/importFailed(status:)`` (`errSecAuthFailed`) for a wrong password.
    public init(
        pkcs12Path: String,
        password: String,
        alpn: [String] = ["http/1.1"]
    ) throws(TLSIdentityError) {
        self.init(identity: try TLSIdentity(pkcs12Path: pkcs12Path, password: password), alpn: alpn)
    }

    /// Network.framework TLS options for the listener.
    func makeOptions() throws(TransportError) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        guard let secIdentity = identity.makeSecIdentity() else { throw .failed(code: -1) }
        sec_protocol_options_set_local_identity(options, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(options, minimumVersion.protocolVersion)
        if let maximumVersion {
            sec_protocol_options_set_max_tls_protocol_version(options, maximumVersion.protocolVersion)
        }
        for token in alpn {
            sec_protocol_options_add_tls_application_protocol(options, token)
        }
        if let clientAuthentication {
            sec_protocol_options_set_peer_authentication_required(options, clientAuthentication.required)
            let verify = clientAuthentication.verify
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                complete(verify(certificateChain(of: trust)))
            }, DispatchQueue.global())
        }
        return tls
    }
}

/// Client-side TLS settings for ``TCPTransport/connect(host:port:configuration:tls:)``: tests and
/// tools that talk to a ``TCPListener`` with TLS.
public struct TLSClientConfiguration: Sendable, Hashable {
    /// ALPN tokens offered, in preference order. Empty offers none.
    public var alpn: [String]
    /// Accept exactly this leaf certificate (DER) with no trust evaluation, for the self-signed
    /// test identity (no keychain or trust-settings change); `nil` uses the system's evaluation.
    public var pinnedCertificate: [UInt8]?
    /// TLS server name (SNI), or `nil` for none.
    public var serverName: String?
    /// The lowest TLS version offered.
    public var minimumVersion: TLSVersion
    /// The highest TLS version offered, or `nil` for the system's highest.
    public var maximumVersion: TLSVersion?

    public init(
        alpn: [String] = ["http/1.1"],
        pinnedCertificate: [UInt8]? = nil,
        serverName: String? = nil,
        minimumVersion: TLSVersion = .v1_2,
        maximumVersion: TLSVersion? = nil
    ) {
        self.alpn = alpn
        self.pinnedCertificate = pinnedCertificate
        self.serverName = serverName
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
    }

    func makeOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for token in alpn {
            sec_protocol_options_add_tls_application_protocol(options, token)
        }
        if let serverName {
            sec_protocol_options_set_tls_server_name(options, serverName)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, minimumVersion.protocolVersion)
        if let maximumVersion {
            sec_protocol_options_set_max_tls_protocol_version(options, maximumVersion.protocolVersion)
        }
        if let expected = pinnedCertificate {
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                complete(certificateChain(of: trust).first == expected)
            }, DispatchQueue.global())
        }
        return tls
    }
}

extension TLSVersion {
    /// The Security framework value. Versions it does not name map to TLS 1.2.
    var protocolVersion: tls_protocol_version_t {
        tls_protocol_version_t(rawValue: rawValue) ?? .TLSv12
    }
}

/// The DER bytes of the peer's certificate chain, leaf first. Reads the chain only; no trust
/// evaluation, no keychain access.
func certificateChain(of trust: sec_trust_t) -> [[UInt8]] {
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] else { return [] }
    return chain.map { [UInt8](SecCertificateCopyData($0) as Data) }
}
