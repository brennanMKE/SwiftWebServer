import HTTP3
import Testing

/// #0100: the pure connection state machine.
struct H3ConnectionStateTests {
    @Test func classifiesStreamsOnce() {
        var connection = H3Connection()
        #expect(connection.handle(.uniStream(.control)) == .readControlStream)
        #expect(connection.handle(.uniStream(.qpackEncoder)) == .readQPACKEncoderStream)
        #expect(connection.handle(.uniStream(.qpackDecoder)) == .readQPACKDecoderStream)
        #expect(connection.handle(.uniStream(.reserved(0x21))) == .ignoreStream(stopSendingCode: 0x103))
        #expect(connection.handle(.uniStream(.unknown(0x54))) == .ignoreStream(stopSendingCode: 0x103))
        #expect(connection.handle(.requestStream(streamID: 0)) == .serveRequest)
        #expect(connection.handle(.requestStream(streamID: 8)) == .serveRequest)
        #expect(connection.largestRequestStreamID == 8)
        #expect(connection.handle(.uniStream(.qpackDecoder)) == .closeConnection(code: 0x103))
        // The first error wins; later events are ignored and new requests rejected.
        #expect(connection.handle(.uniStream(.control)) == .none)
        #expect(connection.handle(.requestStream(streamID: 12)) == .rejectRequest(code: 0x10b))
        #expect(connection.closeCode == 0x103)
    }

    @Test func settingsMustComeFirstAndOnce() {
        var connection = H3Connection()
        #expect(connection.handle(.controlFrame(.maxPushID(1))) == .closeConnection(code: 0x10a))

        connection = H3Connection()
        let settings = H3Settings(maxFieldSectionSize: 100)
        #expect(connection.handle(.controlFrame(.settings(settings))) == .none)
        #expect(connection.peerSettings == settings)
        #expect(connection.handle(.controlFrame(.settings(settings))) == .closeConnection(code: 0x105))
    }

    @Test func pushIDRules() {
        var connection = H3Connection()
        _ = connection.handle(.controlFrame(.settings(H3Settings())))
        #expect(connection.handle(.controlFrame(.cancelPush(pushID: 0))) == .closeConnection(code: 0x108))

        connection = H3Connection()
        _ = connection.handle(.controlFrame(.settings(H3Settings())))
        #expect(connection.handle(.controlFrame(.maxPushID(5))) == .none)
        #expect(connection.handle(.controlFrame(.cancelPush(pushID: 5))) == .none)
        #expect(connection.handle(.controlFrame(.goaway(id: 4))) == .none)
        #expect(connection.handle(.controlFrame(.goaway(id: 4))) == .none)
        #expect(connection.handle(.controlFrame(.maxPushID(4))) == .closeConnection(code: 0x108))

        connection = H3Connection()
        _ = connection.handle(.controlFrame(.settings(H3Settings())))
        _ = connection.handle(.controlFrame(.goaway(id: 4)))
        #expect(connection.handle(.controlFrame(.goaway(id: 5))) == .closeConnection(code: 0x108))
    }

    @Test func criticalStreamsAndPushStreams() {
        var connection = H3Connection()
        #expect(connection.handle(.criticalStreamClosed(.qpackDecoder)) == .closeConnection(code: 0x104))
        connection = H3Connection()
        #expect(connection.handle(.uniStream(.push)) == .closeConnection(code: 0x103))
        connection = H3Connection()
        // A server-initiated bidirectional ID cannot come from the client.
        #expect(connection.handle(.requestStream(streamID: 1)) == .closeConnection(code: 0x103))
        connection = H3Connection()
        #expect(connection.handle(.connectionError(code: 0x201)) == .closeConnection(code: 0x201))
        #expect(connection.isClosing)
    }

    @Test func controlStreamPrefaceEncodesLocalSettings() {
        let connection = H3Connection(configuration: H3Configuration(maxFieldSectionSize: 1000, enableConnectProtocol: true))
        // type 0x00, SETTINGS (0x04) len 9: 0x01=0, 0x06=1000 (2-byte varint 0x43e8), 0x07=0, 0x08=1.
        #expect(connection.controlStreamPreface() == [0x00, 0x04, 0x09, 0x01, 0x00, 0x06, 0x43, 0xe8, 0x07, 0x00, 0x08, 0x01])
    }
}
