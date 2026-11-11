import Testing
import HTTP3

private let request = H3FrameParser.Configuration(streamKind: .request, role: .server)
private let clientRequest = H3FrameParser.Configuration(streamKind: .request, role: .client)
private let control = H3FrameParser.Configuration(streamKind: .control, role: .server)
private let clientControl = H3FrameParser.Configuration(streamKind: .control, role: .client)

private let fieldSection: [UInt8] = [0x00, 0x00, 0xd1, 0xd7, 0x51, 0x84, 0x62, 0xd2, 0x7a, 0x9f]

/// Asserts that every split of `bytes` parses to `expected`.
private func expectSplitInvariant(
    _ bytes: [UInt8], _ configuration: H3FrameParser.Configuration, _ expected: [ParsedFrame],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for chunks in everySplit(of: bytes) {
        let frames = parse(chunks, configuration: configuration).frames
        #expect(frames == expected, "chunks \(chunks.map(\.count))", sourceLocation: sourceLocation)
        if frames != expected { return }
    }
}

private func firstError(_ bytes: [UInt8], _ configuration: H3FrameParser.Configuration) -> HTTP3Error? {
    var errors: Set<HTTP3Error> = []
    for chunks in everySplit(of: bytes) {
        for frame in parse(chunks, configuration: configuration).frames {
            if case .error(let error) = frame { errors.insert(error) }
        }
    }
    // Every split must fail the same way.
    return errors.count == 1 ? errors.first : nil
}

@Suite struct H3FrameRoundTripTests {
    @Test func data() throws {
        var builder = FrameBuilder()
        let payload = (0..<300).map { UInt8(truncatingIfNeeded: $0) }
        try builder.data(payload)
        try builder.data([])
        #expect(Array(builder.bytes.prefix(3)) == [0x00, 0x41, 0x2c])
        expectSplitInvariant(builder.bytes, request, [.dataHeader(300), .data(payload), .dataHeader(0)])
    }

    @Test func dataHeaderThenCallerWrittenPayload() throws {
        var bytes: [UInt8] = []
        try H3FrameEncoder.encodeDataHeader(length: 4, into: &bytes)
        bytes += [1, 2, 3, 4]
        expectSplitInvariant(bytes, request, [.dataHeader(4), .data([1, 2, 3, 4])])
    }

    @Test func headers() throws {
        var builder = FrameBuilder()
        try builder.headers(fieldSection)
        #expect(Array(builder.bytes.prefix(2)) == [0x01, UInt8(fieldSection.count)])
        expectSplitInvariant(builder.bytes, request, [.headers(fieldSection)])
    }

    @Test func requestStreamSequence() throws {
        var builder = FrameBuilder()
        try builder.headers(fieldSection)
        try builder.data(Array("hello".utf8))
        try builder.frame(.reserved(7), [9, 9, 9])
        try builder.data(Array(" world".utf8))
        try builder.headers([0x00, 0x00])
        expectSplitInvariant(builder.bytes, request, [
            .headers(fieldSection),
            .dataHeader(5), .data(Array("hello".utf8)),
            .dataHeader(6), .data(Array(" world".utf8)),
            .headers([0x00, 0x00]),
        ])
    }

    @Test func settings() throws {
        let settings = H3Settings(
            qpackMaxTableCapacity: 4096, maxFieldSectionSize: 16_384, qpackBlockedStreams: 100,
            enableConnectProtocol: true, h3Datagram: false)
        var builder = FrameBuilder()
        try builder.settings(settings, grease: (id: 0x1f * 3 + 0x21, value: 12_345))
        expectSplitInvariant(builder.bytes, control, [.settings(settings)])
    }

    @Test func emptySettings() throws {
        var builder = FrameBuilder()
        try builder.settings(H3Settings())
        #expect(builder.bytes == [0x04, 0x00])
        expectSplitInvariant(builder.bytes, control, [.settings(H3Settings())])
    }

