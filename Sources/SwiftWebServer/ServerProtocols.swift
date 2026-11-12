import ConfigFile
import HTTP1
#if HTTP2
import HTTP2
#endif
import HTTPCore

/// The byte-stream protocols the shipped server registers (#0119).
///
/// - HTTP/2 off: `[HTTP1]`.
/// - HTTP/2 on, cleartext off (the default): one protocol, ``TLSNegotiatedHTTP2``, which
///   offers `h2` and `http/1.1` on TLS and is HTTP/1.1 on cleartext. With a single protocol
///   the registry neither sniffs nor wraps cleartext connections in a replay transport
///   (#0042 Gotchas), so the default cleartext path costs what HTTP/1.1 alone costs.
/// - HTTP/2 and cleartext on: `[HTTP2, HTTP1]`. HTTP/2 first: HTTP/1.1's sniff also matches
///   the `PRI * HTTP/2.0` preface. Every cleartext connection is then sniffed.
enum ServerProtocols {
    static func make(_ settings: ServerSettings) throws(ConfigFileError) -> [any ConnectionProtocol] {
        let http1 = HTTP1(configuration: settings.http1Configuration)
        guard let http2Settings = settings.http2 else { return [http1] }
        #if HTTP2
        let http2 = HTTP2(configuration: configuration(http2Settings, settings))
        if http2Settings.cleartext { return [http2, http1] }
        return [TLSNegotiatedHTTP2(http2: http2, http1: http1)]
        #else
        if http2Settings.cleartext {
            throw ConfigFileError(key: "http2.cleartext", "\"http2.cleartext\": this build has no HTTP/2 (package trait HTTP2 is off)")
        }
        return [http1]
        #endif
    }

    #if HTTP2
    static func configuration(_ http2: ServerSettings.HTTP2Settings, _ settings: ServerSettings) -> HTTP2Configuration {
        var limits = HTTP2AbuseLimits()
        let overrides = http2.abuseLimits
        if let value = overrides.window { limits.window = value }
        if let value = overrides.maxResetStreamsPerWindow { limits.maxResetStreamsPerWindow = value }
        if let value = overrides.maxControlFramesPerWindow { limits.maxControlFramesPerWindow = value }
        if let value = overrides.maxEmptyFramesPerWindow { limits.maxEmptyFramesPerWindow = value }
        if let value = overrides.maxWindowUpdatesPerWindow { limits.maxWindowUpdatesPerWindow = value }
        if let value = overrides.maxSmallDataFramesPerWindow { limits.maxSmallDataFramesPerWindow = value }
        if let value = overrides.smallDataFrameSize { limits.smallDataFrameSize = value }
        if let value = overrides.windowStallTimeout { limits.windowStallTimeout = value }
        if let value = overrides.maxStreamsPerConnection { limits.maxStreamsPerConnection = value }
        return HTTP2Configuration(
            cleartext: http2.cleartext,
            maxConcurrentStreams: http2.maxConcurrentStreams,
            initialWindowSize: UInt32(http2.initialWindowSize),
            maxRequestBodySize: http2.maxRequestBodySize ?? settings.maxBodySize,
            // An idle HTTP/2 connection holds a connection slot like an idle keep-alive one,
            // so it gets the same limit (GOAWAY when no stream ran for that long).
            idleTimeout: settings.timeouts.idle,
            abuseLimits: limits)
    }
    #endif
}

#if HTTP2
/// HTTP/2 on TLS only: one registered protocol listing `h2` and `http/1.1`, so the TLS
/// listener offers both via ALPN (#0088) while a cleartext connection goes straight to
/// HTTP/1.1 with nothing read ahead. A TLS connection that negotiated `h2` runs HTTP/2;
/// anything else (`http/1.1`, no ALPN) runs HTTP/1.1.
struct TLSNegotiatedHTTP2: ConnectionProtocol {
    let http2: HTTP2
    let http1: HTTP1

    static var alpnTokens: [String] { HTTP2.alpnTokens + HTTP1.alpnTokens }

    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        HTTP1.matchesCleartextPreface(bytes)
    }

    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        let info = t.info
        if info.isSecure, let alpn = info.negotiatedALPN, HTTP2.alpnTokens.contains(alpn) {
            await http2.run(t, handler: handler, context: context)
        } else {
            await http1.run(t, handler: handler, context: context)
        }
    }
}
#endif
