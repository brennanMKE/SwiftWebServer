import HTTP1
import HTTP2
import HTTPCore
import HTTPServer
import HTTPTestSupport
import Synchronization
import Testing

/// #0130: `TLSNegotiated` (HTTPServer) offers HTTP/2 on TLS via ALPN only, so a cleartext
/// connection goes straight to HTTP/1.1 without being sniffed or wrapped.
@Suite(.timeLimit(.minutes(1)))
struct TLSNegotiatedTests {
    var clientStart: ByteBuffer { F.join(F.preface, F.settings()) }

    func serve(_ registry: ProtocolRegistry, _ input: ByteBuffer, info: ConnectionInfo = ConnectionInfo()) async -> ByteBuffer {
        let transport = InMemoryTransport.scripted(input, configuration: .init(info: info))
        await registry.serve(transport, handler: HelloHandler(), context: ConnectionContext(info: info))
        #expect(transport.isClosed)
        return transport.sentBytes
    }

    func text(_ bytes: ByteBuffer) -> String {
        bytes.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
    }

    @Test func offersBothTokensPreferredFirst() {
        #expect(TLSNegotiated<HTTP2, HTTP1>.alpnTokens == ["h2", "http/1.1"])
        let registry = ProtocolRegistry([TLSNegotiated(HTTP2(), fallback: HTTP1())])
        #expect(registry.alpnTokens == ["h2", "http/1.1"])
    }

    @Test func tlsWithH2RunsHTTP2() async {
        let registry = ProtocolRegistry([TLSNegotiated(HTTP2(), fallback: HTTP1())])
        let info = ConnectionInfo(isSecure: true, negotiatedALPN: "h2")
        let frames = H2FrameReader.frames(in: await serve(registry, clientStart, info: info))
        #expect(frames.first == .settings(HTTP2Configuration().localSettings))
    }

    @Test func tlsWithoutH2RunsHTTP1() async {
        let registry = ProtocolRegistry([TLSNegotiated(HTTP2(), fallback: HTTP1())])
        for alpn: String? in ["http/1.1", nil] {
            let info = ConnectionInfo(isSecure: true, negotiatedALPN: alpn)
            let sent = text(await serve(registry, ByteBuffer("GET /x HTTP/1.1\r\nHost: a\r\n\r\n"), info: info))
            #expect(sent.hasPrefix("HTTP/1.1 200"), "\(alpn ?? "no ALPN"): \(sent)")
        }
    }

    /// The HTTP/2 prior-knowledge preface on cleartext is not HTTP/2: it reaches HTTP/1.1.
    @Test func cleartextPrefaceIsNotHTTP2() async {
        let registry = ProtocolRegistry([TLSNegotiated(HTTP2(), fallback: HTTP1())])
        let sent = await serve(registry, clientStart)
        #expect(text(sent).hasPrefix("HTTP/1.1 "), "\(text(sent))")
        #expect(!H2FrameReader.frames(in: sent).contains(.settings(HTTP2Configuration().localSettings)))
    }

    /// Nothing is read ahead on cleartext: the fallback gets the listener's transport itself,
    /// not the replaying wrapper sniffing produces with `[HTTP2(), HTTP1()]`.
    @Test func cleartextIsNotSniffed() async {
        let seen = TransportTypeRecorder()
        let request = ByteBuffer("GET / HTTP/1.1\r\nHost: a\r\n\r\n")

        _ = await serve(ProtocolRegistry([TLSNegotiated(HTTP2(), fallback: seen)]), request)
        #expect(seen.last == "\(InMemoryTransport.self)")

        _ = await serve(ProtocolRegistry([HTTP2(), seen], sniffTimeout: .seconds(5)), request)
        #expect(seen.last != "\(InMemoryTransport.self)", "sniffing wraps the transport: \(seen.last)")
    }
}

/// A fallback protocol that records the transport type it was handed and closes.
final class TransportTypeRecorder: ConnectionProtocol {
    private let state = Mutex("")
    var last: String { state.withLock { $0 } }

    static var alpnTokens: [String] { ["http/1.1"] }
    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        bytes.readableBytes == 0 ? .needMoreBytes : .match
    }

    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        state.withLock { $0 = "\(T.self)" }
        await t.close(.normal)
    }
}
