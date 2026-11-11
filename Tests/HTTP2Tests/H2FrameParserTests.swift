import Testing
import HTTP2
import HTTPCore

private let server = HTTP2FrameParser.Configuration(role: .server)
private let client = HTTP2FrameParser.Configuration(role: .client)

private let fragment: [UInt8] = [0x82, 0x86, 0x84, 0x41, 0x8a, 0x08, 0x9d, 0x5c, 0x0b, 0x81, 0x70, 0xdc]

/// Asserts that every split of `bytes` parses to `expected`.
private func expectSplitInvariant(
    _ bytes: [UInt8], _ expected: [ParsedFrame], _ configuration: HTTP2FrameParser.Configuration = server,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for chunks in everySplit(of: bytes) {
        let frames = parse(chunks, configuration: configuration).frames
        #expect(frames == expected, "chunks \(chunks.map(\.count))", sourceLocation: sourceLocation)
        if frames != expected { return }
    }
}

/// Asserts that every split of `bytes` ends in a thrown connection error with `code`.
private func expectConnectionError(
    _ bytes: [UInt8], _ code: HTTP2ErrorCode, _ configuration: HTTP2FrameParser.Configuration = server,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for chunks in everySplit(of: bytes) {
        let last = parse(chunks, configuration: configuration).frames.last
        #expect(last == .connectionError(code), "chunks \(chunks.map(\.count))", sourceLocation: sourceLocation)
        if last != .connectionError(code) { return }
    }
}

private func frame(type: UInt8, flags: UInt8 = 0, stream: UInt32, _ payload: [UInt8]) -> [UInt8] {
    var builder = FrameBuilder()
    builder.rawFrame(type: type, flags: flags, stream: stream, payload)
    return builder.bytes
}

/// A PING, so tests can show the parser carries on after a stream error.
private let pingFrame = frame(type: 0x6, stream: 0, [1, 2, 3, 4, 5, 6, 7, 8])
private let pingEvent = ParsedFrame.ping(ack: false, 0x0102_0304_0506_0708)

