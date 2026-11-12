import Compression
import HTTPCore
import HTTPTestSupport
import Testing
@testable import WebSockets

/// A client's side of permessage-deflate for tests: compresses what it sends, inflates what
/// the server sends.
final class TestDeflateClient {
    let encoder: DeflateEncoder
    let decoder: DeflateDecoder
    let noContextTakeover: Bool

    init(windowBits: Int = 15, noContextTakeover: Bool = false) {
        encoder = DeflateEncoder(format: .raw, level: 6, windowBits: windowBits)!
        decoder = DeflateDecoder(format: .raw, windowBits: 15)!
        self.noContextTakeover = noContextTakeover
    }

    /// The compressed payload for `bytes`: sync-flushed raw deflate without the tail.
    func compress(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: encoder.bound(bytes.count) + 64)
        let produced = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                encoder.process(input, into: out, flush: .sync).produced
            }
        }
        if noContextTakeover { encoder.reset() }
        #expect(Array(output[(produced - 4)..<produced]) == PerMessageDeflate.tail)
        return Array(output[..<(produced - 4)])
    }

    /// Inflates a server message's payload (appending the tail).
    func inflate(_ payload: [UInt8], serverNoContextTakeover: Bool = false) throws -> [UInt8] {
        let input = payload + PerMessageDeflate.tail
        var result: [UInt8] = []
        var offset = 0
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let progress = try input.withUnsafeBytes { bytes in
                try chunk.withUnsafeMutableBytes { out in
                    try decoder.process(UnsafeRawBufferPointer(rebasing: bytes[offset...]), into: out)
                }
            }
            result += chunk[..<progress.produced]
            offset += progress.consumed
            if offset == input.count && progress.produced < chunk.count { break }
        }
        if serverNoContextTakeover { decoder.reset() }
        return result
    }
}

func deflateConnection(maxMessageSize: Int = 1 << 20, clientNoContextTakeover: Bool = false) -> WSConnection {
    let parameters = PerMessageDeflate.Parameters(clientNoContextTakeover: clientNoContextTakeover)
    return WSConnection(configuration: .init(maxFrameSize: 1 << 20, maxMessageSize: maxMessageSize),
                        inflater: PerMessageDeflate.Inflater(parameters)!)
}

func hex(_ text: String) -> [UInt8] {
    text.split(separator: " ").map { UInt8($0, radix: 16)! }
}

@Suite struct PerMessageDeflateNegotiationTests {
    let defaults = PerMessageDeflate.Configuration()

    @Test func plainOfferIsAcceptedWithDefaults() throws {
        let agreement = try #require(PerMessageDeflate.negotiate(offers: "permessage-deflate", configuration: defaults))
        #expect(agreement.responseValue == "permessage-deflate")
        #expect(agreement.parameters == PerMessageDeflate.Parameters())
    }

