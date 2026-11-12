import HTTPCore
import Testing
@testable import WebSockets

@Suite struct WSFrameParserTests {
    // MARK: Masking

    @Test func maskingRoundTripsAtEveryOffsetAndLength() {
        let key: UInt32 = 0xA1B2_C3D4
        let keyBytes: [UInt8] = [0xA1, 0xB2, 0xC3, 0xD4]
        for length in [0, 1, 3, 4, 7, 8, 9, 15, 16, 17, 31, 64, 100] {
            let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
            for offset in 0..<4 {
                var masked = ByteBuffer()
                WSMasking.appendMasked(ByteBuffer(bytes: payload), key: key, offset: offset, into: &masked)
                let expected = payload.enumerated().map { $0.element ^ keyBytes[($0.offset + offset) % 4] }
                #expect(masked.bytes == expected, "length \(length) offset \(offset)")
                var source = masked
                var unmasked = ByteBuffer()
                WSMasking.moveUnmasked(source.readableBytes, from: &source, into: &unmasked, key: key, offset: offset)
                #expect(unmasked.bytes == payload)
                #expect(source.readableBytes == 0)
            }
        }
    }

    @Test func rfcMaskedHelloExample() {
        // RFC 6455 §5.7: a masked "Hello".
        let frame: [UInt8] = [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        let events = parseAll(frame, splits: [])
        #expect(events == [
            .header(WSFrameHeader(fin: true, opcode: .text, maskKey: 0x37FA_213D, payloadLength: 5)),
            .payload(Array("Hello".utf8)),
        ])
    }

    @Test func rfcUnmaskedFramesForAClient() {
        // RFC 6455 §5.7: unmasked "Hello", and the fragmented "Hel" + "lo".
        let bytes: [UInt8] = [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
                              0x01, 0x03, 0x48, 0x65, 0x6C, 0x80, 0x02, 0x6C, 0x6F]
        let events = parseAll(bytes, splits: [], configuration: .init(expectsMaskedFrames: false))
        #expect(events == [
            .header(WSFrameHeader(fin: true, opcode: .text, payloadLength: 5)), .payload(Array("Hello".utf8)),
            .header(WSFrameHeader(fin: false, opcode: .text, payloadLength: 3)), .payload(Array("Hel".utf8)),
            .header(WSFrameHeader(fin: true, opcode: .continuation, payloadLength: 2)), .payload(Array("lo".utf8)),
        ])
    }

    // MARK: Lengths

    @Test(arguments: [0, 1, 125, 126, 127, 1000, 65535, 65536, 70000])
    func everyLengthEncoding(length: Int) {
        let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0) }
        let frame = clientFrame(.binary, payload)
        let expectedHeaderSize = 2 + (length <= 125 ? 0 : length <= 0xFFFF ? 2 : 8) + 4
        #expect(frame.count == expectedHeaderSize + length)
        let events = parseAll(frame, splits: [])
        #expect(events == [
            .header(WSFrameHeader(fin: true, opcode: .binary, maskKey: 0x3712_A5C9, payloadLength: UInt64(length))),
            .payload(payload),
        ])
    }

    @Test func nonMinimalLengthEncodingsAreAccepted() {
        // 5 bytes encoded with the 16-bit and the 64-bit forms (RFC 6455 does not require
        // minimal encoding on read).
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let sixteen: [UInt8] = [0x82, 0x80 | 126, 0, 5, 0, 0, 0, 0] + payload
        let sixtyFour: [UInt8] = [0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0] + payload
        for frame in [sixteen, sixtyFour] {
            #expect(parseAll(frame, splits: []) == [
                .header(WSFrameHeader(fin: true, opcode: .binary, maskKey: 0, payloadLength: 5)), .payload(payload),
            ])
        }
    }

    @Test func emptyFrameReportsFrameEnd() {
        var parser = WSFrameParser()
        var input = ByteBuffer(bytes: clientFrame(.ping, []))
        var sink = ByteBuffer()
        guard case .header(let header) = parser.parse(&input, payloadInto: &sink) else {
            Issue.record("no header"); return
        }
        #expect(header.payloadLength == 0)
        #expect(parser.parse(&input, payloadInto: &sink) == .payload(count: 0, frameEnd: true))
        #expect(parser.parse(&input, payloadInto: &sink) == .needMoreBytes)
    }

    // MARK: Split invariance

    @Test func everySplitOffsetParsesIdentically() {
        var stream: [UInt8] = []
        stream += clientFrame(.text, "Hello, WebSocket", fin: false)
        stream += clientFrame(.ping, Array("p".utf8))
        stream += clientFrame(.continuation, " world", fin: true)
        stream += clientFrame(.binary, (0..<300).map { UInt8(truncatingIfNeeded: $0) })
        stream += clientFrame(.binary, (0..<126).map { UInt8(truncatingIfNeeded: $0 * 3) })
        stream += clientFrame(.close, closePayload(1000, Array("bye".utf8)))
        let whole = parseAll(stream, splits: [])
        #expect(whole.count == 12)
        for split in 1..<stream.count {
            #expect(parseAll(stream, splits: [split]) == whole, "split at \(split)")
        }
        // Two splits around every header byte of the first frames, and byte at a time.
        for a in 1..<30 {
            for b in (a + 1)..<40 {
                #expect(parseAll(stream, splits: [a, b]) == whole, "splits at \(a), \(b)")
            }
        }
        #expect(parseAll(stream, splits: Array(1..<stream.count)) == whole)
    }

    @Test func payloadCapLimitsEachRun() {
        var parser = WSFrameParser()
        var input = ByteBuffer(bytes: clientFrame(.binary, Array(repeating: 7, count: 10)))
        var sink = ByteBuffer()
        _ = parser.parse(&input, payloadInto: &sink)
        #expect(parser.parse(&input, payloadInto: &sink, maxPayloadBytes: 4) == .payload(count: 4, frameEnd: false))
        #expect(parser.parse(&input, payloadInto: &sink, maxPayloadBytes: 4) == .payload(count: 4, frameEnd: false))
        #expect(parser.parse(&input, payloadInto: &sink, maxPayloadBytes: 4) == .payload(count: 2, frameEnd: true))
        #expect(sink.bytes == Array(repeating: 7, count: 10))
    }

    // MARK: Violations

    func firstError(_ bytes: [UInt8], configuration: WSFrameParser.Configuration = .init()) -> WebSocketCloseCode? {
        // The same verdict whatever the split.
        var verdicts: Set<WebSocketCloseCode?> = []
        for split in 0..<max(bytes.count, 1) {
            let events = parseAll(bytes, splits: [split], configuration: configuration)
            if case .error(let code) = events.last { verdicts.insert(code) } else { verdicts.insert(nil) }
        }
        #expect(verdicts.count == 1, "verdict depends on the split: \(verdicts)")
        return verdicts.first ?? nil
    }

    @Test func unmaskedClientFrameIsProtocolError() {
        let unmasked: [UInt8] = [0x81, 0x02, 0x68, 0x69]
        #expect(firstError(unmasked) == .protocolError)
        // And a masked frame where a server is expected to send unmasked ones.
        #expect(firstError(clientFrame(.text, "hi"), configuration: .init(expectsMaskedFrames: false)) == .protocolError)
    }

    @Test(arguments: [UInt8(0x40), 0x20, 0x10, 0x70])
    func reservedBitsAreProtocolErrorsUnlessNegotiated(rsv: UInt8) {
        let frame = clientFrame(.text, Array("x".utf8), rsv: rsv)
        #expect(firstError(frame) == .protocolError)
        #expect(firstError(frame, configuration: .init(allowedReservedBits: 0x70)) == nil)
        if rsv == 0x40 {
            // permessage-deflate allows RSV1 only.
            #expect(firstError(frame, configuration: .init(allowedReservedBits: 0x40)) == nil)
        } else {
            #expect(firstError(frame, configuration: .init(allowedReservedBits: 0x40)) == .protocolError)
        }
    }

    @Test(arguments: [UInt8(3), 4, 5, 6, 7, 0xB, 0xC, 0xD, 0xE, 0xF])
    func reservedOpcodesAreProtocolErrors(opcode: UInt8) {
        let frame: [UInt8] = [0x80 | opcode, 0x80, 1, 2, 3, 4]
        #expect(firstError(frame) == .protocolError)
    }

    @Test(arguments: [WSOpcode.close, .ping, .pong])
    func fragmentedControlFrameIsProtocolError(opcode: WSOpcode) {
        #expect(firstError(clientFrame(opcode, [], fin: false)) == .protocolError)
    }

    @Test(arguments: [WSOpcode.close, .ping, .pong])
    func controlFrameOver125BytesIsProtocolError(opcode: WSOpcode) {
        #expect(firstError(clientFrame(opcode, Array(repeating: 0x41, count: 125))) == nil)
        #expect(firstError(clientFrame(opcode, Array(repeating: 0x41, count: 126))) == .protocolError)
    }

    @Test func sixtyFourBitLengthWithHighBitIsProtocolError() {
        let frame: [UInt8] = [0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4]
        #expect(firstError(frame) == .protocolError)
    }

    @Test func frameOverMaxFrameSizeIsMessageTooBig() {
        let configuration = WSFrameParser.Configuration(maxFrameSize: 1000)
        #expect(firstError(clientFrame(.binary, Array(repeating: 1, count: 1000)), configuration: configuration) == nil)
        #expect(firstError(clientFrame(.binary, Array(repeating: 1, count: 1001)), configuration: configuration) == .messageTooBig)
        // Detected from the header alone: no payload needed.
        let header: [UInt8] = [0x82, 0xFF, 0, 0, 0, 1, 0, 0, 0, 0, 1, 2, 3, 4]
        #expect(firstError(header, configuration: configuration) == .messageTooBig)
    }

    @Test func errorIsSticky() {
        var parser = WSFrameParser()
        var input = ByteBuffer(bytes: [0x81, 0x01, 0x41] + clientFrame(.text, "ok"))
        var sink = ByteBuffer()
        #expect(parser.parse(&input, payloadInto: &sink) == .error(.protocolError))
        #expect(parser.parse(&input, payloadInto: &sink) == .error(.protocolError))
    }

    // MARK: Writer

    @Test func writerUsesShortestLengthEncoding() {
        for (length, headerSize) in [(0, 2), (125, 2), (126, 4), (65535, 4), (65536, 10)] {
            var buffer = ByteBuffer()
            WSFrameWriter.appendHeader(opcode: .binary, payloadLength: length, into: &buffer)
            #expect(buffer.readableBytes == headerSize, "length \(length)")
            #expect(buffer.byte(at: 1) & 0x80 == 0, "server frames are unmasked")
        }
        var close = ByteBuffer()
        WSFrameWriter.appendFrame(opcode: .close, payload: WSFrameWriter.closePayload(code: .goingAway, reason: "bye"), into: &close)
        #expect(close.bytes == [0x88, 0x05, 0x03, 0xE9] + Array("bye".utf8))
    }
}