    @Test func controlStreamFrames() throws {
        var builder = FrameBuilder()
        try builder.settings(H3Settings(maxFieldSectionSize: 8192))
        try H3FrameEncoder.encodeCancelPush(pushID: 7, into: &builder.bytes)
        try H3FrameEncoder.encodeMaxPushID(1_000_000, into: &builder.bytes)
        try builder.frame(H3FrameType(rawValue: 0x1234), [1, 2, 3])
        try H3FrameEncoder.encodeGoaway(id: 4 * 1_000_000_000, into: &builder.bytes)
        expectSplitInvariant(builder.bytes, control, [
            .settings(H3Settings(maxFieldSectionSize: 8192)),
            .cancelPush(7),
            .maxPushID(1_000_000),
            .goaway(4_000_000_000),
        ])
    }

    @Test func singleVarintFrameLayouts() throws {
        var bytes: [UInt8] = []
        try H3FrameEncoder.encodeCancelPush(pushID: 3, into: &bytes)
        #expect(bytes == [0x03, 0x01, 0x03])
        bytes.removeAll()
        try H3FrameEncoder.encodeGoaway(id: 16_384, into: &bytes)
        #expect(bytes == [0x07, 0x04, 0x80, 0x00, 0x40, 0x00])
        bytes.removeAll()
        try H3FrameEncoder.encodeMaxPushID(64, into: &bytes)
        #expect(bytes == [0x0d, 0x02, 0x40, 0x40])
    }

    @Test func goawayAndCancelPushFromServerControlStream() throws {
        // A client receives GOAWAY (stream ID) and CANCEL_PUSH on the server's control stream.
        var builder = FrameBuilder()
        try builder.settings(H3Settings())
        try H3FrameEncoder.encodeCancelPush(pushID: 0, into: &builder.bytes)
        try H3FrameEncoder.encodeGoaway(id: 8, into: &builder.bytes)
        expectSplitInvariant(builder.bytes, clientControl, [.settings(H3Settings()), .cancelPush(0), .goaway(8)])
    }

    @Test func pushPromiseOnClient() throws {
        var builder = FrameBuilder()
        try builder.headers(fieldSection)
        try builder.pushPromise(16_384, fieldSection)
        try builder.data([42])
        expectSplitInvariant(builder.bytes, clientRequest, [
            .headers(fieldSection), .pushPromise(16_384, fieldSection), .dataHeader(1), .data([42]),
        ])
    }

    @Test func reservedAndUnknownFramesAreSkipped() throws {
        var builder = FrameBuilder()
        try builder.frame(.reserved(0), [])
        try builder.frame(.reserved(1), Array(repeating: 0xee, count: 70))
        try builder.frame(H3FrameType(rawValue: 0x0e), [1])
        try builder.frame(H3FrameType(rawValue: QUICVarint.maxValue), [1, 2])
        try builder.headers(fieldSection)
        try builder.frame(.reserved(1_000_000), [3])
        #expect(builder.bytes.first == 0x21)
        expectSplitInvariant(builder.bytes, request, [.headers(fieldSection)])
    }

    @Test func nonMinimalVarintsInFrameHeadersAreAccepted() {
        // HEADERS with an 8-byte type and a 2-byte length.
        let bytes: [UInt8] = [0xc0, 0, 0, 0, 0, 0, 0, 0x01, 0x40, 0x02, 0x00, 0x00]
        expectSplitInvariant(bytes, request, [.headers([0x00, 0x00])])
    }

    @Test func wholePayloadsAreReportedInPlaceAndSplitOnesBuffered() throws {
        var builder = FrameBuilder()
        try builder.headers(fieldSection)
        let whole = parse([builder.bytes], configuration: request)
        #expect(whole.frames == [.headers(fieldSection)])
        #expect(whole.inPlacePayloads == 1)
        #expect(whole.bufferedPayloads == 0)

        let split = parse([Array(builder.bytes.prefix(5)), Array(builder.bytes.dropFirst(5))], configuration: request)
        #expect(split.frames == [.headers(fieldSection)])
        #expect(split.bufferedPayloads == 1)
    }