    @Test func browserStyleOfferWithClientMaxWindowBits() throws {
        let offer = "permessage-deflate; client_max_window_bits"
        let agreement = try #require(PerMessageDeflate.negotiate(offers: offer, configuration: defaults))
        #expect(agreement.responseValue == "permessage-deflate")
        #expect(agreement.parameters.clientMaxWindowBits == 15)

        // A server that limits the client's window says so, only when the client offered it.
        let limited = PerMessageDeflate.Configuration(clientMaxWindowBits: 10)
        #expect(PerMessageDeflate.negotiate(offers: offer, configuration: limited)?.responseValue
                == "permessage-deflate; client_max_window_bits=10")
        #expect(PerMessageDeflate.negotiate(offers: "permessage-deflate", configuration: limited)?.responseValue
                == "permessage-deflate")
        // A smaller window the client asked for itself stands.
        let small = try #require(PerMessageDeflate.negotiate(
            offers: "permessage-deflate; client_max_window_bits=9", configuration: limited))
        #expect(small.parameters.clientMaxWindowBits == 9)
        #expect(small.responseValue == "permessage-deflate")
    }

    @Test func serverWindowAndContextTakeover() throws {
        let offer = "permessage-deflate; server_no_context_takeover; server_max_window_bits=10; client_no_context_takeover"
        let agreement = try #require(PerMessageDeflate.negotiate(offers: offer, configuration: defaults))
        #expect(agreement.parameters.serverNoContextTakeover)
        #expect(agreement.parameters.clientNoContextTakeover)
        #expect(agreement.parameters.serverMaxWindowBits == 10)
        #expect(agreement.responseValue
                == "permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=10")

        // The server's own limits are announced even when not asked for.
        let strict = PerMessageDeflate.Configuration(serverNoContextTakeover: true, clientNoContextTakeover: true,
                                                     serverMaxWindowBits: 12)
        let announced = try #require(PerMessageDeflate.negotiate(offers: "permessage-deflate", configuration: strict))
        #expect(announced.responseValue
                == "permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=12")
        // The smaller of the two windows wins.
        #expect(PerMessageDeflate.negotiate(offers: "permessage-deflate; server_max_window_bits=14",
                                            configuration: strict)?.parameters.serverMaxWindowBits == 12)
        // Quoted values are unquoted (RFC 6455 §9.1).
        #expect(PerMessageDeflate.negotiate(offers: "permessage-deflate; server_max_window_bits=\"11\"",
                                            configuration: defaults)?.parameters.serverMaxWindowBits == 11)
    }

    @Test func aWindowOf256BytesIsDeclinedAndTheNextOfferTaken() throws {
        #expect(PerMessageDeflate.negotiate(offers: "permessage-deflate; server_max_window_bits=8", configuration: defaults) == nil)
        let agreement = try #require(PerMessageDeflate.negotiate(
            offers: "permessage-deflate; server_max_window_bits=8, permessage-deflate; client_max_window_bits",
            configuration: defaults))
        #expect(agreement.parameters.serverMaxWindowBits == 15)
    }

    @Test(arguments: [
        "permessage-deflate; unknown_parameter",
        "permessage-deflate; server_no_context_takeover; server_no_context_takeover",
        "permessage-deflate; server_no_context_takeover=1",
        "permessage-deflate; client_no_context_takeover=true",
        "permessage-deflate; server_max_window_bits",
        "permessage-deflate; server_max_window_bits=16",
        "permessage-deflate; server_max_window_bits=7",
        "permessage-deflate; server_max_window_bits=08",
        "permessage-deflate; client_max_window_bits=abc",
        "permessage-deflate; client_max_window_bits=10; client_max_window_bits=11",
        "x-webkit-deflate-frame",
        "permessage-deflate;",
        "permessage-deflate; server_max_window_bits=\"10",
        "permessage-deflate server_no_context_takeover",
    ])
    func invalidOffersAreDeclined(offer: String) {
        #expect(PerMessageDeflate.negotiate(offers: offer, configuration: defaults) == nil)
    }

    @Test func otherExtensionsAreSkipped() throws {
        let agreement = try #require(PerMessageDeflate.negotiate(
            offers: "x-webkit-deflate-frame, , foo; bar=\"a,b\", Permessage-Deflate", configuration: defaults))
        #expect(agreement.responseValue == "permessage-deflate")
    }
}

@Suite struct PerMessageDeflateCodecTests {
    /// RFC 7692 §7.2.3: each example message, masked as a client sends it, fed whole, byte
    /// at a time, and in every 2–7 byte chunking.
    @Test(arguments: [
        // §7.2.3.1: "Hello" in one compressed frame.
        ([clientFrame(.text, hex("f2 48 cd c9 c9 07 00"), rsv: 0x40)], ["Hello"]),
        // §7.2.3.1: the same message in two fragments.
        ([clientFrame(.text, hex("f2 48 cd"), fin: false, rsv: 0x40),
          clientFrame(.continuation, hex("c9 c9 07 00"))], ["Hello"]),
        // §7.2.3.2: a second "Hello" that refers back into the shared LZ77 window.
        ([clientFrame(.text, hex("f2 48 cd c9 c9 07 00"), rsv: 0x40),
          clientFrame(.text, hex("f2 00 11 00 00"), rsv: 0x40)], ["Hello", "Hello"]),
        // §7.2.3.3: a stored (uncompressed) DEFLATE block.
        ([clientFrame(.text, hex("00 05 00 fa ff 48 65 6c 6c 6f 00"), rsv: 0x40)], ["Hello"]),
        // §7.2.3.4: a block with BFINAL set; the next message starts a new stream.
        ([clientFrame(.text, hex("f3 48 cd c9 c9 07 00 00"), rsv: 0x40),
          clientFrame(.text, hex("f2 48 cd c9 c9 07 00"), rsv: 0x40)], ["Hello", "Hello"]),
        // §7.2.3.5: two DEFLATE blocks in one message.
        ([clientFrame(.text, hex("f2 48 05 00 00 00 ff ff ca c9 c9 07 00"), rsv: 0x40)], ["Hello"]),
        // §7.2.3.6: an empty message compresses to a single 0x00 octet.
        ([clientFrame(.text, hex("00"), rsv: 0x40)], [""]),
        // An uncompressed message (RSV1 clear) between compressed ones.
        ([clientFrame(.text, hex("f2 48 cd c9 c9 07 00"), rsv: 0x40), clientFrame(.text, "plain"),
          clientFrame(.text, hex("f2 00 11 00 00"), rsv: 0x40)], ["Hello", "plain", "Hello"]),
    ] as [([[UInt8]], [String])])
    func rfc7692Examples(frames: [[UInt8]], messages: [String]) {
        let bytes = frames.flatMap { $0 }
        for chunk in [1 << 20, 1, 2, 3, 5, 7] {
            var connection = deflateConnection()
            let delivered = actions(&connection, bytes, chunk: chunk)
            #expect(delivered == messages.map { .deliver(.text($0)) }, "chunk \(chunk)")
            #expect(connection.failure == nil)
        }
    }

