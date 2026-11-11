import Testing
import HTTP2

@Suite struct HTTP2ErrorCodeTests {
    @Test func wireValuesMatchRFC9113() {
        let expected: [(HTTP2ErrorCode, UInt32, String)] = [
            (.noError, 0x0, "NO_ERROR"),
            (.protocolError, 0x1, "PROTOCOL_ERROR"),
            (.internalError, 0x2, "INTERNAL_ERROR"),
            (.flowControlError, 0x3, "FLOW_CONTROL_ERROR"),
            (.settingsTimeout, 0x4, "SETTINGS_TIMEOUT"),
            (.streamClosed, 0x5, "STREAM_CLOSED"),
            (.frameSizeError, 0x6, "FRAME_SIZE_ERROR"),
            (.refusedStream, 0x7, "REFUSED_STREAM"),
            (.cancel, 0x8, "CANCEL"),
            (.compressionError, 0x9, "COMPRESSION_ERROR"),
            (.connectError, 0xa, "CONNECT_ERROR"),
            (.enhanceYourCalm, 0xb, "ENHANCE_YOUR_CALM"),
            (.inadequateSecurity, 0xc, "INADEQUATE_SECURITY"),
            (.http11Required, 0xd, "HTTP_1_1_REQUIRED"),
        ]
        #expect(HTTP2ErrorCode.allDefined.count == 14)
        for (index, (code, raw, name)) in expected.enumerated() {
            #expect(code.rawValue == raw)
            #expect("\(code.name)" == name)
            #expect(code.description == name)
            #expect(code.isDefined)
            #expect(HTTP2ErrorCode.allDefined[index] == code)
            #expect(HTTP2ErrorCode(rawValue: raw) == code)
        }
    }

    @Test func unknownCodesArePreserved() {
        let code = HTTP2ErrorCode(rawValue: 0xdead_beef)
        #expect(code.rawValue == 0xdead_beef)
        #expect(!code.isDefined)
        #expect("\(code.name)" == "UNKNOWN")
        #expect(code.description == "UNKNOWN(0xdeadbeef)")
        #expect(code != .internalError)
        #expect(!HTTP2ErrorCode(rawValue: 0xe).isDefined)
    }
}

@Suite struct HTTP2ErrorTests {
    @Test func connectionError() {
        let error = HTTP2Error.connection(.frameSizeError, reason: "PING length 7")
        #expect(error.code == .frameSizeError)
        #expect(error.streamID == nil)
        #expect(error.isConnectionError)
        #expect(error.reason == "PING length 7")
        #expect(error.description == "connection error FRAME_SIZE_ERROR: PING length 7")
    }

    @Test func streamError() {
        let error = HTTP2Error.stream(HTTP2StreamID(3), .refusedStream, reason: "over limit")
        #expect(error.code == .refusedStream)
        #expect(error.streamID == HTTP2StreamID(3))
        #expect(!error.isConnectionError)
        #expect(error.description == "stream 3 error REFUSED_STREAM: over limit")
    }

    @Test func streamZeroEscalatesToConnectionError() {
        #expect(HTTP2Error.onStream(.connection, .protocolError, reason: "x") == .connection(.protocolError, reason: "x"))
        #expect(HTTP2Error.onStream(HTTP2StreamID(5), .cancel, reason: "x") == .stream(HTTP2StreamID(5), .cancel, reason: "x"))
    }

    @Test func goawayDebugDataNeverCarriesTheReason() {
        let error = HTTP2Error.connection(.protocolError, reason: "internal parser state 0x7f3a at /Users/x")
        #expect("\(error.goawayDebugData)" == "PROTOCOL_ERROR")
        let unknown = HTTP2Error.connection(HTTP2ErrorCode(rawValue: 0x99), reason: "secret")
        #expect("\(unknown.goawayDebugData)" == "UNKNOWN")
    }
}

@Suite struct HTTP2StreamIDTests {
    @Test func rangeAndParity() {
        #expect(HTTP2StreamID(rawValue: 0x8000_0000) == nil)
        #expect(HTTP2StreamID(rawValue: 0x7fff_ffff)?.rawValue == HTTP2StreamID.maxValue)
        #expect(HTTP2StreamID(wireValue: 0x8000_0005) == HTTP2StreamID(5))
        #expect(HTTP2StreamID.connection.isConnection)
        #expect(!HTTP2StreamID.connection.isServerInitiated && !HTTP2StreamID.connection.isClientInitiated)
        #expect(HTTP2StreamID(1).isClientInitiated && !HTTP2StreamID(1).isServerInitiated)
        #expect(HTTP2StreamID(2).isServerInitiated && !HTTP2StreamID(2).isClientInitiated)
        #expect(HTTP2StreamID(1) < HTTP2StreamID(2))
    }
}
