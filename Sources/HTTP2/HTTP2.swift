public import HTTPCore

/// HTTP/2 (RFC 9113) as a ``ConnectionProtocol``: TLS connections that negotiated ALPN `h2`,
/// and cleartext connections that start with the connection preface (prior knowledge,
/// RFC 9113 §3.3; no `Upgrade: h2c`).
///
/// ```swift
/// let server = Server(configuration: config, listeners: [listener],
///                     protocols: [HTTP2(), HTTP1()], handler: app)
/// ```
///
/// Register it before ``HTTP1`` (HTTP1's sniff also matches `PRI * HTTP/2.0`); a TLS listener
/// then offers `h2, http/1.1` (``ProtocolRegistry/alpnTokens``).
///
/// This first step (#0042) sends the server's SETTINGS, checks the client preface and that
/// the first frame after it is SETTINGS (`GOAWAY(PROTOCOL_ERROR)` otherwise), and then closes
/// with `GOAWAY(NO_ERROR)`: the SETTINGS exchange (#0043) and the frame loop (#0044) follow.
public struct HTTP2: ConnectionProtocol {
    public var configuration: HTTP2Configuration

    public init(configuration: HTTP2Configuration = HTTP2Configuration()) {
        self.configuration = configuration
    }

    public static var alpnTokens: [String] { ["h2"] }

    /// Matches the 24-octet connection preface (``HTTP2Preface``): `needMoreBytes` for a proper
    /// prefix, `noMatch` at the first octet that differs.
    public static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        HTTP2Preface.match(bytes)
    }

    public func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        if !t.info.isSecure && !configuration.cleartext {
            await t.close(.protocolError)
            return
        }
        var out = ByteBuffer()
        HTTP2FrameEncoder.encodeSettings(configuration.localSettings, into: &out)
        do {
            try await t.send(out, endOfStream: false)
        } catch {
            await t.close(.abort)
            return
        }
        guard let error = await checkPreface(t) else {
            await t.close(.abort)   // The peer left or the transport failed.
            return
        }
        out.clear()
        HTTP2FrameEncoder.encodeGoaway(lastStreamID: .connection, error: error, into: &out)
        try? await t.send(out, endOfStream: false)
        await t.close(error.code == .noError ? .normal : .protocolError)
    }

    /// Reads the preface and the first frame. Returns the error to close with (`NO_ERROR` when
    /// both are valid), or `nil` when input ended or failed first.
    func checkPreface<T: ByteStreamTransport>(_ t: T) async -> HTTP2Error? {
        var buffer = ByteBuffer(capacity: configuration.receiveSize)
        var prefaceChecked = false
        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        while true {
            if !prefaceChecked {
                switch HTTP2Preface.match(buffer) {
                case .noMatch:
                    return .connection(.protocolError, reason: "invalid connection preface")
                case .match:
                    buffer.moveReaderIndex(forwardBy: HTTP2Preface.count)
                    prefaceChecked = true
                case .needMoreBytes:
                    break
                }
            }
            while prefaceChecked && buffer.readableBytes > 0 {
                let output: HTTP2FrameParser.Output
                do throws(HTTP2Error) {
                    output = try parser.parse(buffer)
                } catch {
                    return error
                }
                buffer.moveReaderIndex(forwardBy: output.consumed)
                switch output.event {
                case .needsMoreData:
                    break
                case .settings:
                    return .connection(.noError, reason: "the frame loop is not implemented yet")
                default:
                    return .connection(.protocolError, reason: "first frame after the preface is not SETTINGS")
                }
            }
            do {
                guard try await t.receive(into: &buffer, maxLength: configuration.receiveSize) > 0 else { return nil }
            } catch {
                return nil
            }
        }
    }
}