    @Test func dataIsSlicedFromTheInputWithoutBuffering() throws {
        var builder = FrameBuilder()
        try builder.data(Array(repeating: 7, count: 10))
        var parser = H3FrameParser(configuration: request)
        try builder.bytes.withUnsafeBytes { input in
            let header = try parser.parse(input)
            #expect(header == H3FrameParser.Output(.dataHeader(length: 10), consumed: 2))
            // Half the payload arrives: it is reported straight away, as a range of the input.
            let partial = try parser.parse(UnsafeRawBufferPointer(rebasing: input[2..<7]))
            #expect(partial == H3FrameParser.Output(.data(0..<5), consumed: 5))
            #expect(!parser.isAtFrameBoundary)
            let rest = try parser.parse(UnsafeRawBufferPointer(rebasing: input[7...]))
            #expect(rest == H3FrameParser.Output(.data(0..<5), consumed: 5))
            #expect(parser.isAtFrameBoundary)
        }
    }

    @Test func largeUnknownFrameStreamsThrough() throws {
        // A 1 MiB reserved frame is skipped as it arrives, well past every buffering limit.
        var bytes: [UInt8] = []
        try H3FrameEncoder.encodeFrameHeader(type: .reserved(2), length: 1 << 20, into: &bytes)
        let header = bytes
        var parser = H3FrameParser(configuration: H3FrameParser.Configuration(maxFieldSectionLength: 16, maxSettingsLength: 16))
        let chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let first = try header.withUnsafeBytes { input throws in try parser.parse(input) }
        #expect(first.event == .needsMoreData)
        for _ in 0..<16 {
            let output = try chunk.withUnsafeBytes { input throws in try parser.parse(input) }
            #expect(output == H3FrameParser.Output(.needsMoreData, consumed: chunk.count))
        }
        #expect(parser.isAtFrameBoundary)
    }
}

@Suite struct H3FrameErrorTests {
    @Test(arguments: [UInt64(0x02), 0x06, 0x08, 0x09])
    func http2OnlyFrameTypesAreUnexpected(type: UInt64) throws {
        var builder = FrameBuilder()
        try builder.frame(H3FrameType(rawValue: type), [0])
        #expect(H3FrameType(rawValue: type).isHTTP2Only)
        #expect(firstError(builder.bytes, request) == .frameUnexpected)
        #expect(firstError(builder.bytes, clientRequest) == .frameUnexpected)

        var onControl = FrameBuilder()
        try onControl.settings(H3Settings())
        try onControl.frame(H3FrameType(rawValue: type), [0])
        #expect(firstError(onControl.bytes, control) == .frameUnexpected)
    }

    @Test func pushPromiseFromClientIsUnexpected() throws {
        var builder = FrameBuilder()
        try builder.headers(fieldSection)
        try builder.pushPromise(0, fieldSection)
        #expect(firstError(builder.bytes, request) == .frameUnexpected)
    }

    @Test(arguments: [H3FrameType.settings, .cancelPush, .goaway, .maxPushID])
    func controlFramesOnRequestStreamAreUnexpected(type: H3FrameType) throws {
        var builder = FrameBuilder()
        try builder.frame(type, [0])
        #expect(firstError(builder.bytes, request) == .frameUnexpected)
    }

    @Test(arguments: [H3FrameType.data, .headers, .pushPromise])
    func requestFramesOnControlStreamAreUnexpected(type: H3FrameType) throws {
        var builder = FrameBuilder()
        try builder.settings(H3Settings())
        try builder.frame(type, [0, 0])
        #expect(firstError(builder.bytes, control) == .frameUnexpected)
        #expect(firstError(builder.bytes, clientControl) == .frameUnexpected)
    }

    @Test func maxPushIDToClientIsUnexpected() throws {
        var builder = FrameBuilder()
        try builder.settings(H3Settings())
        try H3FrameEncoder.encodeMaxPushID(4, into: &builder.bytes)
        #expect(firstError(builder.bytes, clientControl) == .frameUnexpected)
    }