    @Test func roundTripWithAndWithoutContextTakeover() throws {
        let json = Array(#"{"type":"tick","symbol":"AAPL","price":231.45,"volume":1200,"ts":1731340800}"#.utf8)
        for noContextTakeover in [false, true] {
            let parameters = PerMessageDeflate.Parameters(serverNoContextTakeover: noContextTakeover)
            let deflater = try #require(PerMessageDeflate.Deflater(parameters))
            let client = TestDeflateClient()
            var output = ByteBuffer()
            var sizes: [Int] = []
            for _ in 0..<3 {
                let length = try #require(deflater.compress(ByteBuffer(bytes: json), into: &output))
                let payload = Array(output.bytes[..<length])
                sizes.append(length)
                #expect(try client.inflate(payload, serverNoContextTakeover: noContextTakeover) == json)
            }
            if noContextTakeover {
                #expect(Set(sizes).count == 1, "\(sizes)")
            } else {
                // The repeats refer back to the first message.
                #expect(sizes[1] < sizes[0] / 3, "\(sizes)")
            }
        }
    }

    @Test func smallAndIncompressibleMessagesGoUncompressed() throws {
        let deflater = try #require(PerMessageDeflate.Deflater(PerMessageDeflate.Parameters(minimumMessageSize: 32)))
        var output = ByteBuffer()
        #expect(deflater.compress(ByteBuffer(bytes: Array("short".utf8)), into: &output) == nil)
        // Without context takeover, a message that does not shrink is sent as is.
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let reset = try #require(PerMessageDeflate.Deflater(PerMessageDeflate.Parameters(serverNoContextTakeover: true)))
        #expect(reset.compress(ByteBuffer(bytes: noise), into: &output) == nil)
        // With context takeover the compressor already saw it, so it must be sent compressed.
        #expect(deflater.compress(ByteBuffer(bytes: noise), into: &output) != nil)
    }

    @Test func clientContextTakeoverAcrossManyMessages() throws {
        // The client keeps its context; we must too (and reset when it does not).
        for noContextTakeover in [false, true] {
            var connection = deflateConnection(clientNoContextTakeover: noContextTakeover)
            let client = TestDeflateClient(noContextTakeover: noContextTakeover)
            var bytes: [UInt8] = []
            var expected: [WSConnection.Action] = []
            for i in 0..<20 {
                let text = #"{"id":\#(i),"event":"update","payload":{"status":"ok","items":[1,2,3]}}"#
                bytes += clientFrame(.text, client.compress(Array(text.utf8)), rsv: 0x40)
                expected.append(.deliver(.text(text)))
            }
            #expect(actions(&connection, bytes, chunk: 13) == expected)
            #expect(connection.compressedMessages == 20)
        }
    }

    @Test func decompressionBombFailsWith1009() throws {
        // 4 MiB of zeros compresses to about 4 KiB; the limit is 64 KiB of inflated data.
        let client = TestDeflateClient()
        let payload = client.compress([UInt8](repeating: 0, count: 4 << 20))
        #expect(payload.count < 8 * 1024)
        var connection = deflateConnection(maxMessageSize: 64 * 1024)
        let result = actions(&connection, clientFrame(.binary, payload, rsv: 0x40))
        #expect(result == [.sendClose(code: .messageTooBig, reason: "", thenCloseTransport: true)])
        #expect(connection.failure == .messageTooBig)

        // Exactly at the limit is fine.
        var exact = deflateConnection(maxMessageSize: 64 * 1024)
        let fits = TestDeflateClient().compress([UInt8](repeating: 7, count: 64 * 1024))
        #expect(actions(&exact, clientFrame(.binary, fits, rsv: 0x40))
                == [.deliver(.binary(ByteBuffer(bytes: [UInt8](repeating: 7, count: 64 * 1024))))])

        // Fragmented: the bomb is caught in the fragment that crosses the limit.
        var fragmented = deflateConnection(maxMessageSize: 64 * 1024)
        let half = payload.count / 2
        let frames = clientFrame(.binary, Array(payload[..<half]), fin: false, rsv: 0x40)
            + clientFrame(.continuation, Array(payload[half...]))
        #expect(actions(&fragmented, frames).first == .sendClose(code: .messageTooBig, reason: "", thenCloseTransport: true))
    }