private func setting(_ id: UInt16, _ value: UInt32) -> [UInt8] {
    [UInt8(id >> 8), UInt8(id & 0xff), UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
}

// MARK: - Round trips

@Suite struct H2FrameRoundTripTests {
    @Test func frameHeaderLayout() {
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodeHeader(
            HTTP2FrameHeader(length: 0x01_02_03, type: .headers, flags: [.endStream, .endHeaders], streamID: .s(0x7fff_fffe)),
            into: &builder.buffer)
        #expect(builder.bytes == [0x01, 0x02, 0x03, 0x01, 0x05, 0x7f, 0xff, 0xff, 0xfe])
    }

    @Test func data() {
        var builder = FrameBuilder()
        let payload = (0..<40).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        builder.with(payload) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, into: &$1) }
        builder.with([]) { HTTP2FrameEncoder.encodeData(streamID: .s(3), data: $0, endStream: true, into: &$1) }
        #expect(Array(builder.bytes.prefix(9)) == [0, 0, 40, 0x0, 0x0, 0, 0, 0, 1])
        expectSplitInvariant(builder.bytes, [
            .dataHeader(.init(streamID: .s(1), dataLength: 40, flowControlledLength: 40, endStream: false)),
            .data(payload),
            .dataHeader(.init(streamID: .s(3), dataLength: 0, flowControlledLength: 0, endStream: true)),
        ])
    }

    @Test func dataHeaderThenCallerWrittenPayload() {
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodeDataHeader(streamID: .s(5), dataLength: 4, endStream: true, padding: 2, into: &builder.buffer)
        builder.raw([9, 8, 7, 6])
        HTTP2FrameEncoder.encodePadding(2, into: &builder.buffer)
        #expect(builder.bytes == [0, 0, 7, 0x0, 0x09, 0, 0, 0, 5, 2, 9, 8, 7, 6, 0, 0])
        expectSplitInvariant(builder.bytes, [
            .dataHeader(.init(streamID: .s(5), dataLength: 4, flowControlledLength: 7, endStream: true)),
            .data([9, 8, 7, 6]),
        ])
    }

    @Test func paddedDataEdgeCases() {
        var builder = FrameBuilder()
        // Pad Length 0: one extra octet of flow-controlled length.
        builder.with([1, 2]) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, padding: 0, into: &$1) }
        // Padding only, no data: Pad Length = length − 1, the largest valid value.
        builder.with([]) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, padding: 10, into: &$1) }
        // The maximum padding.
        builder.with([3]) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, endStream: true, padding: 255, into: &$1) }
        builder.raw(pingFrame)
        expectSplitInvariant(builder.bytes, [
            .dataHeader(.init(streamID: .s(1), dataLength: 2, flowControlledLength: 3, endStream: false)),
            .data([1, 2]),
            .dataHeader(.init(streamID: .s(1), dataLength: 0, flowControlledLength: 11, endStream: false)),
            .dataHeader(.init(streamID: .s(1), dataLength: 1, flowControlledLength: 257, endStream: true)),
            .data([3]),
            pingEvent,
        ])
    }

    @Test func headers() {
        var builder = FrameBuilder()
        builder.with(fragment) { HTTP2FrameEncoder.encodeHeaders(streamID: .s(1), fragment: $0, into: &$1) }
        #expect(Array(builder.bytes.prefix(9)) == [0, 0, UInt8(fragment.count), 0x1, 0x04, 0, 0, 0, 1])
        expectSplitInvariant(builder.bytes, [
            .headers(stream: 1, endStream: false, endHeaders: true, priority: nil, fragment),
        ])
    }

    @Test func headersWithFlagsPaddingAndPriority() {
        let priority = HTTP2Priority(exclusive: true, dependency: .s(3), weight: 256)
        var builder = FrameBuilder()
        builder.with(fragment) {
            HTTP2FrameEncoder.encodeHeaders(streamID: .s(5), fragment: $0, endStream: true, endHeaders: false, into: &$1)
        }
        builder.with(fragment) {
            HTTP2FrameEncoder.encodeHeaders(streamID: .s(7), fragment: $0, padding: 3, into: &$1)
        }
        builder.with(fragment) {
            HTTP2FrameEncoder.encodeHeaders(streamID: .s(9), fragment: $0, priority: priority, into: &$1)
        }
        builder.with(fragment) {
            HTTP2FrameEncoder.encodeHeaders(
                streamID: .s(11), fragment: $0, priority: HTTP2Priority(weight: 1), padding: 255, into: &$1)
        }
        // Empty fragment, and padding that fills the payload exactly.
        builder.with([]) { HTTP2FrameEncoder.encodeHeaders(streamID: .s(13), fragment: $0, padding: 4, into: &$1) }
        expectSplitInvariant(builder.bytes, [
            .headers(stream: 5, endStream: true, endHeaders: false, priority: nil, fragment),
            .headers(stream: 7, endStream: false, endHeaders: true, priority: nil, fragment),
            .headers(stream: 9, endStream: false, endHeaders: true, priority: priority, fragment),
            .headers(stream: 11, endStream: false, endHeaders: true, priority: HTTP2Priority(weight: 1), fragment),
            .headers(stream: 13, endStream: false, endHeaders: true, priority: nil, []),
        ])
    }

    @Test func priority() {
        var builder = FrameBuilder()
        let priority = HTTP2Priority(exclusive: true, dependency: .s(1), weight: 42)
        HTTP2FrameEncoder.encodePriority(streamID: .s(3), priority, into: &builder.buffer)
        #expect(builder.bytes == [0, 0, 5, 0x2, 0, 0, 0, 0, 3, 0x80, 0, 0, 1, 41])
        expectSplitInvariant(builder.bytes, [.priority(stream: 3, priority)])
    }

    @Test func rstStream() {
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodeRSTStream(streamID: .s(1), .cancel, into: &builder.buffer)
        HTTP2FrameEncoder.encodeRSTStream(streamID: .s(3), HTTP2ErrorCode(rawValue: 0xabcd), into: &builder.buffer)
        #expect(Array(builder.bytes.prefix(13)) == [0, 0, 4, 0x3, 0, 0, 0, 0, 1, 0, 0, 0, 8])
        expectSplitInvariant(builder.bytes, [
            .rstStream(stream: 1, .cancel),
            .rstStream(stream: 3, HTTP2ErrorCode(rawValue: 0xabcd)),
        ])
    }

    @Test func settings() {
        let all = HTTP2Settings(
            headerTableSize: 0, enablePush: false, maxConcurrentStreams: 100, initialWindowSize: 0x7fff_ffff,
            maxFrameSize: 16_777_215, maxHeaderListSize: 8192, enableConnectProtocol: true, noRFC7540Priorities: true)
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodeSettings(all, into: &builder.buffer)
        HTTP2FrameEncoder.encodeSettings(HTTP2Settings(), into: &builder.buffer)
        HTTP2FrameEncoder.encodeSettingsAck(into: &builder.buffer)
        let bytes = builder.bytes
        #expect(Array(bytes.prefix(15)) == [0, 0, 48, 0x4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0])
        #expect(Array(bytes.suffix(18)) == [0, 0, 0, 0x4, 0, 0, 0, 0, 0, 0, 0, 0, 0x4, 0x1, 0, 0, 0, 0])
        expectSplitInvariant(bytes, [.settings(all), .settings(HTTP2Settings()), .settingsAck])
    }

    @Test func settingsIgnoreUnknownIdentifiersAndKeepTheLastDuplicate() {
        let payload = setting(0x4, 100) + setting(0xfafa, 7) + setting(0x7, 1) + setting(0x4, 200) + setting(0x2, 1)
        expectSplitInvariant(frame(type: 0x4, stream: 0, payload), [
            .settings(HTTP2Settings(enablePush: true, initialWindowSize: 200)),
        ])
    }

    @Test func pushPromise() {
        var builder = FrameBuilder()
        builder.with(fragment) {
            HTTP2FrameEncoder.encodePushPromise(streamID: .s(1), promisedStreamID: .s(2), fragment: $0, into: &$1)
        }
        builder.with(fragment) {
            HTTP2FrameEncoder.encodePushPromise(
                streamID: .s(3), promisedStreamID: .s(4), fragment: $0, endHeaders: false, padding: 6, into: &$1)
        }
        #expect(Array(builder.bytes.prefix(13)) == [0, 0, UInt8(4 + fragment.count), 0x5, 0x04, 0, 0, 0, 1, 0, 0, 0, 2])
        expectSplitInvariant(builder.bytes, [
            .pushPromise(stream: 1, promised: 2, endHeaders: true, fragment),
            .pushPromise(stream: 3, promised: 4, endHeaders: false, fragment),
        ], client)
    }

    @Test func ping() {
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodePing(opaqueData: 0x0102_0304_0506_0708, into: &builder.buffer)
        HTTP2FrameEncoder.encodePing(opaqueData: .max, ack: true, into: &builder.buffer)
        #expect(Array(builder.bytes.prefix(17)) == [0, 0, 8, 0x6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        expectSplitInvariant(builder.bytes, [pingEvent, .ping(ack: true, .max)])
    }

    @Test func goaway() {
        var builder = FrameBuilder()
        builder.with([0xde, 0xad]) {
            HTTP2FrameEncoder.encodeGoaway(lastStreamID: .s(7), .enhanceYourCalm, debugData: $0, into: &$1)
        }
        builder.with([]) { HTTP2FrameEncoder.encodeGoaway(lastStreamID: .s(0), .noError, debugData: $0, into: &$1) }
        let error = HTTP2Error.connection(.frameSizeError, reason: "internal detail")
        HTTP2FrameEncoder.encodeGoaway(lastStreamID: .s(9), error: error, into: &builder.buffer)
        #expect(Array(builder.bytes.prefix(19)) == [0, 0, 10, 0x7, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0xb, 0xde, 0xad])
        expectSplitInvariant(builder.bytes, [
            .goaway(last: 7, .enhanceYourCalm, [0xde, 0xad]),
            .goaway(last: 0, .noError, []),
            .goaway(last: 9, .frameSizeError, Array("FRAME_SIZE_ERROR".utf8)),
        ])
    }

    @Test func windowUpdate() {
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: 0x7fff_ffff, into: &builder.buffer)
        HTTP2FrameEncoder.encodeWindowUpdate(streamID: .s(1), increment: 1, into: &builder.buffer)
        #expect(Array(builder.bytes.prefix(13)) == [0, 0, 4, 0x8, 0, 0, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff])
        expectSplitInvariant(builder.bytes, [
            .windowUpdate(stream: 0, 0x7fff_ffff),
            .windowUpdate(stream: 1, 1),
        ])
    }

    @Test func continuation() {
        var builder = FrameBuilder()
        builder.with(Array(fragment[..<5])) {
            HTTP2FrameEncoder.encodeHeaders(streamID: .s(1), fragment: $0, endHeaders: false, into: &$1)
        }
        builder.with(Array(fragment[5..<9])) {
            HTTP2FrameEncoder.encodeContinuation(streamID: .s(1), fragment: $0, endHeaders: false, into: &$1)
        }
        builder.with([]) { HTTP2FrameEncoder.encodeContinuation(streamID: .s(1), fragment: $0, endHeaders: false, into: &$1) }
        builder.with(Array(fragment[9...])) { HTTP2FrameEncoder.encodeContinuation(streamID: .s(1), fragment: $0, into: &$1) }
        expectSplitInvariant(builder.bytes, [
            .headers(stream: 1, endStream: false, endHeaders: false, priority: nil, Array(fragment[..<5])),
            .continuation(stream: 1, endHeaders: false, Array(fragment[5..<9])),
            .continuation(stream: 1, endHeaders: false, []),
            .continuation(stream: 1, endHeaders: true, Array(fragment[9...])),
        ])
    }

    @Test func unknownTypesAreSurfacedAndSkipped() {
        var builder = FrameBuilder()
        builder.with([1, 2, 3]) {
            HTTP2FrameEncoder.encodeFrame(type: HTTP2FrameType(rawValue: 0xa), flags: [.padded], streamID: .s(1), payload: $0, into: &$1)
        }
        builder.with([]) {
            HTTP2FrameEncoder.encodeFrame(type: HTTP2FrameType(rawValue: 0xff), streamID: .connection, payload: $0, into: &$1)
        }
        builder.raw(pingFrame)
        expectSplitInvariant(builder.bytes, [
            .unknown(HTTP2FrameHeader(length: 3, type: HTTP2FrameType(rawValue: 0xa), flags: .padded, streamID: .s(1))),
            .unknown(HTTP2FrameHeader(length: 0, type: HTTP2FrameType(rawValue: 0xff), streamID: .connection)),
            pingEvent,
        ])
        #expect(!HTTP2FrameType(rawValue: 0xa).isKnown)
        #expect(HTTP2FrameType.continuation.isKnown)
        #expect(HTTP2FrameType(rawValue: 0xa).description == "unknown(0xa)")
    }

    @Test func undefinedFlagsAndReservedBitsAreIgnored() {
        var bytes = frame(type: 0x6, flags: 0xfe, stream: 0, [0, 0, 0, 0, 0, 0, 0, 1])  // every flag but ACK
        bytes += frame(type: 0x0, flags: 0x20 | 0x04, stream: 0x8000_0001, [7])  // PRIORITY/END_HEADERS bits on DATA
        bytes += frame(type: 0x8, stream: 0x8000_0003, [0x80, 0, 0, 5])  // R bits on stream and increment
        bytes += frame(type: 0x7, stream: 0, [0x80, 0, 0, 9, 0, 0, 0, 1])  // R bit on last stream ID
        expectSplitInvariant(bytes, [
            .ping(ack: false, 1),
            .dataHeader(.init(streamID: .s(1), dataLength: 1, flowControlledLength: 1, endStream: false)),
            .data([7]),
            .windowUpdate(stream: 3, 5),
            .goaway(last: 9, .protocolError, []),
        ])
    }

    @Test func mixedConnection() {
        var builder = FrameBuilder()
        HTTP2FrameEncoder.encodeSettings(HTTP2Settings(maxConcurrentStreams: 10), into: &builder.buffer)
        builder.with(fragment) { HTTP2FrameEncoder.encodeHeaders(streamID: .s(1), fragment: $0, into: &$1) }
        builder.with([1, 2, 3]) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, padding: 1, into: &$1) }
        HTTP2FrameEncoder.encodeWindowUpdate(streamID: .s(1), increment: 3, into: &builder.buffer)
        builder.with([4]) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, endStream: true, into: &$1) }
        HTTP2FrameEncoder.encodeRSTStream(streamID: .s(1), .noError, into: &builder.buffer)
        HTTP2FrameEncoder.encodeSettingsAck(into: &builder.buffer)
        expectSplitInvariant(builder.bytes, [
            .settings(HTTP2Settings(maxConcurrentStreams: 10)),
            .headers(stream: 1, endStream: false, endHeaders: true, priority: nil, fragment),
            .dataHeader(.init(streamID: .s(1), dataLength: 3, flowControlledLength: 5, endStream: false)),
            .data([1, 2, 3]),
            .windowUpdate(stream: 1, 3),
            .dataHeader(.init(streamID: .s(1), dataLength: 1, flowControlledLength: 1, endStream: true)),
            .data([4]),
            .rstStream(stream: 1, .noError),
            .settingsAck,
        ])
    }
}

