import HTTPCore
import Testing
@testable import WebSockets

/// Feeds `bytes` to a connection state machine in one piece and collects every action.
func actions(_ connection: inout WSConnection, _ bytes: [UInt8]) -> [WSConnection.Action] {
    var input = ByteBuffer(bytes: bytes)
    var result: [WSConnection.Action] = []
    while true {
        let action = connection.process(&input)
        if action == .needMoreBytes { return result }
        result.append(action)
    }
}

/// Feeds `bytes` split at the given chunk size.
func actions(_ connection: inout WSConnection, _ bytes: [UInt8], chunk: Int) -> [WSConnection.Action] {
    var input = ByteBuffer()
    var result: [WSConnection.Action] = []
    var offset = 0
    while offset < bytes.count {
        let end = min(offset + chunk, bytes.count)
        input.append(contentsOf: bytes[offset..<end])
        offset = end
        while true {
            let action = connection.process(&input)
            if action == .needMoreBytes { break }
            result.append(action)
        }
        input.discardReadBytes()
    }
    return result
}

@Suite struct WSConnectionTests {
    func failure(_ code: WebSocketCloseCode) -> WSConnection.Action {
        .sendClose(code: code, reason: "", thenCloseTransport: true)
    }

    // MARK: Messages

    @Test func singleFrameMessages() {
        var connection = WSConnection()
        let bytes = clientFrame(.text, "hello") + clientFrame(.binary, [1, 2, 3])
        #expect(actions(&connection, bytes) == [
            .deliver(.text("hello")), .deliver(.binary(ByteBuffer(bytes: [1, 2, 3]))),
        ])
        #expect(connection.state == .open)
    }

    @Test func emptyMessages() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.text, []) + clientFrame(.binary, [])) == [
            .deliver(.text("")), .deliver(.binary(ByteBuffer())),
        ])
    }

    @Test func fragmentedTextWithAMultibyteCharacterSplitAcrossFrames() {
        // "aé😀b": é is C3 A9, 😀 is F0 9F 98 80. Split inside both characters.
        let text = Array("aé😀b".utf8)
        for first in 1..<text.count {
            for second in first..<text.count {
                var connection = WSConnection()
                let bytes = clientFrame(.text, Array(text[..<first]), fin: false)
                    + clientFrame(.continuation, Array(text[first..<second]), fin: false)
                    + clientFrame(.continuation, Array(text[second...]), fin: true)
                #expect(actions(&connection, bytes) == [.deliver(.text("aé😀b"))], "split \(first), \(second)")
            }
        }
    }

    @Test func messagesSurviveEverySplitOfTheStream() {
        let stream = clientFrame(.text, Array("κόσ".utf8.prefix(3)), fin: false)
            + clientFrame(.ping, Array("p1".utf8))
            + clientFrame(.continuation, Array("κόσμε".utf8.dropFirst(3)), fin: true)
            + clientFrame(.binary, Array(repeating: 9, count: 200))
        var whole = WSConnection()
        let expected = actions(&whole, stream)
        #expect(expected == [
            .sendPong(ByteBuffer(bytes: Array("p1".utf8))),
            .deliver(.text("κόσμε")),
            .deliver(.binary(ByteBuffer(bytes: Array(repeating: 9, count: 200)))),
        ])
        for chunk in 1...stream.count {
            var connection = WSConnection()
            #expect(actions(&connection, stream, chunk: chunk) == expected, "chunk \(chunk)")
        }
    }

    @Test func invalidUTF8FailsWith1007BeforeTheMessageEnds() {
        var connection = WSConnection()
        // The first fragment holds a surrogate; the message never finishes.
        let bytes = clientFrame(.text, [0x61, 0xED, 0xA0, 0x80], fin: false)
        #expect(actions(&connection, bytes) == [failure(.invalidFramePayloadData)])
        #expect(connection.state == .closed)
        #expect(connection.failure == .invalidFramePayloadData)
    }

    @Test func invalidUTF8SplitAcrossFragments() {
        var connection = WSConnection()
        // F0 9F in one fragment and 41 (not a continuation) in the next.
        let bytes = clientFrame(.text, [0xF0, 0x9F], fin: false) + clientFrame(.continuation, [0x41], fin: true)
        #expect(actions(&connection, bytes) == [failure(.invalidFramePayloadData)])
    }

    @Test func textEndingInsideACodePointIs1007() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.text, [0x61, 0xE2, 0x82])) == [failure(.invalidFramePayloadData)])
    }

    @Test func binaryIsNotValidated() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.binary, [0xFF, 0xED, 0xA0, 0x80])) == [
            .deliver(.binary(ByteBuffer(bytes: [0xFF, 0xED, 0xA0, 0x80]))),
        ])
    }

    @Test func oversizedMessageFailsWith1009() {
        var connection = WSConnection(configuration: .init(maxFrameSize: 1000, maxMessageSize: 1500))
        let bytes = clientFrame(.binary, Array(repeating: 1, count: 1000), fin: false)
            + clientFrame(.continuation, Array(repeating: 1, count: 501), fin: true)
        #expect(actions(&connection, bytes) == [failure(.messageTooBig)])

        var exact = WSConnection(configuration: .init(maxFrameSize: 1000, maxMessageSize: 1500))
        let fits = clientFrame(.binary, Array(repeating: 1, count: 1000), fin: false)
            + clientFrame(.continuation, Array(repeating: 1, count: 500), fin: true)
        #expect(actions(&exact, fits) == [.deliver(.binary(ByteBuffer(bytes: Array(repeating: 1, count: 1500))))])
    }

    @Test func oversizedFrameFailsWith1009() {
        var connection = WSConnection(configuration: .init(maxFrameSize: 200))
        #expect(actions(&connection, clientFrame(.binary, Array(repeating: 1, count: 201))) == [failure(.messageTooBig)])
    }

    @Test func continuationWithoutAStartIs1002() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.continuation, "x")) == [failure(.protocolError)])
    }

    @Test func newDataFrameInsideAFragmentedMessageIs1002() {
        var connection = WSConnection()
        let bytes = clientFrame(.text, "a", fin: false) + clientFrame(.binary, [1])
        #expect(actions(&connection, bytes) == [failure(.protocolError)])
    }

    @Test(arguments: [
        [0x81, 0x01, 0x41] as [UInt8],                 // unmasked
        [0xC1, 0x80, 0, 0, 0, 0],                       // RSV1
        [0x83, 0x80, 0, 0, 0, 0],                       // reserved opcode
        [0x09, 0x80, 0, 0, 0, 0],                       // fragmented ping
    ])
    func frameViolationsFailWith1002(bytes: [UInt8]) {
        var connection = WSConnection()
        #expect(actions(&connection, bytes) == [failure(.protocolError)])
        #expect(connection.failure == .protocolError)
    }

    // MARK: Ping and pong

    @Test func pingsInterleavedWithFragmentsAreAnsweredInOrder() {
        var connection = WSConnection()
        let bytes = clientFrame(.binary, [1], fin: false)
            + clientFrame(.ping, Array("a".utf8))
            + clientFrame(.continuation, [2], fin: false)
            + clientFrame(.pong, Array("unsolicited".utf8))
            + clientFrame(.ping, Array("b".utf8))
            + clientFrame(.continuation, [3], fin: true)
        #expect(actions(&connection, bytes) == [
            .sendPong(ByteBuffer(bytes: Array("a".utf8))),
            .receivedPong(ByteBuffer(bytes: Array("unsolicited".utf8))),
            .sendPong(ByteBuffer(bytes: Array("b".utf8))),
            .deliver(.binary(ByteBuffer(bytes: [1, 2, 3]))),
        ])
    }

    @Test func pingWith125BytePayloadIsEchoed() {
        var connection = WSConnection()
        let payload = Array(repeating: UInt8(0x5A), count: 125)
        #expect(actions(&connection, clientFrame(.ping, payload)) == [.sendPong(ByteBuffer(bytes: payload))])
    }

    // MARK: Close handshake

    @Test func peerInitiatedCloseIsEchoed() {
        var connection = WSConnection()
        let bytes = clientFrame(.close, closePayload(1001, Array("going".utf8)))
        #expect(actions(&connection, bytes) == [.sendClose(code: .goingAway, reason: "", thenCloseTransport: true)])
        #expect(connection.state == .closed)
        #expect(connection.receivedCloseCode == .goingAway)
        #expect(connection.receivedCloseReason == "going")
        // Nothing after the close is processed.
        #expect(actions(&connection, clientFrame(.text, "late")) == [])
    }

    @Test func emptyCloseIsEchoedEmpty() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.close, [])) == [.sendClose(code: nil, reason: "", thenCloseTransport: true)])
        #expect(connection.receivedCloseCode == .noStatusReceived)
    }

    @Test func serverInitiatedCloseWaitsForThePeer() {
        var connection = WSConnection()
        #expect(connection.handle(.closeRequested(.goingAway, reason: "bye"))
                == .sendClose(code: .goingAway, reason: "bye", thenCloseTransport: false))
        #expect(connection.state == .closing)
        // A second close does nothing.
        #expect(connection.handle(.closeRequested(.normalClosure, reason: "")) == .none)
        // Data and pings that cross our Close are discarded; the peer's Close finishes.
        let bytes = clientFrame(.text, "in flight") + clientFrame(.ping, [1])
            + clientFrame(.close, closePayload(1001))
        #expect(actions(&connection, bytes) == [.closeTransport(.normal)])
        #expect(connection.state == .closed)
        #expect(connection.receivedCloseCode == .goingAway)
        #expect(connection.sentCloseCode == .goingAway)
    }

    @Test func closeTimeoutAndEndOfStream() {
        var closing = WSConnection()
        _ = closing.handle(.closeRequested(.normalClosure, reason: ""))
        #expect(closing.handle(.closeTimedOut) == .closeTransport(.timeout))
        #expect(closing.receivedCloseCode == .abnormalClosure)

        var open = WSConnection()
        #expect(open.handle(.endOfStream) == .closeTransport(.normal))
        #expect(open.receivedCloseCode == .abnormalClosure)
        #expect(open.handle(.endOfStream) == .none)
    }

    @Test(arguments: [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 3000, 3999, 4000, 4999] as [UInt16])
    func validCloseCodesAreEchoed(code: UInt16) {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.close, closePayload(code)))
                == [.sendClose(code: WebSocketCloseCode(rawValue: code), reason: "", thenCloseTransport: true)])
    }

    @Test(arguments: [0, 999, 1004, 1005, 1006, 1015, 1016, 1100, 2000, 2999, 5000, 65535] as [UInt16])
    func invalidCloseCodesAre1002(code: UInt16) {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.close, closePayload(code))) == [failure(.protocolError)])
    }

    @Test func oneByteCloseIs1002() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.close, [0x03])) == [failure(.protocolError)])
    }

    @Test func closeReasonMustBeUTF8() {
        var connection = WSConnection()
        #expect(actions(&connection, clientFrame(.close, closePayload(1000, [0xCE, 0xBA, 0xFF])))
                == [failure(.invalidFramePayloadData)])
        var valid = WSConnection()
        #expect(actions(&valid, clientFrame(.close, closePayload(1000, Array("κόσμε".utf8))))
                == [.sendClose(code: .normalClosure, reason: "", thenCloseTransport: true)])
    }

    @Test func violationWhileClosingClosesTheTransport() {
        var connection = WSConnection()
        _ = connection.handle(.closeRequested(.normalClosure, reason: ""))
        #expect(actions(&connection, [0x81, 0x01, 0x41]) == [.closeTransport(.protocolError)])
    }

    @Test func closeCodeValidity() {
        #expect(WebSocketCloseCode.normalClosure.isValidOnTheWire)
        #expect(!WebSocketCloseCode.noStatusReceived.isValidOnTheWire)
        #expect(!WebSocketCloseCode.abnormalClosure.isValidOnTheWire)
        #expect(!WebSocketCloseCode.tlsHandshake.isValidOnTheWire)
        #expect(!WebSocketCloseCode(rawValue: 1004).isValidOnTheWire)
        #expect(WebSocketCloseCode(rawValue: 4999).isValidOnTheWire)
        #expect(!WebSocketCloseCode(rawValue: 5000).isValidOnTheWire)
    }
}