    @Test func reservedBitRules() {
        // RSV1 on a continuation or a control frame is a protocol error.
        var connection = deflateConnection()
        #expect(actions(&connection, clientFrame(.text, hex("f2 48 cd"), fin: false, rsv: 0x40)
                        + clientFrame(.continuation, hex("c9 c9 07 00"), rsv: 0x40))
                == [.sendClose(code: .protocolError, reason: "", thenCloseTransport: true)])
        var ping = deflateConnection()
        #expect(actions(&ping, clientFrame(.ping, [1, 2], rsv: 0x40))
                == [.sendClose(code: .protocolError, reason: "", thenCloseTransport: true)])
        // RSV2/RSV3 stay errors, and RSV1 is an error without the extension.
        var rsv2 = deflateConnection()
        #expect(actions(&rsv2, clientFrame(.text, [0x41], rsv: 0x20))
                == [.sendClose(code: .protocolError, reason: "", thenCloseTransport: true)])
        var plain = WSConnection()
        #expect(actions(&plain, clientFrame(.text, hex("f2 48 cd c9 c9 07 00"), rsv: 0x40))
                == [.sendClose(code: .protocolError, reason: "", thenCloseTransport: true)])
    }

    @Test func invalidDeflateDataAndInvalidUTF8Fail1007() {
        var garbage = deflateConnection()
        #expect(actions(&garbage, clientFrame(.binary, [0xFF, 0xFF, 0xFF], rsv: 0x40))
                == [.sendClose(code: .invalidFramePayloadData, reason: "", thenCloseTransport: true)])
        // Valid deflate of bytes that are not UTF-8, sent as text.
        var text = deflateConnection()
        let payload = TestDeflateClient().compress([0x48, 0x69, 0xC0, 0xAF])
        #expect(actions(&text, clientFrame(.text, payload, rsv: 0x40))
                == [.sendClose(code: .invalidFramePayloadData, reason: "", thenCloseTransport: true)])
    }
}

