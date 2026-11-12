import HPACK
@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0044: the connection frame loop, the single writer and its queue, and the minimal request
/// path, over in-memory transports.
@Suite(.timeLimit(.minutes(1)))
struct H2ConnectionTests {
    // MARK: Lifecycle

    @Test func handshakeAndCleanClose() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(F.goaway())
        }
        // The server closes when the client does (withH2Connection waits for `run`).
        try await withH2Connection { client in
            try await client.send(F.preface)
        }
    }

    @Test func pingIsAnsweredAndPingAckIgnored() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(F.ping(0xdead_beef, ack: true), F.ping(0x0102_0304_0506_0708))
            let frames = try await client.frames(until: { if case .ping = $0 { return true }; return false })
            #expect(frames.last == .ping(ack: true, 0x0102_0304_0506_0708), "\(frames)")
            #expect(frames.filter { if case .ping = $0 { return true }; return false }.count == 1)
        }
    }

    // MARK: Requests

    @Test func getIsAnswered() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            let block = client.requests.get("/hello?x=1")
            try await client.send(F.headers(1, block: block))
            let response = try await client.response(on: 1)
            #expect(response.head.map(\.0) == [":status", "content-length"])
            #expect(response.head.first?.1 == "200")
            #expect(response.head.last?.1 == "12")
            #expect(String(decoding: response.body, as: UTF8.self) == "hello /hello")
        }
    }

    @Test func headHasNoBody() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/", method: "HEAD")))
            var frames: [H2Frame] = []
            while let frame = try await client.nextFrame() {
                frames.append(frame)
                if case .headers(1, _, _, _) = frame { break }
            }
            guard case .headers(1, let endStream, true, let block)? = frames.last else {
                Issue.record("\(frames)")
                return
            }
            #expect(endStream)
            let fields = try decodeBlock(block, with: &client.decoder)
            #expect(fields.first { $0.0 == "content-length" }?.1 == "7")
        }
    }

    @Test func handlerErrorIsA500AndConnectionSpecificFieldsAreDropped() async throws {
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/fail" { throw TransportError.closed }
            var headers = HTTPFields()
            headers.append(.connection, "keep-alive")
            headers.append(name: "X-Mixed-Case", value: "v")
            return HTTPResponse(status: .noContent, headers: headers)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/fail")))
            #expect(try await client.response(on: 1).head.first?.1 == "500")
            try await client.send(F.headers(3, block: client.requests.get("/ok")))
            let head = try await client.response(on: 3).head
            #expect(head.map(\.0) == [":status", "x-mixed-case"])
            #expect(head.first?.1 == "204")
        }
    }

    @Test func malformedRequestIsAStreamProtocolError() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            let noPath = client.requests.block([(":method", "GET"), (":scheme", "http"), (":authority", "a")])
            try await client.send(F.headers(1, block: noPath))
            #expect(try await client.frames(until: { if case .rstStream = $0 { return true }; return false }).last
                    == .rstStream(stream: 1, .protocolError))
            // The connection carries on.
            try await client.send(F.headers(3, block: client.requests.get("/next")))
            #expect(String(decoding: try await client.response(on: 3).body, as: UTF8.self) == "hello /next")
        }
    }

    /// A body larger than the peer's windows is sent as window allows, resuming on
    /// WINDOW_UPDATE.
    @Test func responseWaitsForFlowControlWindow() async throws {
        let size = 100_000
        let handler = ClosureHandler { _ in
            HTTPResponse(body: .bytes(ByteBuffer(bytes: (0..<size).map { UInt8(truncatingIfNeeded: $0) })))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/big")))
            var received = 0
            var updated = false
            while received < size {
                guard let frame = try await client.nextFrame(timeout: .seconds(5)) else { break }
                guard case .data(1, let bytes, let endStream) = frame else { continue }
                received += bytes.count
                #expect(bytes.count <= 16_384)
                if received == 65_535 && !updated {
                    // The initial windows are used up: nothing more comes until we grant more.
                    updated = true
                    try await client.send(F.windowUpdate(0, 1 << 20), F.windowUpdate(1, 1 << 20))
                }
                if endStream { break }
            }
            #expect(updated)
            #expect(received == size)
        }
    }

    @Test func streamingAndFileBodies() async throws {
        let path = TestIdentity.repositoryRoot + "/Package.swift"
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/file" {
                let file = try OwnedFileDescriptor.openForReading(path: path)
                return HTTPResponse(body: .file(try FileRegion.entireFile(file)))
            }
            return HTTPResponse(body: .stream(length: nil) { writer in
                for chunk in ["one ", "two ", "three"] { try await writer.write(ByteBuffer(bytes: Array(chunk.utf8))) }
            })
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/stream")))
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "one two three")
            try await client.send(F.headers(3, block: client.requests.get("/file")))
            let file = try await client.response(on: 3)
            #expect(file.body.count > 1000)
            #expect(String(decoding: file.body.prefix(25), as: UTF8.self) == "// swift-tools-version: 6")
        }
    }

    /// A body the handler does not read is discarded, but its connection credit comes back
    /// (in one or two WINDOW_UPDATEs, depending on whether the DATA arrived before or after the
    /// handler returned), and a stream still sending when its response ends is reset with
    /// NO_ERROR.
    @Test func requestDataIsCreditedAndUnfinishedStreamsReset() async throws {
        let config = HTTP2Configuration(connectionWindowSize: 65_535)
        try await withH2Connection(configuration: config) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/post", method: "POST"), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 16_000), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 16_000), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 8_000), endStream: false))
            let response = try await client.response(on: 1)
            #expect(String(decoding: response.body, as: UTF8.self) == "hello /post")
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return false })
            var all = response.others + frames
            #expect(all.last == .rstStream(stream: 1, .noError), "\(all)")
            func credited() -> Int {
                all.reduce(0) { if case .windowUpdate(0, let i) = $1 { return $0 + Int(i) }; return $0 }
            }
            // Every byte is credited; the last WINDOW_UPDATE may wait for more pending credit.
            while credited() < 32_000, let frame = try await client.nextFrame(timeout: .seconds(2)) { all.append(frame) }
            #expect(credited() == 40_000 || credited() == 32_000, "\(all)")
        }
    }

    // MARK: Connection errors

    @Test(arguments: [
        ("CONTINUATION without HEADERS", F.raw(type: .continuation, flags: .endHeaders, streamID: 1, payload: []), HTTP2ErrorCode.protocolError),
        ("DATA on stream 0", F.raw(type: .data, streamID: 0, payload: [1]), .protocolError),
        ("DATA on an idle stream", F.data(7, [1]), .protocolError),
        ("invalid HPACK", F.headers(3, block: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), .compressionError),
        ("HEADERS on a closed stream", F.headers(1, block: [0x82]), .streamClosed),
        ("WINDOW_UPDATE 0 on the connection", F.raw(type: .windowUpdate, streamID: 0, payload: [0, 0, 0, 0]), .protocolError),
        ("PING on a stream", F.raw(type: .ping, streamID: 1, payload: Array(repeating: 0, count: 8)), .protocolError),
        ("connection window overflow", F.windowUpdate(0, 0x7fff_ffff), .flowControlError),
    ])
    func protocolErrorsSendGoaway(name: String, frame: ByteBuffer, code: HTTP2ErrorCode) async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")))
            _ = try await client.response(on: 1)
            try await client.send(frame)
            let frames = try await client.framesUntilClosed()
            // Stream 3 was opened by the HEADERS whose block failed to decode.
            let last: UInt32 = code == .compressionError ? 3 : 1
            #expect(frames.last == .goaway(last: last, code, debug: "\(code.name)"), "\(name): \(frames)")
        }
    }

    @Test func frameInsideAHeaderBlockIsAProtocolError() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            let block = client.requests.get("/")
            try await client.send(F.headers(1, block: block, endHeaders: false), F.ping(1))
            let frames = try await client.framesUntilClosed()
            // The block never completed, so stream 1 was never opened.
            #expect(frames.last == .goaway(last: 0, .protocolError, debug: "PROTOCOL_ERROR"), "\(frames)")
        }
    }

    /// A refused stream's block is still decoded, so the next request may index the entry it
    /// added to the dynamic table.
    @Test func refusedStreamKeepsHPACKInStep() async throws {
        let gate = Gate()
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/slow" { await gate.wait() }
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array("ok \(request.headers.contains(.cookie))".utf8))))
        }
        try await withH2Connection(configuration: HTTP2Configuration(maxConcurrentStreams: 1), handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/slow")))
            // Incremental indexing adds `x-token` to the client's table; the server must too.
            var encoder = client.requests
            let refused = encoder.block([(":method", "GET"), (":scheme", "http"), (":authority", "a"), (":path", "/r"),
                                         ("x-token", "abc")])
            try await client.send(F.headers(3, block: refused))
            #expect(try await client.frames(until: { if case .rstStream = $0 { return true }; return false }).last
                    == .rstStream(stream: 3, .refusedStream))
            gate.open()
            #expect(try await client.response(on: 1).head.first?.1 == "200")
            let next = encoder.block([(":method", "GET"), (":scheme", "http"), (":authority", "a"), (":path", "/n"),
                                      ("x-token", "abc")])
            #expect(next.count < refused.count)  // `x-token: abc` is now an index.
            try await client.send(F.headers(5, block: next))
            #expect(String(decoding: try await client.response(on: 5).body, as: UTF8.self) == "ok false")
        }
    }

    // MARK: Writer

    /// Frames queued while a send is in progress go out together in the next send.
    @Test func writerBatchesQueuedFrames() async throws {
        let handled = Atomic<Int>(0)
        let handler = ClosureHandler { _ in
            handled.add(1, ordering: .relaxed)
            return HTTPResponse(body: .bytes(ByteBuffer("x")))
        }
        let counting = Mutex<CountingTransport<InMemoryTransport>?>(nil)
        try await withH2Connection(handler: handler, server: { base in
            let transport = CountingTransport(base)
            counting.withLock { $0 = transport }
            return transport
        }) { client in
            try await client.handshake()
            _ = try await client.frames(until: { $0 == .settingsAck })
            let transport = counting.withLock { $0 }!
            let before = transport.sends
            transport.closeGate()
            // One more send is held at the gate; everything else queues behind it.
            try await client.send(F.ping(1))
            var requests: [ByteBuffer] = []
            for i in 0..<20 { requests.append(F.headers(UInt32(2 * i + 1), block: client.requests.get("/\(i)"))) }
            try await client.send(F.join(requests))
            while handled.load(ordering: .relaxed) < 20 { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(50))
            transport.openGate()
            var frames = 0
            var ended = 0
            while ended < 20, let frame = try await client.nextFrame() {
                frames += 1
                if case .data(_, _, true) = frame { ended += 1 }
            }
            #expect(ended == 20)
            // 20 HEADERS + 20 DATA (+ the PING ACK) in at most three sends: the held one, the
            // batch queued behind it, and possibly one that raced the gate.
            #expect(frames >= 40)
            #expect(transport.sends - before <= 3, "\(transport.sends - before) sends")
        }
    }

    @Test func outboundQueueBatchesAndBounds() {
        var shared = HTTP2SharedState(configuration: HTTP2Configuration(outboundQueueSize: 100))
        var wakeups = HTTP2Wakeups()
        _ = shared.handle(.start, wakeups: &wakeups)
        _ = shared.handle(.settings(HTTP2Settings()), wakeups: &wakeups)
        _ = shared.handle(.ping(ack: false, opaqueData: 1), wakeups: &wakeups)
        _ = shared.handle(.headers(streamID: HTTP2StreamID(1), endStream: true, trailers: false), wakeups: &wakeups)
        let step = shared.sendHeaders(streamID: HTTP2StreamID(1), status: .ok, headers: HTTPFields(), contentLength: nil,
                                      endStream: false, wakeups: &wakeups)
        #expect(step == .sent(length: 0, endStream: false))
        let body = ByteBuffer(bytes: Array(repeating: 9, count: 300))
        #expect(shared.sendData(streamID: HTTP2StreamID(1), bytes: body, endStream: true, wakeups: &wakeups)
                == .sent(length: 300, endStream: true))
        // The ordered lane is past its capacity: stream writers wait for the writer.
        #expect(!shared.outbound.hasSpace)
        guard case .wait(let generation) = shared.sendHeaders(
            streamID: HTTP2StreamID(1), status: .ok, headers: HTTPFields(), contentLength: nil, endStream: true,
            wakeups: &wakeups)
        else {
            Issue.record("did not wait")
            return
        }
        guard case .send(let batch) = shared.nextWriterStep(wakeups: &wakeups) else {
            Issue.record("no batch")
            return
        }
        #expect(shared.generation != generation)
        #expect(shared.outbound.batches == 1)
        let frames = H2FrameReader.frames(in: batch)
        #expect(frames.count == 6, "\(frames)")
        #expect(frames.first == .settings(HTTP2Configuration().localSettings))
        #expect(frames.contains(.ping(ack: true, 1)))
        // The first batch keeps our SETTINGS first; the PING ACK follows the ordered lane.
        #expect(frames.contains(.data(stream: 1, Array(repeating: 9, count: 300), endStream: true)))
        guard case .wait = shared.nextWriterStep(wakeups: &wakeups) else {
            Issue.record("queue not empty")
            return
        }
    }

    /// Reply control frames that pile up unwritten are a flood: GOAWAY(ENHANCE_YOUR_CALM).
    @Test func controlFrameFloodIsEnhanceYourCalm() async throws {
        let counting = Mutex<CountingTransport<InMemoryTransport>?>(nil)
        try await withH2Connection(configuration: HTTP2Configuration(maxQueuedControlFrames: 10), server: { base in
            let transport = CountingTransport(base)
            counting.withLock { $0 = transport }
            return transport
        }) { client in
            try await client.handshake()
            _ = try await client.frames(until: { $0 == .settingsAck })
            let transport = counting.withLock { $0 }!
            transport.closeGate()
            try await client.send(F.ping(0))
            try await Task.sleep(for: .milliseconds(20))
            try await client.send(F.join((1...20).map { F.ping(UInt64($0)) }))
            try await Task.sleep(for: .milliseconds(50))
            transport.openGate()
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 0, .enhanceYourCalm, debug: "ENHANCE_YOUR_CALM"), "\(frames)")
        }
    }

    /// Response heads from many concurrent stream tasks never interleave: every HEADERS
    /// without END_HEADERS is followed directly by its CONTINUATIONs, and the blocks decode in
    /// wire order with one HPACK decoder.
    @Test func headerBlocksNeverInterleave() async throws {
        let streams = 40
        let handler = ClosureHandler { request in
            let path = request.string(of: request.path)
            var headers = HTTPFields()
            for i in 0..<24 {
                // Unique, long values: more than one 16,384-byte frame per block.
                headers.append(name: "x-field-\(i)", value: String(repeating: "\(path)-\(i)-", count: 250))
            }
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...5)))
            return HTTPResponse(headers: headers, body: .bytes(ByteBuffer(bytes: Array(path.utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            var requests: [ByteBuffer] = []
            for i in 0..<streams { requests.append(F.headers(UInt32(2 * i + 1), block: client.requests.get("/s\(i)"))) }
            try await client.send(F.join(requests))
            var open: UInt32?
            var block: [UInt8] = []
            var finished = 0
            var continuations = 0
            while finished < streams, let frame = try await client.nextFrame() {
                switch frame {
                case .headers(let id, _, let endHeaders, let fragment):
                    #expect(open == nil, "HEADERS inside the block of stream \(open ?? 0)")
                    block = fragment
                    open = endHeaders ? nil : id
                    if endHeaders { try check(block, stream: id) }
                case .continuation(let id, let endHeaders, let fragment):
                    #expect(open == id, "CONTINUATION on \(id) inside the block of \(open ?? 0)")
                    continuations += 1
                    block += fragment
                    if endHeaders {
                        open = nil
                        try check(block, stream: id)
                    }
                case .data(_, _, let endStream):
                    #expect(open == nil, "DATA inside a header block")
                    if endStream { finished += 1 }
                default:
                    #expect(open == nil, "\(frame) inside a header block")
                }
            }
            #expect(finished == streams)
            #expect(continuations >= streams)

            func check(_ block: [UInt8], stream: UInt32) throws {
                let fields = try decodeBlock(block, with: &client.decoder)
                let path = "/s\((stream - 1) / 2)"
                #expect(fields.count == 26)
                #expect(fields[1].0 == "x-field-0" && fields[1].1 == String(repeating: "\(path)-0-", count: 250))
                #expect(fields.allSatisfy { $0.0 == ":status" || $0.0 == "content-length" || $0.1.hasPrefix(path) })
            }
        }
    }

    // Graceful shutdown: H2GoawayTests (#0052).
}

/// A one-shot gate handlers can wait on.
final class Gate: Sendable {
    let signal = ShutdownSignal()
    func wait() async { await signal.wait() }
    func open() { signal.trigger() }
}