    @Test func controlStreamMustStartWithSettings() throws {
        for first in [H3FrameType.goaway, .maxPushID, .reserved(0), H3FrameType(rawValue: 0x1234)] {
            var builder = FrameBuilder()
            try builder.frame(first, [0])
            #expect(firstError(builder.bytes, control) == .missingSettings, "\(first)")
        }
    }

    @Test func secondSettingsIsUnexpected() throws {
        var builder = FrameBuilder()
        try builder.settings(H3Settings())
        try builder.settings(H3Settings())
        #expect(firstError(builder.bytes, control) == .frameUnexpected)
    }

    @Test func oversizedFieldSectionIsExcessiveLoad() throws {
        let limited = H3FrameParser.Configuration(streamKind: .request, role: .client, maxFieldSectionLength: 8)
        var builder = FrameBuilder()
        try builder.headers(Array(repeating: 0, count: 8))
        expectSplitInvariant(builder.bytes, limited, [.headers(Array(repeating: 0, count: 8))])

        var tooBig = FrameBuilder()
        try tooBig.headers(Array(repeating: 0, count: 9))
        #expect(firstError(tooBig.bytes, limited) == .excessiveLoad)

        var push = FrameBuilder()
        try push.pushPromise(1, Array(repeating: 0, count: 8))
        #expect(firstError(push.bytes, limited) == .excessiveLoad)

        // The limit is checked from the length alone, before any payload arrives.
        var header: [UInt8] = []
        try H3FrameEncoder.encodeFrameHeader(type: .headers, length: QUICVarint.maxValue, into: &header)
        #expect(firstError(header, request) == .excessiveLoad)
    }

    @Test func oversizedSettingsIsExcessiveLoad() throws {
        let limited = H3FrameParser.Configuration(streamKind: .control, maxSettingsLength: 4)
        var builder = FrameBuilder()
        try builder.settings(H3Settings(qpackMaxTableCapacity: 1 << 20))
        #expect(builder.bytes.count > 6)
        #expect(firstError(builder.bytes, limited) == .excessiveLoad)
    }

    @Test func singleVarintFramesWithBadLengthsAreFrameErrors() throws {
        var builder = FrameBuilder()
        try builder.settings(H3Settings())
        let prefix = builder.bytes
        let bad: [[UInt8]] = [
            [0x03, 0x00],                                  // CANCEL_PUSH, empty
            [0x07, 0x09] + Array(repeating: 0, count: 9),  // GOAWAY, longer than any varint
            [0x0d, 0x02, 0x05, 0x00],                      // MAX_PUSH_ID, trailing byte
            [0x07, 0x01, 0x40],                            // GOAWAY, truncated two-byte varint
        ]
        for frame in bad {
            #expect(firstError(prefix + frame, control) == .frameError, "\(frame)")
        }
    }

    @Test func pushPromiseWithoutPushIDIsFrameError() {
        #expect(firstError([0x05, 0x00], clientRequest) == .frameError)
        #expect(firstError([0x05, 0x01, 0x40], clientRequest) == .frameError)
    }

    @Test func streamEndingInsideAFrameIsFrameError() throws {
        var builder = FrameBuilder()
        try builder.headers(fieldSection)
        try builder.data([1, 2, 3])
        let bytes = builder.bytes
        // Every proper prefix that is not a frame boundary ends inside a frame.
        let boundaries: Set<Int> = [0, fieldSection.count + 2, bytes.count]
        for cut in 0...bytes.count {
            let frames = parse([Array(bytes[..<cut])], configuration: request).frames
            if boundaries.contains(cut) {
                #expect(frames.last.map { if case .unfinished = $0 { false } else { true } } ?? true, "cut \(cut)")
            } else {
                #expect(frames.last == .unfinished(.frameError), "cut \(cut)")
            }
        }
        // A stream ending inside a type varint or a reserved frame also counts.
        #expect(parse([[0x40]], configuration: request).frames == [.unfinished(.frameError)])
        #expect(parse([[0x21, 0x02, 0x00]], configuration: request).frames == [.unfinished(.frameError)])
    }
}

