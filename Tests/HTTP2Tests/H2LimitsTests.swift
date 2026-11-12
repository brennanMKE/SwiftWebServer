@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0055: MAX_CONCURRENT_STREAMS, header list size limits (ours and the peer's), the request
/// body size limit, and no RST_STREAM on idle streams.
@Suite(.timeLimit(.minutes(1)))
struct H2LimitsTests {
    /// Counts handler calls and waits for `gate` before answering `ok <path>`.
    final class Calls: Sendable {
        let count = Atomic<Int>(0)
        let gate = Gate()

        func handler(gated: Bool = false) -> ClosureHandler {
            ClosureHandler { [self] request in
                count.add(1, ordering: .relaxed)
                if gated { await gate.wait() }
                return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array("ok \(request.string(of: request.path))".utf8))))
            }
        }
    }

    static func status(_ head: [(String, String)]) -> String? { head.first { $0.0 == ":status" }?.1 }

    // MARK: MAX_CONCURRENT_STREAMS

    /// Stream 101 of 100 is refused while the first 100 complete, and its header block is still
    /// decoded, so a later request that refers to its HPACK entries works.
    @Test func streamOverTheConcurrencyLimitIsRefused() async throws {
        let calls = Calls()
        try await withH2Connection(handler: calls.handler(gated: true)) { client in
            try await client.handshake()
            for i in 0..<100 {
                try await client.send(F.headers(UInt32(2 * i + 1), block: client.requests.get("/\(i)")))
            }
            let refused = UInt32(201)
            try await client.send(F.headers(refused, block: client.requests.get("/refused", extra: [("x-refused", "yes")])))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: refused, .refusedStream), "\(seen)")

            calls.gate.open()
            var completed = 0
            var block: [UInt32: [UInt8]] = [:]
            while completed < 100, let frame = try await client.nextFrame() {
                switch frame {
                case .headers(let stream, _, _, let fragment):
                    block[stream] = fragment
                    _ = try decodeBlock(fragment, with: &client.decoder)
                case .data(let stream, let bytes, true):
                    #expect(String(decoding: bytes, as: UTF8.self) == "ok /\((stream - 1) / 2)")
                    completed += 1
                default:
                    break
                }
            }
            #expect(completed == 100)
            #expect(calls.count.load(ordering: .relaxed) == 100)
            // Refers to the dynamic-table entries the refused block added.
            try await client.send(F.headers(203, block: client.requests.get("/after", extra: [("x-refused", "yes")])))
            let response = try await client.response(on: 203)
            #expect(String(decoding: response.body, as: UTF8.self) == "ok /after")
        }
    }

    // MARK: Header list size

    /// A request head over SETTINGS_MAX_HEADER_LIST_SIZE is answered 431 without the handler,
    /// and the connection carries on.
    @Test func oversizedHeaderListIs431() async throws {
        let calls = Calls()
        let config = HTTP2Configuration(maxHeaderListSize: 1_000)
        try await withH2Connection(configuration: config, handler: calls.handler()) { client in
            try await client.handshake()
            let big = String(repeating: "v", count: 1_200)
            try await client.send(F.headers(1, block: client.requests.get("/big", extra: [("x-big", big)])))
            let response = try await client.response(on: 1)
            #expect(Self.status(response.head) == "431")
            #expect(calls.count.load(ordering: .relaxed) == 0)
            try await client.send(F.headers(3, block: client.requests.get("/small")))
            #expect(String(decoding: try await client.response(on: 3).body, as: UTF8.self) == "ok /small")
        }
    }

    /// A body on a 431 stream is credited and the stream reset with NO_ERROR after the answer.
    @Test func oversizedHeaderListWithABodyIsAnsweredAndReset() async throws {
        let config = HTTP2Configuration(maxHeaderListSize: 1_000)
        try await withH2Connection(configuration: config, handler: Calls().handler()) { client in
            try await client.handshake()
            let big = String(repeating: "v", count: 1_200)
            try await client.send(F.headers(1, block: client.requests.get("/big", method: "POST", extra: [("x-big", big)]),
                                            endStream: false))
            let response = try await client.response(on: 1)
            #expect(Self.status(response.head) == "431")
            // The reset waits for the body's next DATA (#0061).
            try await client.send(F.data(1, Array(repeating: 1, count: 100), endStream: false))
            let after = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(after.last == .rstStream(stream: 1, .noError), "\(after)")
        }
    }

    /// A field that is malformed before the limit is crossed makes the stream a PROTOCOL_ERROR.
    @Test func malformedOversizedHeaderListIsReset() async throws {
        let config = HTTP2Configuration(maxHeaderListSize: 1_000)
        try await withH2Connection(configuration: config, handler: Calls().handler()) { client in
            try await client.handshake()
            let big = String(repeating: "v", count: 1_200)
            try await client.send(F.headers(1, block: client.requests.get("/big", extra: [("Bad-Name", "x"), ("x-big", big)])))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: 1, .protocolError), "\(seen)")
        }
    }

    /// Past the hard limit (twice the advertised size) the block is not decoded: the
    /// connection closes.
    @Test func headerBlockPastTheHardLimitClosesTheConnection() async throws {
        let config = HTTP2Configuration(maxHeaderListSize: 1_000)
        try await withH2Connection(configuration: config, handler: Calls().handler()) { client in
            try await client.handshake()
            let huge = (0..<5_000).map { _ in "~" }.joined()
            try await client.send(F.headers(1, block: client.requests.get("/huge", extra: [("x-huge", huge)])))
            let seen = try await client.frames(until: \.isGoaway)
            guard case .goaway(_, let code, _) = seen.last else {
                Issue.record("no GOAWAY: \(seen)")
                return
            }
            #expect(code == .enhanceYourCalm)
        }
    }

    @Test func oversizedTrailersAreAStreamProtocolError() async throws {
        let config = HTTP2Configuration(maxHeaderListSize: 1_000)
        try await withH2Connection(configuration: config, handler: H2RequestBodyTests.echo()) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false),
                                  F.data(1, [1, 2, 3], endStream: false))
            let trailers = client.requests.block([("x-trailer", String(repeating: "t", count: 1_200))])
            try await client.send(F.headers(1, block: trailers, endStream: true))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: 1, .protocolError), "\(seen)")
        }
    }

    /// A response head larger than the peer's SETTINGS_MAX_HEADER_LIST_SIZE becomes a bare 500
    /// that ends the stream; the body is not sent.
    @Test func responseHeadOverThePeersLimitIsABare500() async throws {
        let handler = ClosureHandler { request in
            var headers = HTTPFields()
            if request.string(of: request.path) == "/big" { headers.append(name: "x-big", value: String(repeating: "b", count: 300)) }
            return HTTPResponse(status: .ok, headers: headers, body: .bytes(ByteBuffer(bytes: Array("hello".utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake(HTTP2Settings(maxHeaderListSize: 200))
            try await client.send(F.headers(1, block: client.requests.get("/big")))
            var frames: [H2Frame] = []
            while let frame = try await client.nextFrame() {
                if case .headers(1, _, _, _) = frame { frames.append(frame) }
                if case .data(1, _, _) = frame { frames.append(frame) }
                if case .headers(1, true, _, _) = frame { break }
                if case .data(1, _, true) = frame { break }
            }
            guard case .headers(1, true, true, let fragment) = frames.first, frames.count == 1 else {
                Issue.record("\(frames)")
                return
            }
            #expect(try decodeBlock(fragment, with: &client.decoder).map(\.0) == [":status"])
            // A head within the limit is sent as is.
            try await client.send(F.headers(3, block: client.requests.get("/small")))
            let small = try await client.response(on: 3)
            #expect(Self.status(small.head) == "200")
            #expect(String(decoding: small.body, as: UTF8.self) == "hello")
        }
    }

    @Test func responseHeadListSizeCountsWhatIsSent() {
        var headers = HTTPFields()
        headers.append(name: "X-A", value: "12345")
        headers.append(name: "Connection", value: "close")
        // :status (7 + 3 + 32), x-a (3 + 5 + 32), content-length (14 + 2 + 32); no connection.
        #expect(HTTP2ResponseHeadEncoder.listSize(status: .ok, headers: headers, contentLength: 42) == 42 + 40 + 48)
    }

    // MARK: Request body size

    @Test func declaredBodyOverTheLimitIs413WithoutTheHandler() async throws {
        let calls = Calls()
        let config = HTTP2Configuration(maxRequestBodySize: 1_000)
        try await withH2Connection(configuration: config, handler: calls.handler()) { client in
            try await client.handshake()
            let block = client.requests.get("/up", method: "POST", extra: [("content-length", "2000")])
            try await client.send(F.headers(1, block: block, endStream: false))
            let response = try await client.response(on: 1)
            #expect(Self.status(response.head) == "413")
            #expect(calls.count.load(ordering: .relaxed) == 0)
        }
    }

    @Test func undeclaredBodyGrowingPastTheLimitIs413() async throws {
        let config = HTTP2Configuration(maxRequestBodySize: 1_000)
        try await withH2Connection(configuration: config, handler: H2RequestBodyTests.echo()) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/up", method: "POST"), endStream: false))
            _ = try await client.sendBody(H2RequestBodyTests.pattern(1_500), on: 1, frameSize: 500)
            let response = try await client.response(on: 1)
            #expect(Self.status(response.head) == "413")
            // Within the limit, the same handler echoes.
            try await client.send(F.headers(3, block: client.requests.get("/up", method: "POST"), endStream: false))
            _ = try await client.sendBody(H2RequestBodyTests.pattern(1_000), on: 3)
            let ok = try await client.response(on: 3)
            #expect(String(decoding: ok.body, as: UTF8.self) == "1000 \(H2RequestBodyTests.checksum(H2RequestBodyTests.pattern(1_000)))")
        }
    }

    // MARK: Idle streams

    /// RST_STREAM must not be sent on an idle stream (§6.4): a stream error there is a
    /// connection error.
    @Test func streamErrorOnAnIdleStreamIsAConnectionError() async throws {
        var machine = HTTP2Connection()
        _ = machine.handle(.start)
        _ = machine.handle(.settings(HTTP2Settings()))
        let error = HTTP2Error.stream(HTTP2StreamID(5), .protocolError, reason: "depends on itself")
        guard case .goaway(_, let goaway) = machine.handle(.streamError(error)) else {
            Issue.record("no GOAWAY")
            return
        }
        #expect(goaway.code == .protocolError)

        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(F.raw(type: .priority, streamID: 3, payload: [0, 0, 0, 3, 16]))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            guard case .goaway(_, .protocolError, _) = seen.last else {
                Issue.record("\(seen)")
                return
            }
        }
    }
}