/// permessage-deflate through `WebSocketUpgrade` and the HTTP/1.1 runner, with a hand-built
/// client.
@Suite struct PerMessageDeflateSessionTests {
    static func echoComponent(_ compression: PerMessageDeflate.Configuration?, maxMessageSize: Int = 1 << 20) -> WebSocketUpgrade {
        WebSocketUpgrade(path: "/ws", configuration: WebSocketConfiguration(
            maxMessageSize: maxMessageSize, compression: compression)) { socket, _ in
            for await message in socket.messages { try await socket.send(message) }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func compressedEcho(serverNoContextTakeover: Bool) async throws {
        let component = Self.echoComponent(PerMessageDeflate.Configuration(serverNoContextTakeover: serverNoContextTakeover))
        let offer = "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"
        try await withServer(component, request: handshake(extra: offer)) { client, head, leftover in
            #expect(head.status == 101)
            let expectedValue = serverNoContextTakeover
                ? "permessage-deflate; server_no_context_takeover" : "permessage-deflate"
            #expect(head.header("Sec-WebSocket-Extensions") == expectedValue)
            let codec = TestDeflateClient()
            var reader = FrameReader(client, prefix: leftover, allowedReservedBits: 0x40)
            var sizes: [Int] = []
            for i in 0..<5 {
                let text = #"{"seq":\#(i),"kind":"chat","room":"general","body":"hello there, everyone"}"#
                // Every other message goes uncompressed; both directions must keep working.
                let frame = i % 2 == 0
                    ? clientFrame(.text, codec.compress(Array(text.utf8)), rsv: 0x40)
                    : clientFrame(.text, text)
                try await client.send(ByteBuffer(bytes: frame), endOfStream: false)
                let echoed = try #require(try await reader.next())
                #expect(echoed.opcode == .text)
                sizes.append(echoed.payload.count)
                let inflated = try codec.inflate(echoed.payload, serverNoContextTakeover: serverNoContextTakeover)
                #expect(String(decoding: inflated, as: UTF8.self) == text)
            }
            if !serverNoContextTakeover { #expect(sizes[2] < sizes[0], "\(sizes)") }
            try await client.send(ByteBuffer(bytes: clientFrame(.close, closePayload(1000))), endOfStream: false)
            #expect(try await reader.next()?.closeCode == 1000)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func serverFramesCarryRSV1OnlyWhenCompressed() async throws {
        let component = Self.echoComponent(PerMessageDeflate.Configuration(minimumMessageSize: 16))
        let offer = "Sec-WebSocket-Extensions: permessage-deflate\r\n"
        try await withServer(component, request: handshake(extra: offer)) { client, head, leftover in
            #expect(head.status == 101)
            // Read raw headers to see RSV1.
            var input = leftover
            try await client.send(ByteBuffer(bytes: clientFrame(.text, "tiny")), endOfStream: false)
            try await client.send(ByteBuffer(bytes: clientFrame(.text, String(repeating: "abc", count: 100))), endOfStream: false)
            var parser = WSFrameParser(configuration: .init(allowedReservedBits: 0x40, expectsMaskedFrames: false))
            var headers: [WSFrameHeader] = []
            var sink = ByteBuffer()
            while headers.count < 2 {
                switch parser.parse(&input, payloadInto: &sink) {
                case .header(let header): headers.append(header)
                case .needMoreBytes: _ = try await client.receive(into: &input, maxLength: 4096)
                case .payload: continue
                case .error(let code): Issue.record("\(code)"); return
                }
            }
            #expect(headers[0].reservedBits == 0)
            #expect(headers[0].payloadLength == 4)
            #expect(headers[1].reservedBits == 0x40)
            #expect(headers[1].payloadLength < 300)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func extensionIsDeclinedWhenNotConfiguredOrNotOffered() async throws {
        let offer = "Sec-WebSocket-Extensions: permessage-deflate\r\n"
        try await withServer(Self.echoComponent(nil), request: handshake(extra: offer)) { client, head, leftover in
            #expect(head.status == 101)
            #expect(head.header("Sec-WebSocket-Extensions") == nil)
            // RSV1 is then a protocol error.
            var reader = FrameReader(client, prefix: leftover)
            try await client.send(ByteBuffer(bytes: clientFrame(.text, hex("f2 48 cd c9 c9 07 00"), rsv: 0x40)), endOfStream: false)
            #expect(try await reader.next()?.closeCode == 1002)
        }
        try await withServer(Self.echoComponent(PerMessageDeflate.Configuration()), request: handshake()) { _, head, _ in
            #expect(head.status == 101)
            #expect(head.header("Sec-WebSocket-Extensions") == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bombThroughTheSessionClosesWith1009() async throws {
        let component = Self.echoComponent(PerMessageDeflate.Configuration(), maxMessageSize: 64 * 1024)
        let offer = "Sec-WebSocket-Extensions: permessage-deflate\r\n"
        try await withServer(component, request: handshake(extra: offer)) { client, head, leftover in
            #expect(head.status == 101)
            var reader = FrameReader(client, prefix: leftover)
            let bomb = TestDeflateClient().compress([UInt8](repeating: 0x41, count: 8 << 20))
            try await client.send(ByteBuffer(bytes: clientFrame(.text, bomb, rsv: 0x40)), endOfStream: false)
            #expect(try await reader.next()?.closeCode == 1009)
        }
    }
}