@Suite struct H3SettingsTests {
    private func parseSettings(_ payload: [UInt8]) throws(HTTP3Error) -> H3Settings {
        let result: Result<H3Settings, HTTP3Error> = payload.withUnsafeBytes { bytes in
            do throws(HTTP3Error) { return .success(try H3Settings(payload: bytes)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    @Test func knownSettingsDecode() throws {
        let settings = try parseSettings([0x01, 0x50, 0x00, 0x06, 0x44, 0x00, 0x07, 0x10, 0x08, 0x01, 0x33, 0x01])
        #expect(settings == H3Settings(
            qpackMaxTableCapacity: 4096, maxFieldSectionSize: 1024, qpackBlockedStreams: 16,
            enableConnectProtocol: true, h3Datagram: true))
    }

    @Test func unknownAndReservedSettingsAreIgnored() throws {
        let settings = try parseSettings([0x21, 0x05, 0x40, 0x40, 0x01, 0x07, 0x01, 0x80, 0x00, 0x12, 0x34, 0x00])
        #expect(settings == H3Settings(qpackBlockedStreams: 1))
    }

    @Test(arguments: [UInt8(0x02), 0x03, 0x04, 0x05])
    func http2SettingsAreSettingsErrors(id: UInt8) {
        #expect(throws: HTTP3Error.settingsError) { try parseSettings([id, 0x00]) }
        #expect(throws: HTTP3Error.settingsError) { try parseSettings([0x01, 0x00, id, 0x00]) }
    }

    @Test func duplicatesAreSettingsErrors() {
        #expect(throws: HTTP3Error.settingsError) { try parseSettings([0x06, 0x01, 0x06, 0x02]) }
        // Duplicates of unknown identifiers count too, even in a different varint form.
        #expect(throws: HTTP3Error.settingsError) { try parseSettings([0x21, 0x00, 0x01, 0x00, 0x40, 0x21, 0x00]) }
    }

    @Test func booleanSettingsMustBeZeroOrOne() {
        #expect(throws: HTTP3Error.settingsError) { try parseSettings([0x08, 0x02]) }
        #expect(throws: HTTP3Error.settingsError) { try parseSettings([0x33, 0x02]) }
    }

    @Test func truncatedPairIsFrameError() {
        #expect(throws: HTTP3Error.frameError) { try parseSettings([0x06]) }
        #expect(throws: HTTP3Error.frameError) { try parseSettings([0x06, 0x40]) }
    }

    @Test func settingsFrameErrorsSurfaceThroughTheParser() throws {
        #expect(firstError([0x04, 0x04, 0x06, 0x01, 0x06, 0x02], control) == .settingsError)
        #expect(firstError([0x04, 0x02, 0x04, 0x00], control) == .settingsError)
        #expect(firstError([0x04, 0x01, 0x06], control) == .frameError)
    }

    @Test func encoderRejectsOutOfRangeValues() {
        var bytes: [UInt8] = []
        #expect(throws: QUICVarintError.valueOutOfRange(1 << 62)) {
            try H3FrameEncoder.encodeSettings(H3Settings(maxFieldSectionSize: 1 << 62), into: &bytes)
        }
        #expect(bytes.isEmpty)
    }
}

@Suite struct H3StreamTypeTests {
    @Test func knownTypes() throws {
        let cases: [(UInt64, H3UniStreamType)] = [
            (0x00, .control), (0x01, .push), (0x02, .qpackEncoder), (0x03, .qpackDecoder),
        ]
        for (raw, type) in cases {
            #expect(H3UniStreamType(rawValue: raw) == type)
            #expect(type.rawValue == raw)
            #expect(type.isKnown)
            var bytes: [UInt8] = []
            try type.encode(into: &bytes)
            #expect(bytes == [UInt8(raw)])
        }
    }

