import Testing
import HTTP2

private func id(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }

@Suite("HTTP2Stream state machine (RFC 9113 §5.1)")
struct H2StreamStateTests {
    @Test("The expected table covers every state × frame × direction")
    func tableIsComplete() {
        #expect(expectedTransitionRowCount == allStreamStates.count * allStreamFrames.count * 2)
    }

    @Test("Every received frame in every state", arguments: allStreamStates)
    func received(_ state: StreamState) {
        for frame in allStreamFrames {
            var stream = makeStream(state)
            let expected = expectedTransition(state, .received(frame))
            let action = stream.handle(.received(frame))
            #expect(action == expected.action, "\(state) recv \(frame)")
            #expect(stream.state == (expected.next ?? state), "\(state) recv \(frame)")
        }
    }

    @Test("Every sent frame in every state", arguments: allStreamStates)
    func sent(_ state: StreamState) {
        for frame in allStreamFrames {
            var stream = makeStream(state)
            let expected = expectedTransition(state, .sent(frame))
            let action = stream.handle(.sent(frame))
            #expect(action == expected.action, "\(state) send \(frame)")
            #expect(stream.state == (expected.next ?? state), "\(state) send \(frame)")
        }
    }

    @Test("A request with a body and trailers walks open → half-closed (remote) → closed")
    func requestWithTrailers() {
        var stream = HTTP2Stream()
        #expect(stream.handle(.received(.headers(endStream: false))) == .proceed)
        #expect(stream.hasReceivedHeaders)
        #expect(stream.handle(.received(.data(endStream: false))) == .proceed)
        #expect(stream.handle(.received(.headers(endStream: true))) == .proceed)
        #expect(stream.state == .halfClosedRemote)
        #expect(stream.handle(.sent(.headers(endStream: false))) == .proceed)
        #expect(stream.handle(.sent(.data(endStream: true))) == .proceed)
        #expect(stream.state == .closed(.endStream))
        // In flight from the peer after our END_STREAM.
        #expect(stream.handle(.received(.windowUpdate)) == .ignore)
        #expect(stream.handle(.received(.rstStream)) == .ignore)
    }

    @Test("After answering a peer reset with STREAM_CLOSED, further frames are ignored")
    func resetReceivedThenLateData() {
        var stream = makeStream(.closed(.resetReceived))
        #expect(stream.handle(.received(.data(endStream: false))) == .streamError(.streamClosed))
        #expect(stream.state == .closed(.resetSent))
        #expect(stream.handle(.received(.data(endStream: false))) == .ignore)
    }

    @Test("A response racing the peer's reset is dropped, not an error")
    func sendAfterPeerReset() {
        var stream = makeStream(.closed(.resetReceived))
        #expect(stream.handle(.sent(.data(endStream: true))) == .ignore)
        #expect(stream.handle(.sent(.rstStream)) == .ignore)
    }
}

@Suite("HTTP2StreamTable identifier rules")
struct H2StreamTableTests {
    @Test("Client streams open with odd increasing identifiers")
    func increasingIdentifiers() {
        var table = HTTP2StreamTable()
        for value: UInt32 in [1, 3, 9, 11] {
            #expect(table.handle(.received(id(value), .headers(endStream: false))) == .proceed)
        }
        #expect(table.activeCount == 4)
        #expect(table.highestClientStreamID == id(11))
        #expect(table.stream(id(9))?.state == .open)
    }

    @Test("A lower identifier that was never opened is a connection PROTOCOL_ERROR")
    func lowerIdentifier() {
        var table = HTTP2StreamTable()
        #expect(table.handle(.received(id(5), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.received(id(3), .headers(endStream: false))) == .connectionError(.protocolError))
    }