// MARK: - Zero copy and limits

@Suite struct H2FrameParserBufferingTests {
    @Test func wholeInputReportsPayloadsInPlace() {
        var builder = FrameBuilder()
        builder.with(fragment) { HTTP2FrameEncoder.encodeHeaders(streamID: .s(1), fragment: $0, into: &$1) }
        builder.with([1]) { HTTP2FrameEncoder.encodeGoaway(lastStreamID: .s(1), .noError, debugData: $0, into: &$1) }
        let whole = parse([builder.bytes])
        #expect(whole.inPlacePayloads == 2)
        #expect(whole.bufferedPayloads == 0)
        let split = parse(builder.bytes.map { [$0] })
        #expect(split.bufferedPayloads == 2)
        #expect(split.frames == whole.frames)
    }

    @Test func largeDataIsDeliveredAsSlicesWithoutBuffering() {
        let payload = (0..<HTTP2Settings.defaultMaxFrameSize).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var builder = FrameBuilder()
        builder.with(payload) { HTTP2FrameEncoder.encodeData(streamID: .s(1), data: $0, endStream: true, padding: 100, into: &$1) }
        let bytes = builder.bytes
        // The padding pushes the frame over 2^14: raise the limit.
        let configuration = HTTP2FrameParser.Configuration(maxFrameSize: 32_768)
        for chunkSize in [1, 7, 1000, 4096, bytes.count] {
            let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
            let run = parse(chunks, configuration: configuration)
            #expect(run.frames == [
                .dataHeader(.init(streamID: .s(1), dataLength: payload.count, flowControlledLength: payload.count + 101, endStream: true)),
                .data(payload),
            ], "chunk size \(chunkSize)")
            #expect(run.bufferedPayloads == 0)
        }
    }

    @Test func frameSizeIsBoundedBySettingsMaxFrameSize() {
        let atLimit = frame(type: 0x0, stream: 1, [UInt8](repeating: 0, count: 16_384))
        #expect(parse([atLimit]).frames.count == 2)
        let over = frame(type: 0x0, stream: 1, [UInt8](repeating: 0, count: 16_385))
        // Only the 9-octet header is needed to reject it.
        #expect(parse([Array(over.prefix(9))]).frames == [.connectionError(.frameSizeError)])
        for type: UInt8 in [0x1, 0x4, 0x8, 0x9, 0x42] {
            var header = Array(over.prefix(9))
            header[3] = type
            #expect(parse([header]).frames == [.connectionError(.frameSizeError)], "type \(type)")
        }
        #expect(parse([over], configuration: .init(maxFrameSize: 16_385)).frames.count == 2)
    }

    @Test func maxFrameSizeCanBeRaisedBetweenFrames() throws {
        let big = frame(type: 0x9, stream: 1, [UInt8](repeating: 0xaa, count: 20_000))
        var parser = HTTP2FrameParser()
        var head = ByteBuffer()
        head.append(contentsOf: big.prefix(5))
        #expect(try parser.parse(head).event == .needsMoreData)
        parser.maxFrameSize = 20_000
        var rest = ByteBuffer()
        rest.append(contentsOf: big.dropFirst(5))
        let output = try parser.parse(rest)
        guard case .continuation(_, _, .input(let range)) = output.event else {
            Issue.record("expected CONTINUATION, got \(output.event)")
            return
        }
        #expect(range.count == 20_000)
        #expect(output.consumed == big.count - 5)
    }

    @Test func parsesFromAByteBuffer() throws {
        var buffer = ByteBuffer()
        buffer.append(contentsOf: [0xff, 0xff])  // already consumed
        buffer.moveReaderIndex(forwardBy: 2)
        HTTP2FrameEncoder.encodePing(opaqueData: 42, into: &buffer)
        fragment.withUnsafeBytes { HTTP2FrameEncoder.encodeHeaders(streamID: .s(1), fragment: $0, into: &buffer) }
        var parser = HTTP2FrameParser()
        var output = try parser.parse(buffer)
        #expect(output.event == .ping(ack: false, opaqueData: 42))
        buffer.moveReaderIndex(forwardBy: output.consumed)
        output = try parser.parse(buffer)
        guard case .headers(_, _, _, _, let location) = output.event else {
            Issue.record("expected HEADERS, got \(output.event)")
            return
        }
        let bytes = buffer.withUnsafeReadableBytes { input in parser.withPayload(location, in: input) { Array($0) } }
        #expect(bytes == fragment)
        buffer.moveReaderIndex(forwardBy: output.consumed)
        #expect(try parser.parse(buffer) == HTTP2FrameParser.Output(.needsMoreData, consumed: 0))
        #expect(parser.isAtFrameBoundary)
    }

    @Test func inputEndingInsideAFrameIsUnfinished() throws {
        let headers = frame(type: 0x1, flags: 0x4, stream: 1, fragment)
        for cut in 1..<headers.count {
            #expect(parse([Array(headers[..<cut])]).frames.last == .unfinished, "cut \(cut)")
        }
        let data = frame(type: 0x0, flags: 0x8, stream: 1, [2, 9, 0, 0])
        for cut in 1..<data.count {
            #expect(parse([Array(data[..<cut])]).frames.last == .unfinished, "cut \(cut)")
        }
        var parser = HTTP2FrameParser()
        var partial = ByteBuffer()
        partial.append(contentsOf: headers.prefix(4))
        _ = try parser.parse(partial)
        var thrown: HTTP2Error?
        do { try parser.finish() } catch { thrown = error }
        #expect(thrown == .connection(.protocolError, reason: "input ended inside a frame"))
    }
}