    @Test func reservedAndUnknownTypesAreSkipped() {
        for n: UInt64 in [0, 1, 2, 1000, (QUICVarint.maxValue - 0x21) / 0x1f] {
            let raw = 0x1f * n + 0x21
            #expect(H3UniStreamType(rawValue: raw) == .reserved(raw))
            #expect(!H3UniStreamType(rawValue: raw).isKnown)
        }
        #expect(H3UniStreamType(rawValue: 0x04) == .unknown(0x04))
        #expect(H3UniStreamType(rawValue: 0x22) == .unknown(0x22))
        #expect(!H3UniStreamType(rawValue: 0x04).isKnown)
    }

    @Test func classifierHandlesSplitTypesAndLeavesTheBody() throws {
        var bytes: [UInt8] = []
        try QUICVarint.encode(0x02, length: 8, into: &bytes)
        bytes += [0xaa, 0xbb]
        for chunks in everySplit(of: bytes) {
            var classifier = UniStreamClassifier()
            var result: UniStreamClassifier.Result = .needsMoreData
            var bodyStart = 0
            var fed = 0
            for chunk in chunks where result == .needsMoreData {
                result = chunk.withUnsafeBytes { classifier.classify($0) }
                if case .classified(_, let consumed) = result { bodyStart = fed + consumed }
                fed += chunk.count
            }
            #expect(result.isClassified(as: .qpackEncoder))
            #expect(bodyStart == 8)
        }
    }

    @Test func classifierReportsReservedTypes() {
        var classifier = UniStreamClassifier()
        let result = [UInt8]([0x40, 0x40, 0xff]).withUnsafeBytes { classifier.classify($0) }
        #expect(result == .classified(.reserved(0x40), consumed: 2))
    }
}

extension UniStreamClassifier.Result {
    func isClassified(as type: H3UniStreamType) -> Bool {
        if case .classified(let found, _) = self { return found == type }
        return false
    }
}

@Suite struct HTTP3ErrorTests {
    @Test func everyRFC9114Code() {
        let expected: [(HTTP3Error, UInt64, String)] = [
            (.noError, 0x0100, "H3_NO_ERROR"),
            (.generalProtocolError, 0x0101, "H3_GENERAL_PROTOCOL_ERROR"),
            (.internalError, 0x0102, "H3_INTERNAL_ERROR"),
            (.streamCreationError, 0x0103, "H3_STREAM_CREATION_ERROR"),
            (.closedCriticalStream, 0x0104, "H3_CLOSED_CRITICAL_STREAM"),
            (.frameUnexpected, 0x0105, "H3_FRAME_UNEXPECTED"),
            (.frameError, 0x0106, "H3_FRAME_ERROR"),
            (.excessiveLoad, 0x0107, "H3_EXCESSIVE_LOAD"),
            (.idError, 0x0108, "H3_ID_ERROR"),
            (.settingsError, 0x0109, "H3_SETTINGS_ERROR"),
            (.missingSettings, 0x010a, "H3_MISSING_SETTINGS"),
            (.requestRejected, 0x010b, "H3_REQUEST_REJECTED"),
            (.requestCancelled, 0x010c, "H3_REQUEST_CANCELLED"),
            (.requestIncomplete, 0x010d, "H3_REQUEST_INCOMPLETE"),
            (.messageError, 0x010e, "H3_MESSAGE_ERROR"),
            (.connectError, 0x010f, "H3_CONNECT_ERROR"),
            (.versionFallback, 0x0110, "H3_VERSION_FALLBACK"),
        ]
        #expect(HTTP3Error.allCases.count == expected.count)
        for (code, value, name) in expected {
            #expect(code.rawValue == value)
            #expect(HTTP3Error(rawValue: value) == code)
            #expect("\(code.name)" == name)
        }
        #expect(HTTP3Error(rawValue: 0x0111) == nil)
        #expect(H3ErrorCode.frameUnexpected == HTTP3Error.frameUnexpected)
    }

    @Test func reservedErrorCodes() {
        #expect(HTTP3Error.isReserved(0x21))
        #expect(HTTP3Error.isReserved(0x1f * 9 + 0x21))
        #expect(!HTTP3Error.isReserved(0x0100))
        #expect(!HTTP3Error.isReserved(0x20))
    }
}