    @Test("Reusing a closed identifier is a connection error")
    func reusedIdentifier() {
        var table = HTTP2StreamTable(configuration: .init(maxConcurrentStreams: 4, recentlyClosedCapacity: 1))
        #expect(table.handle(.received(id(1), .headers(endStream: true))) == .proceed)
        #expect(table.handle(.sent(id(1), .headers(endStream: true))) == .proceed)
        // Still remembered: closed after END_STREAM both ways.
        #expect(table.handle(.received(id(1), .headers(endStream: true))) == .connectionError(.streamClosed))
        // Evict it by closing another stream; now it is a plain reuse.
        #expect(table.handle(.received(id(3), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.sent(id(3), .rstStream)) == .proceed)
        #expect(table.stream(id(1)) == nil)
        #expect(table.handle(.received(id(1), .headers(endStream: true))) == .connectionError(.protocolError))
    }

    @Test("Opening a stream implicitly closes lower idle streams")
    func implicitClose() {
        var table = HTTP2StreamTable()
        #expect(table.handle(.received(id(1), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.received(id(7), .headers(endStream: false))) == .proceed)
        // 3 and 5 were never opened and are now closed.
        #expect(table.stream(id(3)) == nil)
        #expect(table.handle(.received(id(3), .data(endStream: false))) == .streamError(.streamClosed))
        #expect(table.handle(.received(id(3), .data(endStream: false))) == .ignore)  // after our RST
        #expect(table.handle(.received(id(5), .windowUpdate)) == .ignore)
        #expect(table.handle(.received(id(5), .rstStream)) == .ignore)
        #expect(table.handle(.received(id(5), .priority)) == .proceed)
        #expect(table.handle(.received(id(5), .headers(endStream: false))) == .connectionError(.protocolError))
    }

    @Test("Frames other than HEADERS and PRIORITY on an idle stream are a connection PROTOCOL_ERROR",
          arguments: [StreamFrame.data(endStream: false), .data(endStream: true), .rstStream, .windowUpdate])
    func idleFrames(_ frame: StreamFrame) {
        var table = HTTP2StreamTable()
        #expect(table.handle(.received(id(1), frame)) == .connectionError(.protocolError))
    }

    @Test("PRIORITY on an idle stream does not open it or use up its identifier")
    func priorityOnIdle() {
        var table = HTTP2StreamTable()
        #expect(table.handle(.received(id(9), .priority)) == .proceed)
        #expect(table.highestClientStreamID == .connection)
        #expect(table.handle(.received(id(5), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.received(id(9), .headers(endStream: false))) == .proceed)
    }

    @Test("Even streams and stream 0 cannot be opened by a client; PUSH_PROMISE is refused")
    func invalidIdentifiers() {
        var table = HTTP2StreamTable()
        #expect(table.handle(.received(id(2), .headers(endStream: false))) == .connectionError(.protocolError))
        #expect(table.handle(.received(id(4), .data(endStream: false))) == .connectionError(.protocolError))
        #expect(table.handle(.received(id(2), .priority)) == .proceed)
        #expect(table.handle(.received(.connection, .headers(endStream: false))) == .connectionError(.protocolError))
        #expect(table.handle(.received(id(1), .pushPromise)) == .connectionError(.protocolError))
    }

    @Test("A server opens no streams; sending on one is an internal error")
    func serverCannotOpen() {
        var table = HTTP2StreamTable()
        #expect(table.handle(.sent(id(2), .headers(endStream: false))) == .connectionError(.internalError))
        #expect(table.handle(.sent(id(1), .headers(endStream: false))) == .connectionError(.internalError))
        #expect(table.handle(.sent(id(1), .priority)) == .proceed)
    }

    @Test("HEADERS over SETTINGS_MAX_CONCURRENT_STREAMS is refused, and its in-flight frames ignored")
    func concurrencyLimit() {
        var table = HTTP2StreamTable(configuration: .init(maxConcurrentStreams: 2))
        #expect(table.handle(.received(id(1), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.received(id(3), .headers(endStream: true))) == .proceed)
        #expect(table.handle(.received(id(5), .headers(endStream: false))) == .streamError(.refusedStream))
        #expect(table.activeCount == 2)
        #expect(table.highestClientStreamID == id(5))
        #expect(table.handle(.received(id(5), .data(endStream: true))) == .ignore)
        // Finishing stream 3 frees a slot.
        #expect(table.handle(.sent(id(3), .data(endStream: true))) == .proceed)
        #expect(table.activeCount == 1)
        #expect(table.handle(.received(id(7), .headers(endStream: false))) == .proceed)
        #expect(table.activeCount == 2)
    }