// MARK: - Malformed frames

@Suite struct H2FrameValidationTests {
    @Test func data() {
        expectConnectionError(frame(type: 0x0, stream: 0, [1]), .protocolError)
        expectConnectionError(frame(type: 0x0, flags: 0x8, stream: 1, []), .frameSizeError)
        // Pad Length equal to the payload length leaves −1 data bytes.
        expectConnectionError(frame(type: 0x0, flags: 0x8, stream: 1, [3, 0, 0]), .protocolError)
        expectConnectionError(frame(type: 0x0, flags: 0x8, stream: 1, [255]), .protocolError)
        expectSplitInvariant(frame(type: 0x0, flags: 0x8, stream: 1, [2, 0, 0]), [
            .dataHeader(.init(streamID: .s(1), dataLength: 0, flowControlledLength: 3, endStream: false)),
        ])
    }

    @Test func headers() {
        expectConnectionError(frame(type: 0x1, flags: 0x4, stream: 0, fragment), .protocolError)
        expectConnectionError(frame(type: 0x1, flags: 0x8, stream: 1, []), .frameSizeError)
        expectConnectionError(frame(type: 0x1, flags: 0x20, stream: 1, [0, 0, 0, 3]), .frameSizeError)
        expectConnectionError(frame(type: 0x1, flags: 0x28, stream: 1, [0, 0, 0, 0, 3]), .frameSizeError)
        expectConnectionError(frame(type: 0x1, flags: 0x8, stream: 1, [4, 0xaa, 0, 0]), .protocolError)
        expectSplitInvariant(frame(type: 0x1, flags: 0x8, stream: 1, [3, 0, 0, 0]), [
            .headers(stream: 1, endStream: false, endHeaders: false, priority: nil, []),
        ])
        expectConnectionError(frame(type: 0x1, flags: 0x28, stream: 1, [1, 0, 0, 0, 3, 15]), .protocolError)
        expectSplitInvariant(frame(type: 0x1, flags: 0x28, stream: 1, [0, 0, 0, 0, 3, 15]), [
            .headers(stream: 1, endStream: false, endHeaders: false, priority: HTTP2Priority(dependency: .s(3)), []),
        ])
    }

