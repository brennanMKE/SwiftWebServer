public import HTTPCore

/// A protocol offered on TLS only, chosen by ALPN; every other connection runs `Fallback`
/// (#0119, made public in #0130).
///
/// Register it as the server's only byte-stream protocol:
///
/// ```swift
/// Server(listeners: …, protocols: [TLSNegotiated(HTTP2(), fallback: HTTP1())]) { … }
/// ```
///
/// A TLS listener then offers both protocols' ALPN tokens (`h2`, `http/1.1`). A TLS connection
/// that negotiated one of `Preferred`'s tokens runs `Preferred`; anything else (`http/1.1`,
/// no ALPN, cleartext) runs `Fallback`. Because the registry holds a single protocol, a
/// cleartext connection is neither sniffed nor wrapped in a replay transport (#0042 Gotchas):
/// the cleartext path costs what `Fallback` alone costs.
///
/// Compare `[HTTP2(), HTTP1()]`, which also serves HTTP/2 prior knowledge (h2c) on cleartext
/// and pays for it by sniffing the first bytes of every cleartext connection.
public struct TLSNegotiated<Preferred: ConnectionProtocol, Fallback: ConnectionProtocol>: ConnectionProtocol {
    /// Runs TLS connections that negotiated one of `Preferred.alpnTokens`.
    public let preferred: Preferred
    /// Runs every other connection.
    public let fallback: Fallback

    public init(_ preferred: Preferred, fallback: Fallback) {
        self.preferred = preferred
        self.fallback = fallback
    }

    /// `Preferred`'s tokens first (the server's preference), then `Fallback`'s, without
    /// duplicates.
    public static var alpnTokens: [String] {
        var tokens = Preferred.alpnTokens
        for token in Fallback.alpnTokens where !tokens.contains(token) { tokens.append(token) }
        return tokens
    }

    /// Cleartext is `Fallback`'s. Only consulted when other protocols are registered too.
    public static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        Fallback.matchesCleartextPreface(bytes)
    }

    public func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        let info = t.info
        if info.isSecure, let alpn = info.negotiatedALPN, Preferred.alpnTokens.contains(alpn) {
            await preferred.run(t, handler: handler, context: context)
        } else {
            await fallback.run(t, handler: handler, context: context)
        }
    }
}