    @Test("Frames after this endpoint's RST_STREAM are tolerated until the stream is evicted")
    func closedStreamWindow() {
        var table = HTTP2StreamTable(configuration: .init(maxConcurrentStreams: 8, recentlyClosedCapacity: 2))
        #expect(table.handle(.received(id(1), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.sent(id(1), .rstStream)) == .proceed)
        #expect(table.handle(.received(id(1), .data(endStream: false))) == .ignore)
        #expect(table.handle(.received(id(1), .headers(endStream: true))) == .ignore)
        // Two newer closes push stream 1 out of the window.
        for value: UInt32 in [3, 5] {
            #expect(table.handle(.received(id(value), .headers(endStream: false))) == .proceed)
            #expect(table.handle(.received(id(value), .rstStream)) == .proceed)
        }
        #expect(table.stream(id(1)) == nil)
        #expect(table.stream(id(3))?.state == .closed(.resetReceived))
        #expect(table.handle(.received(id(1), .data(endStream: false))) == .streamError(.streamClosed))
    }

    @Test("Closed-stream bookkeeping stays bounded over many streams")
    func boundedBookkeeping() {
        var table = HTTP2StreamTable(configuration: .init(maxConcurrentStreams: 4, recentlyClosedCapacity: 4))
        var value: UInt32 = 1
        for _ in 0..<5000 {
            #expect(table.handle(.received(id(value), .headers(endStream: true))) == .proceed)
            #expect(table.handle(.sent(id(value), .headers(endStream: true))) == .proceed)
            #expect(table.count <= 8)
            value += 2
        }
        #expect(table.activeCount == 0)
        #expect(table.count == 4)
        // The four newest are remembered, older ones are not.
        #expect(table.stream(id(value - 2))?.state == .closed(.endStream))
        #expect(table.stream(id(value - 8))?.state == .closed(.endStream))
        #expect(table.stream(id(value - 10)) == nil)
    }