    @Test func priority() {
        expectConnectionError(frame(type: 0x2, stream: 0, [0, 0, 0, 1, 15]), .protocolError)
        for length in [0, 4, 6] {
            expectSplitInvariant(frame(type: 0x2, stream: 3, [UInt8](repeating: 0, count: length)) + pingFrame, [
                .streamError(stream: 3, .frameSizeError), pingEvent,
            ])
        }
        expectSplitInvariant(frame(type: 0x2, stream: 3, [0x80, 0, 0, 3, 15]) + pingFrame, [
            .streamError(stream: 3, .protocolError), pingEvent,
        ])
    }

    @Test func rstStream() {
        expectConnectionError(frame(type: 0x3, stream: 0, [0, 0, 0, 8]), .protocolError)
        expectConnectionError(frame(type: 0x3, stream: 1, [0, 0, 8]), .frameSizeError)
        expectConnectionError(frame(type: 0x3, stream: 1, [0, 0, 0, 0, 8]), .frameSizeError)
    }

    @Test func settingsFraming() {
        expectConnectionError(frame(type: 0x4, stream: 1, []), .protocolError)
        expectConnectionError(frame(type: 0x4, flags: 0x1, stream: 1, []), .protocolError)
        expectConnectionError(frame(type: 0x4, stream: 0, [0, 1, 0, 0, 0]), .frameSizeError)
        expectConnectionError(frame(type: 0x4, stream: 0, setting(0x3, 1) + [0]), .frameSizeError)
        expectConnectionError(frame(type: 0x4, flags: 0x1, stream: 0, setting(0x3, 1)), .frameSizeError)
    }

