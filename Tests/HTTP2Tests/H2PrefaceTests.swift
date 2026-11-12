import HTTP1
@testable import HTTP2
import HTTPCore
import HTTPServer
import HTTPTestSupport
import Testing

/// #0042: the connection preface, cleartext routing through the protocol registry, and the
/// rule that the first frame after it is SETTINGS.
@Suite(.timeLimit(.minutes(1)))
struct H2PrefaceTests {
    let preface = HTTP2Preface.bytes

    @Test func prefaceIsTheRFCBytes() {
        #expect(preface == Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
        #expect(preface.count == 24)
        #expect(HTTP2.alpnTokens == ["h2"])
    }

    @Test func sniffMatchesOnlyTheWholePreface() {
        for count in 0..<preface.count {
            #expect(HTTP2.matchesCleartextPreface(ByteBuffer(bytes: preface.prefix(count))) == .needMoreBytes,
                    "prefix of \(count)")
        }
        #expect(HTTP2.matchesCleartextPreface(ByteBuffer(bytes: preface)) == .match)
        #expect(HTTP2.matchesCleartextPreface(ByteBuffer(bytes: preface + [0, 0, 0, 4])) == .match)
        // A wrong byte anywhere is a mismatch as soon as it arrives.
        for position in 0..<preface.count {
            var bytes = Array(preface.prefix(position + 1))
            bytes[position] ^= 0x20
            #expect(HTTP2.matchesCleartextPreface(ByteBuffer(bytes: bytes)) == .noMatch, "byte \(position)")
        }
        #expect(HTTP2.matchesCleartextPreface(ByteBuffer("GET / HTTP/1.1\r\n")) == .noMatch)
        #expect(HTTP2.matchesCleartextPreface(ByteBuffer("PRI / HTTP/1.1\r\n")) == .noMatch)
    }

    /// The registry asks protocols in order; HTTP/2's undecided prefix holds off HTTP/1.1,
    /// which would otherwise match `PRI `.
    @Test func registryWaitsForTheWholePreface() {
        let registry = ProtocolRegistry([HTTP2(), HTTP1()])
        #expect(registry.alpnTokens == ["h2", "http/1.1"])
        for count in 0..<preface.count {
            #expect(registry.select(alpn: nil, preface: ByteBuffer(bytes: preface.prefix(count))) == .needMoreBytes)
        }
        #expect(registry.select(alpn: nil, preface: ByteBuffer(bytes: preface)) == .selected(index: 0))
        #expect(registry.select(alpn: nil, preface: ByteBuffer("GET / HTTP/1.1\r\n")) == .selected(index: 1))
        #expect(registry.select(alpn: nil, preface: ByteBuffer("PRI / HTTP/1.1\r\n")) == .selected(index: 1))
        #expect(registry.select(alpn: "h2", secure: true, preface: ByteBuffer()) == .selected(index: 0))
        #expect(registry.select(alpn: nil, secure: true, preface: ByteBuffer()) == .selected(index: 1))
    }

    // MARK: Routing over an in-memory transport

    /// Serves `input` (then end of stream) through `[HTTP2(), HTTP1()]` and returns what the
    /// server sent.
    func route(_ input: ByteBuffer, chunking: InMemoryTransport.Chunking = .unlimited,
               http2: HTTP2Configuration = HTTP2Configuration(), info: ConnectionInfo = ConnectionInfo()) async -> ByteBuffer {
        let transport = InMemoryTransport.scripted(input, configuration: .init(receiveChunking: chunking, info: info))
        let registry = ProtocolRegistry([HTTP2(configuration: http2), HTTP1()], sniffTimeout: .seconds(5))
        await registry.serve(transport, handler: HelloHandler(), context: ConnectionContext(info: info))
        #expect(transport.isClosed)
        return transport.sentBytes
    }

    var clientStart: ByteBuffer { F.join(F.preface, F.settings()) }

    @Test func prefaceRoutesToHTTP2() async {
        let frames = H2FrameReader.frames(in: await route(clientStart))
        // Our SETTINGS first; the frame loop (#0044) is not there yet, so a clean GOAWAY.
        #expect(frames == [.settings(HTTP2Configuration().localSettings), .goaway(last: 0, .noError, debug: "NO_ERROR")])
    }

    @Test func prefaceSplitAtEveryByteRoutesToHTTP2() async {
        let input = clientStart
        let expected: [H2Frame] = [.settings(HTTP2Configuration().localSettings), .goaway(last: 0, .noError, debug: "NO_ERROR")]
        var chunkings: [InMemoryTransport.Chunking] = [.bytewise]
        for split in 1..<input.readableBytes { chunkings.append(.pattern([split, .max])) }
        for chunking in chunkings {
            let frames = H2FrameReader.frames(in: await route(input, chunking: chunking))
            #expect(frames == expected, "\(chunking)")
        }
    }

    @Test func http11RequestRoutesToHTTP1() async {
        for chunking: InMemoryTransport.Chunking in [.unlimited, .bytewise, .pattern([3, .max])] {
            let sent = await route(ByteBuffer("GET /x HTTP/1.1\r\nHost: a\r\n\r\n"), chunking: chunking)
            let text = sent.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
            #expect(text.hasPrefix("HTTP/1.1 200"), "\(text)")
            #expect(text.hasSuffix("hello /x"), "\(text)")
        }
    }

    @Test func shortInputThenCloseIsClosedSilently() async {
        for count in [0, 1, 4, 10, 23] {
            let sent = await route(ByteBuffer(bytes: preface.prefix(count)), chunking: .bytewise)
            #expect(sent.readableBytes == 0, "\(count) bytes")
        }
    }

    /// Over TLS there is no sniff: a wrong preface reaches HTTP/2, which answers
    /// GOAWAY(PROTOCOL_ERROR) after its own SETTINGS.
    @Test func invalidPrefaceOverTLSIsAProtocolError() async {
        var bad = preface
        bad[20] = UInt8(ascii: "X")
        let info = ConnectionInfo(isSecure: true, negotiatedALPN: "h2")
        let frames = H2FrameReader.frames(in: await route(ByteBuffer(bytes: bad), info: info))
        #expect(frames == [.settings(HTTP2Configuration().localSettings),
                           .goaway(last: 0, .protocolError, debug: "PROTOCOL_ERROR")])
    }

    @Test func firstFrameMustBeSettings() async {
        var encoder = RequestEncoder()
        let firstFrames: [ByteBuffer] = [
            F.ping(1), F.settingsAck, F.windowUpdate(0, 10), F.headers(1, block: encoder.get("/")),
            F.raw(type: HTTP2FrameType(rawValue: 0x42), streamID: 0, payload: [1, 2]),
        ]
        for first in firstFrames {
            let frames = H2FrameReader.frames(in: await route(F.join(F.preface, first, F.settings())))
            #expect(frames.last == .goaway(last: 0, .protocolError, debug: "PROTOCOL_ERROR"), "\(frames)")
            #expect(!frames.contains(.settingsAck), "\(frames)")
        }
    }

    @Test func cleartextCanBeDisabled() async {
        let sent = await route(clientStart, http2: HTTP2Configuration(cleartext: false))
        #expect(sent.readableBytes == 0)
        // TLS connections that negotiated h2 are still served.
        let info = ConnectionInfo(isSecure: true, negotiatedALPN: "h2")
        let frames = H2FrameReader.frames(in: await route(clientStart, http2: HTTP2Configuration(cleartext: false), info: info))
        #expect(frames.first == .settings(HTTP2Configuration().localSettings))
    }
}