    @Test("Identifiers that collide in the hash table are found and removed correctly")
    func collisions() {
        // Identifiers spaced so many share home slots; lookups must survive backward shifts.
        var table = HTTP2StreamTable(configuration: .init(maxConcurrentStreams: 16, recentlyClosedCapacity: 3))
        var open: [UInt32] = []
        var value: UInt32 = 1
        for round in 0..<200 {
            #expect(table.handle(.received(id(value), .headers(endStream: false))) == .proceed)
            open.append(value)
            if open.count > 10 || round % 3 == 0 {
                let victim = open.remove(at: (round * 7) % open.count)
                #expect(table.handle(.sent(id(victim), .rstStream)) == .proceed)
            }
            for live in open { #expect(table.stream(id(live))?.state == .open) }
            value += 2 * 64 + 2 * UInt32(round % 2)
        }
    }

    @Test("GOAWAY bounds the streams that are processed, and can only be lowered")
    func goaway() {
        var table = HTTP2StreamTable()
        #expect(table.handle(.received(id(1), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.received(id(3), .headers(endStream: false))) == .proceed)
        #expect(table.handle(.goawaySent(lastStreamID: id(3))) == .proceed)
        #expect(table.goawayLastStreamID == id(3))
        #expect(table.handle(.received(id(5), .headers(endStream: false))) == .ignore)
        #expect(table.handle(.received(id(5), .data(endStream: true))) == .ignore)
        #expect(table.handle(.received(id(3), .data(endStream: true))) == .proceed)
        // Lowering closes stream 3; raising again is not allowed.
        #expect(table.handle(.goawaySent(lastStreamID: id(1))) == .proceed)
        #expect(table.handle(.goawaySent(lastStreamID: id(7))) == .proceed)
        #expect(table.goawayLastStreamID == id(1))
        #expect(table.stream(id(3))?.state == .closed(.resetSent))
        #expect(table.activeCount == 1)
        #expect(table.handle(.received(id(3), .windowUpdate)) == .ignore)
        #expect(table.handle(.received(id(1), .data(endStream: true))) == .proceed)
    }

    @Test("Seeded random frame sequences match the reference model", arguments: 0..<64)
    func randomSequences(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let maxConcurrent = [0, 1, 2, 4][Int(seed % 4)]
        let recentlyClosed = [1, 3, 8][Int(seed / 4 % 3)]
        var table = HTTP2StreamTable(
            configuration: .init(maxConcurrentStreams: maxConcurrent, recentlyClosedCapacity: recentlyClosed))
        var model = StreamTableModel(maxConcurrent: maxConcurrent, recentlyClosed: recentlyClosed)

        var connectionErrors = 0
        for step in 0..<400 {
            let event = randomEvent(&rng, model: model)
            // A connection error ends the connection. Both are values, so roll back and keep
            // exploring from the state before the bad frame.
            let (savedTable, savedModel) = (table, model)
            let expected = model.handle(event)
            let actual = table.handle(event)
            #expect(actual == expected, "seed \(seed) step \(step): \(event)")
            if actual != expected { return }
            if case .connectionError = actual {
                connectionErrors += 1
                (table, model) = (savedTable, savedModel)
            }
            #expect(table.activeCount == model.active, "seed \(seed) step \(step)")
            for (key, state) in model.streams {
                #expect(table.stream(id(key))?.state == state, "seed \(seed) step \(step) stream \(key)")
            }
            #expect(table.count == model.streams.count, "seed \(seed) step \(step)")
        }
        #expect(connectionErrors < 400)
        #expect(model.highest > 20, "seed \(seed) explored few streams")
    }

    private func randomEvent(_ rng: inout SplitMix64, model: StreamTableModel) -> HTTP2StreamTable.Event {
        let roll = Int.random(in: 0..<100, using: &rng)
        if roll < 2 {
            return .goawaySent(lastStreamID: id(UInt32.random(in: 0...(model.highest + 4), using: &rng)))
        }
        let frames: [StreamFrame] = [
            .headers(endStream: false), .headers(endStream: true), .headers(endStream: true),
            .data(endStream: false), .data(endStream: false), .data(endStream: true),
            .priority, .rstStream, .windowUpdate, .pushPromise,
        ]
        var frame = frames.randomElement(using: &rng)!
        let known = Array(model.streams.keys).sorted()

        // Sent frames mostly go to streams the server knows; a rare one opens a stream, which
        // a server must not do.
        if roll < 40, let target = known.randomElement(using: &rng) {
            if frame == .pushPromise { frame = .data(endStream: true) }
            let streamID = Int.random(in: 0..<50, using: &rng) == 0 ? model.highest + 2 : target
            return .sent(id(streamID), frame)
        }

        // Mostly streams near the frontier, sometimes old, even, or zero ones.
        let streamID: UInt32
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<45:
            streamID = model.highest + 2 * UInt32.random(in: 1...2, using: &rng) - (model.highest & 1 == 0 ? 1 : 0)
        case 45..<85: streamID = known.randomElement(using: &rng) ?? 1
        case 85..<95: streamID = UInt32.random(in: 0...(model.highest + 2), using: &rng) | 1
        case 95..<98: streamID = 2 * UInt32.random(in: 1...4, using: &rng)
        default: streamID = 0
        }
        if frame == .pushPromise && Int.random(in: 0..<4, using: &rng) != 0 { frame = .headers(endStream: false) }
        return .received(id(streamID), frame)
    }
}