    @Test func settingsValues() {
        func payload(_ id: UInt16, _ value: UInt32) -> [UInt8] { frame(type: 0x4, stream: 0, setting(id, value)) }
        expectConnectionError(payload(0x2, 2), .protocolError)
        expectConnectionError(payload(0x4, 0x8000_0000), .flowControlError)
        expectConnectionError(payload(0x5, 16_383), .protocolError)
        expectConnectionError(payload(0x5, 16_777_216), .protocolError)
        expectConnectionError(payload(0x8, 2), .protocolError)
        expectConnectionError(payload(0x9, 2), .protocolError)
        // A server may not enable push; a client may.
        expectConnectionError(payload(0x2, 1), .protocolError, client)
        expectSplitInvariant(payload(0x2, 1), [.settings(HTTP2Settings(enablePush: true))])
        expectSplitInvariant(payload(0x2, 0), [.settings(HTTP2Settings(enablePush: false))], client)
        // Boundary values are accepted.
        expectSplitInvariant(payload(0x4, 0x7fff_ffff), [.settings(HTTP2Settings(initialWindowSize: 0x7fff_ffff))])
        expectSplitInvariant(payload(0x5, 16_384), [.settings(HTTP2Settings(maxFrameSize: 16_384))])
        expectSplitInvariant(payload(0x5, 16_777_215), [.settings(HTTP2Settings(maxFrameSize: 16_777_215))])
    }

