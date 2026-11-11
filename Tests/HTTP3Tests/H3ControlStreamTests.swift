import HTTP3
import HTTPCore
import HTTPTestSupport
import Testing

/// #0100: control streams, SETTINGS and unidirectional stream classification, over the
/// in-memory multiplexed transport. Each connection error asserts the exact RFC 9114 code.
@Suite(.timeLimit(.minutes(1)))
struct H3ControlStreamTests {
    // MARK: SETTINGS exchange

    @Test func serverOpensControlAndQPACKStreamsWithSettings() async throws {
        try await withH3Server(handler: PathHandler()) { client, _ in
            var iterator = client.inboundStreams.makeAsyncIterator()
            let control = try #require(try await iterator.next())
            let encoder = try #require(try await iterator.next())
            let decoder = try #require(try await iterator.next())
            #expect(control.streamID == 3 && encoder.streamID == 7 && decoder.streamID == 11)

            let expectedSettings = H3Settings(qpackMaxTableCapacity: 0, maxFieldSectionSize: 16 * 1024, qpackBlockedStreams: 0)
            let preface = [0x00] + H3Wire.settings(expectedSettings)
            #expect(try await receive(preface.count, from: control) == preface)
            #expect(try await receive(1, from: encoder) == [0x02])
            #expect(try await receive(1, from: decoder) == [0x03])
            // The streams stay open (closing one would be H3_CLOSED_CRITICAL_STREAM for us).
            #expect(!client.isClosed)
        }
    }

    @Test func enableConnectProtocolIsAdvertisedWhenConfigured() async throws {
        let configuration = H3Configuration(maxFieldSectionSize: 4096, enableConnectProtocol: true)
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            var iterator = client.inboundStreams.makeAsyncIterator()
            let control = try #require(try await iterator.next())
            let expected = [0x00] + H3Wire.settings(H3Settings(
                qpackMaxTableCapacity: 0, maxFieldSectionSize: 4096, qpackBlockedStreams: 0, enableConnectProtocol: true))
            #expect(try await receive(expected.count, from: control) == expected)
        }
    }

    @Test func peerSettingsAndQPACKStreamsAreAccepted() async throws {
        try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream([0x00] + H3Wire.settings(H3Settings(
                qpackMaxTableCapacity: 4096, maxFieldSectionSize: 8192, qpackBlockedStreams: 16)))
            // Capacity 0, and a Stream Cancellation: both legal against our settings.
            try await h3.openUniStream([0x02, 0x20])
            try await h3.openUniStream([0x03, 0x41])
            let response = try await h3.send(H3Wire.request(path: "/after-settings"))
            #expect(response.status == "200")
            #expect(response.bodyString == "hello /after-settings")
            #expect(!client.isClosed)
        }
    }

    @Test func unknownAndReservedFramesOnControlStreamAreSkipped() async throws {
        try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream(
                [0x00] + H3Wire.settings() + H3Wire.frame(.reserved(7), [9, 9]) + H3Wire.frame(H3FrameType(rawValue: 0x3f), []))
            let response = try await h3.send()
            #expect(response.status == "200")
            #expect(!client.isClosed)
        }
    }

    // MARK: Control-stream rules

    @Test func controlStreamMustStartWithSettings() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openControlStream([0x00] + H3Wire.frame(.goaway, H3Wire.varint(0)))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.missingSettings.rawValue)
    }

    @Test func secondSettingsFrameIsFrameUnexpected() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openControlStream([0x00] + H3Wire.settings() + H3Wire.settings())
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.frameUnexpected.rawValue)
    }

    @Test func dataOnControlStreamIsFrameUnexpected() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openControlStream([0x00] + H3Wire.settings() + H3Wire.data([1]))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.frameUnexpected.rawValue)
    }

    @Test(arguments: [
        [(UInt64(0x06), UInt64(100)), (0x06, 200)],   // duplicate identifier
        [(UInt64(0x02), UInt64(0))],                   // HTTP/2 SETTINGS_ENABLE_PUSH
        [(UInt64(0x08), UInt64(2))],                   // boolean setting out of range
    ])
    func invalidSettingsAreSettingsError(pairs: [(UInt64, UInt64)]) async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openControlStream([0x00] + H3Wire.rawSettings(pairs))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.settingsError.rawValue)
    }

    @Test func secondControlStreamIsStreamCreationError() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            try await h3.openControlStream()
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.streamCreationError.rawValue)
    }

    @Test func closingControlStreamIsClosedCriticalStream() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            let control = try await H3TestClient(transport: client).openControlStream()
            try await control.send(ByteBuffer(), endOfStream: true)
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.closedCriticalStream.rawValue)
    }

    @Test func resettingControlStreamIsClosedCriticalStream() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            let control = try await h3.openControlStream()
            // A reset discards unread bytes, so let the server classify the stream first.
            #expect(try await h3.send().status == "200")
            await control.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.closedCriticalStream.rawValue)
    }

    @Test func clientPushStreamIsStreamCreationError() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openUniStream([0x01, 0x00])
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.streamCreationError.rawValue)
    }

    @Test(arguments: [0x21, 0x21 + 0x1f * 5, 0x54] as [UInt64])
    func reservedAndUnknownStreamTypesAreIgnoredWithStopSending(type: UInt64) async throws {
        try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            let ignored = try await h3.openUniStream(H3Wire.varint(type) + [1, 2, 3])
            // Wait for the server's STOP_SENDING: later sends fail.
            while (try? await ignored.send(ByteBuffer(bytes: [0]), endOfStream: false)) != nil {
                await Task.yield()
            }
            #expect(ignored.receivedStopSendingCode == HTTP3Error.streamCreationError.rawValue)
            let response = try await h3.send()
            #expect(response.status == "200")
            #expect(!client.isClosed)
        }
    }

    // MARK: QPACK streams

    @Test func encoderStreamInsertIsEncoderStreamError() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            // Set Dynamic Table Capacity 1: above the 0 we advertised.
            try await H3TestClient(transport: client).openUniStream([0x02, 0x21])
            return await serverCloseCode(client)
        }
        #expect(code == QPACKErrorCode.encoderStream)
    }

    @Test func decoderStreamSectionAcknowledgmentIsDecoderStreamError() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openUniStream([0x03, 0x80])
            return await serverCloseCode(client)
        }
        #expect(code == QPACKErrorCode.decoderStream)
    }

    @Test(arguments: [0x02, 0x03] as [UInt8])
    func closingQPACKStreamIsClosedCriticalStream(type: UInt8) async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openUniStream([type], fin: true)
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.closedCriticalStream.rawValue)
    }

    @Test(arguments: [0x02, 0x03] as [UInt8])
    func secondQPACKStreamIsStreamCreationError(type: UInt8) async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openUniStream([type])
            try await h3.openUniStream([type])
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.streamCreationError.rawValue)
    }

    // MARK: Shutdown

    @Test func shutdownClosesWithNoError() async throws {
        let shutdown = ShutdownSignal()
        let code = try await withH3Server(handler: PathHandler(), shutdown: shutdown) { client, _ in
            let response = try await H3TestClient(transport: client).send()
            #expect(response.status == "200")
            shutdown.trigger()
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.noError.rawValue)
    }
}

enum QPACKErrorCode {
    static let encoderStream: UInt64 = 0x0201
    static let decoderStream: UInt64 = 0x0202
}
