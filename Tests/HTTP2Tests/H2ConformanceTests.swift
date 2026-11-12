@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Testing

/// #0061: regressions for h2spec conformance cases. The other h2spec fixes are tested next to
/// the code they touch: H2PrefaceTests (3.5/2) and H2GoawayTests (5.4.1/1).
@Suite(.timeLimit(.minutes(1)))
struct H2ConformanceTests {
    static func id(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }

    /// A connection with stream 1 open (the request not finished) and its whole response sent.
    static func respondedWhileRequestOpen() -> HTTP2Connection {
        var machine = HTTP2Connection()
        _ = machine.handle(.start)
        _ = machine.handle(.settings(HTTP2Settings()))
        #expect(machine.handle(.headers(streamID: id(1), endStream: false, trailers: false))
                == .dispatch(streamID: id(1), endStream: false))
        #expect(machine.handle(.sendHeaders(streamID: id(1), endStream: false)) == .send)
        #expect(machine.handle(.sendData(streamID: id(1), length: 14, endStream: true)) == .sendData(length: 14, endStream: true))
        #expect(machine.handle(.responseFinished(streamID: id(1))) == .none)
        return machine
    }

    // MARK: 6.9.1/3 — WINDOW_UPDATE overflow on a stream whose response is complete

    /// h2spec 6.9.1/3: the request stays open after the response, so the stream is half-closed
    /// (local) and a WINDOW_UPDATE that overflows its window is still a stream
    /// FLOW_CONTROL_ERROR, not ignored on a stream already reset with NO_ERROR.
    @Test func windowOverflowAfterTheResponseIsAStreamError() {
        var machine = Self.respondedWhileRequestOpen()
        #expect(machine.streams.stream(Self.id(1))?.state == .halfClosedLocal)
        #expect(machine.sendWindow(of: Self.id(1)) == 65_535 - 14)
        #expect(machine.respondingStreams == 0)
        #expect(machine.handle(.windowUpdate(streamID: Self.id(1), increment: 0x7fff_ffff))
                == .resetStream(streamID: Self.id(1), .flowControlError, windowIncrement: nil))
        #expect(machine.sendWindow(of: Self.id(1)) == nil)
        // The stream is closed now: more WINDOW_UPDATEs are ignored.
        #expect(machine.handle(.windowUpdate(streamID: Self.id(1), increment: 0x7fff_ffff)) == .none)
    }

    /// A WINDOW_UPDATE that fits is accepted without waking any writer.
    @Test func windowUpdateAfterTheResponseIsAccepted() {
        var machine = Self.respondedWhileRequestOpen()
        #expect(machine.handle(.windowUpdate(streamID: Self.id(1), increment: 100)) == .none)
        #expect(machine.sendWindow(of: Self.id(1)) == 65_535 - 14 + 100)
    }

    /// §8.1: the NO_ERROR reset that stops the upload is sent when the next DATA arrives, and
    /// that DATA is credited to the connection.
    @Test func dataAfterTheResponseIsAnsweredWithNoError() {
        var machine = Self.respondedWhileRequestOpen()
        guard case .resetStream(let id, .noError, _) = machine.handle(
            .data(streamID: Self.id(1), dataLength: 10, flowControlledLength: 10, endStream: false))
        else {
            Issue.record("no NO_ERROR reset")
            return
        }
        #expect(id == Self.id(1))
        #expect(machine.sendWindow(of: Self.id(1)) == nil)
    }

    /// A request that ends after its response closes the stream without a reset.
    @Test func requestEndingAfterTheResponseClosesQuietly() {
        var machine = Self.respondedWhileRequestOpen()
        let action = machine.handle(.data(streamID: Self.id(1), dataLength: 0, flowControlledLength: 0, endStream: true))
        #expect(action == .none)
        #expect(machine.sendWindow(of: Self.id(1)) == nil)
        #expect(machine.handle(.windowUpdate(streamID: Self.id(1), increment: 0x7fff_ffff)) == .none)
    }

    /// Trailers that end the request after the response also close the stream quietly.
    @Test func trailersAfterTheResponseCloseTheStream() {
        var machine = Self.respondedWhileRequestOpen()
        #expect(machine.handle(.headers(streamID: Self.id(1), endStream: true, trailers: true))
                == .acceptTrailers(streamID: Self.id(1)))
        #expect(machine.sendWindow(of: Self.id(1)) == nil)
    }

    /// The same over a connection, in h2spec's order but with the response complete before the
    /// WINDOW_UPDATEs arrive (the race that made 6.9.1/3 flaky over TLS).
    @Test func windowOverflowAfterACompleteResponseOverAConnection() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/"), endStream: false))
            let response = try await client.response(on: 1)
            let resets = response.others.filter { if case .rstStream = $0 { return true }; return false }
            #expect(resets.isEmpty, "\(response.others)")
            try await client.send(F.windowUpdate(1, 0x7fff_ffff), F.windowUpdate(1, 0x7fff_ffff))
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 1, .flowControlError), "\(frames)")
        }
    }
}