    @Test func pushPromise() {
        let valid = frame(type: 0x5, flags: 0x4, stream: 1, [0, 0, 0, 2] + fragment)
        expectConnectionError(valid, .protocolError, server)
        expectConnectionError(frame(type: 0x5, flags: 0x4, stream: 0, [0, 0, 0, 2]), .protocolError, client)
        expectConnectionError(frame(type: 0x5, stream: 1, [0, 0, 2]), .frameSizeError, client)
        expectConnectionError(frame(type: 0x5, flags: 0x8, stream: 1, [0, 0, 0, 2]), .frameSizeError, client)
        expectConnectionError(frame(type: 0x5, flags: 0x8, stream: 1, [1, 0, 0, 0, 2]), .protocolError, client)
        expectSplitInvariant(frame(type: 0x5, flags: 0x8, stream: 1, [1, 0, 0, 0, 2, 0]), [
            .pushPromise(stream: 1, promised: 2, endHeaders: false, []),
        ], client)
    }

    @Test func ping() {
        expectConnectionError(frame(type: 0x6, stream: 1, [UInt8](repeating: 0, count: 8)), .protocolError)
        expectConnectionError(frame(type: 0x6, stream: 0, [UInt8](repeating: 0, count: 7)), .frameSizeError)
        expectConnectionError(frame(type: 0x6, flags: 0x1, stream: 0, [UInt8](repeating: 0, count: 9)), .frameSizeError)
    }

    @Test func goaway() {
        expectConnectionError(frame(type: 0x7, stream: 1, [UInt8](repeating: 0, count: 8)), .protocolError)
        expectConnectionError(frame(type: 0x7, stream: 0, [UInt8](repeating: 0, count: 7)), .frameSizeError)
    }

    @Test func windowUpdate() {
        expectConnectionError(frame(type: 0x8, stream: 0, [0, 0, 1]), .frameSizeError)
        expectConnectionError(frame(type: 0x8, stream: 1, [0, 0, 0, 0, 1]), .frameSizeError)
        expectConnectionError(frame(type: 0x8, stream: 0, [0, 0, 0, 0]), .protocolError)
        expectConnectionError(frame(type: 0x8, stream: 0, [0x80, 0, 0, 0]), .protocolError)
        expectSplitInvariant(frame(type: 0x8, stream: 5, [0x80, 0, 0, 0]) + pingFrame, [
            .streamError(stream: 5, .protocolError), pingEvent,
        ])
    }

    @Test func continuation() {
        expectConnectionError(frame(type: 0x9, flags: 0x4, stream: 0, fragment), .protocolError)
    }

    @Test func streamIDRulesForEveryType() {
        // Types that require a stream: stream 0 is PROTOCOL_ERROR.
        for type: UInt8 in [0x0, 0x1, 0x2, 0x3, 0x9] {
            let length = type == 0x2 ? 5 : 4
            #expect(parse([frame(type: type, stream: 0, [UInt8](repeating: 0, count: length))]).frames
                == [.connectionError(.protocolError)], "type \(type)")
        }
        // Types that require stream 0: any stream is PROTOCOL_ERROR.
        for (type, length): (UInt8, Int) in [(0x4, 0), (0x6, 8), (0x7, 8)] {
            #expect(parse([frame(type: type, stream: 2, [UInt8](repeating: 0, count: length))]).frames
                == [.connectionError(.protocolError)], "type \(type)")
        }
        // WINDOW_UPDATE and unknown types are valid on both.
        for stream: UInt32 in [0, 1] {
            #expect(parse([frame(type: 0x8, stream: stream, [0, 0, 0, 1])]).frames == [.windowUpdate(stream: stream, 1)])
            #expect(parse([frame(type: 0x20, stream: stream, [])]).frames.count == 1)
        }
    }
}
