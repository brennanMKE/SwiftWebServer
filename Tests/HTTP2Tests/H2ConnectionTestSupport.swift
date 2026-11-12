import HPACK
@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

// Support for driving `HTTP2` connections over in-memory transports (#0042–#0044).

/// A frame as the test client sees it, with payloads copied out.
enum H2Frame: Equatable, CustomStringConvertible {
    case settings(HTTP2Settings)
    case settingsAck
    case windowUpdate(stream: UInt32, UInt32)
    case ping(ack: Bool, UInt64)
    case goaway(last: UInt32, HTTP2ErrorCode, debug: String)
    case rstStream(stream: UInt32, HTTP2ErrorCode)
    case headers(stream: UInt32, endStream: Bool, endHeaders: Bool, [UInt8])
    case continuation(stream: UInt32, endHeaders: Bool, [UInt8])
    /// A whole DATA frame.
    case data(stream: UInt32, [UInt8], endStream: Bool)
    case other(String)

    var description: String {
        switch self {
        case .settings(let s): "SETTINGS(\(s))"
        case .settingsAck: "SETTINGS ACK"
        case .windowUpdate(let s, let i): "WINDOW_UPDATE(\(s), +\(i))"
        case .ping(let ack, let d): "PING(ack: \(ack), \(d))"
        case .goaway(let l, let c, let d): "GOAWAY(\(l), \(c), \(d))"
        case .rstStream(let s, let c): "RST_STREAM(\(s), \(c))"
        case .headers(let s, let es, let eh, let b): "HEADERS(\(s), es: \(es), eh: \(eh), \(b.count) bytes)"
        case .continuation(let s, let eh, let b): "CONTINUATION(\(s), eh: \(eh), \(b.count) bytes)"
        case .data(let s, let b, let es): "DATA(\(s), \(b.count) bytes, es: \(es))"
        case .other(let s): s
        }
    }

    var isGoaway: Bool {
        if case .goaway = self { return true }
        return false
    }
}

/// Parses a server's output into ``H2Frame``s (client role). Partial input is kept.
struct H2FrameReader {
    var parser = HTTP2FrameParser(configuration: .init(role: .client, maxFrameSize: HTTP2Settings.maxMaxFrameSize))
    var pendingData: (stream: UInt32, remaining: Int, endStream: Bool, bytes: [UInt8])?
    var frames: [H2Frame] = []
    var error: HTTP2ErrorCode?

    mutating func feed(_ bytes: ByteBuffer) {
        bytes.withUnsafeReadableBytes { feed($0) }
    }

    mutating func feed(_ input: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < input.count || pendingData?.remaining == 0 {
            if let pending = pendingData, pending.remaining == 0 {
                frames.append(.data(stream: pending.stream, pending.bytes, endStream: pending.endStream))
                pendingData = nil
                continue
            }
            let rest = UnsafeRawBufferPointer(rebasing: input[offset...])
            let output: HTTP2FrameParser.Output
            do throws(HTTP2Error) {
                output = try parser.parse(rest)
            } catch {
                self.error = error.code
                return
            }
            offset += output.consumed
            func copy(_ location: HTTP2FrameParser.PayloadLocation) -> [UInt8] {
                parser.withPayload(location, in: rest) { Array($0) }
            }
            switch output.event {
            case .needsMoreData:
                return
            case .dataHeader(let frame):
                pendingData = (frame.streamID.rawValue, frame.dataLength, frame.endStream, [])
            case .data(let range):
                pendingData!.bytes += Array(rest[range])
                pendingData!.remaining -= range.count
            case .headers(let stream, let endStream, let endHeaders, _, let fragment):
                frames.append(.headers(stream: stream.rawValue, endStream: endStream, endHeaders: endHeaders, copy(fragment)))
            case .continuation(let stream, let endHeaders, let fragment):
                frames.append(.continuation(stream: stream.rawValue, endHeaders: endHeaders, copy(fragment)))
            case .settings(let settings): frames.append(.settings(settings))
            case .settingsAck: frames.append(.settingsAck)
            case .windowUpdate(let stream, let increment): frames.append(.windowUpdate(stream: stream.rawValue, increment))
            case .ping(let ack, let data): frames.append(.ping(ack: ack, data))
            case .goaway(let last, let code, let debug):
                frames.append(.goaway(last: last.rawValue, code, debug: String(decoding: copy(debug), as: UTF8.self)))
            case .rstStream(let stream, let code): frames.append(.rstStream(stream: stream.rawValue, code))
            case .priority, .pushPromise, .unknown, .streamError, .priorityUpdate:
                frames.append(.other("\(output.event)"))
            }
        }
    }

    /// Every frame of `bytes`.
    static func frames(in bytes: ByteBuffer) -> [H2Frame] {
        var reader = H2FrameReader()
        reader.feed(bytes)
        return reader.frames
    }
}

// MARK: Frame builders

enum F {
    static func bytes(_ build: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var buffer = ByteBuffer()
        build(&buffer)
        return buffer
    }

    static var preface: ByteBuffer { ByteBuffer(bytes: HTTP2Preface.bytes) }

    static func settings(_ settings: HTTP2Settings = HTTP2Settings()) -> ByteBuffer {
        bytes { HTTP2FrameEncoder.encodeSettings(settings, into: &$0) }
    }

    /// A SETTINGS frame with raw identifier/value pairs (including invalid ones).
    static func rawSettings(_ pairs: [(UInt16, UInt32)], streamID: UInt32 = 0, flags: HTTP2FrameFlags = []) -> ByteBuffer {
        var payload: [UInt8] = []
        for (id, value) in pairs {
            payload += [UInt8(id >> 8), UInt8(id & 0xff)]
            payload += [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
        return raw(type: .settings, flags: flags, streamID: streamID, payload: payload)
    }

    static var settingsAck: ByteBuffer { bytes { HTTP2FrameEncoder.encodeSettingsAck(into: &$0) } }

    static func ping(_ data: UInt64, ack: Bool = false) -> ByteBuffer {
        bytes { HTTP2FrameEncoder.encodePing(opaqueData: data, ack: ack, into: &$0) }
    }

    static func windowUpdate(_ stream: UInt32, _ increment: UInt32) -> ByteBuffer {
        bytes { HTTP2FrameEncoder.encodeWindowUpdate(streamID: HTTP2StreamID(stream), increment: increment, into: &$0) }
    }

    static func goaway(_ last: UInt32 = 0, _ code: HTTP2ErrorCode = .noError) -> ByteBuffer {
        bytes {
            HTTP2FrameEncoder.encodeGoaway(
                lastStreamID: HTTP2StreamID(last), code, debugData: UnsafeRawBufferPointer(start: nil, count: 0), into: &$0)
        }
    }

    static func raw(type: HTTP2FrameType, flags: HTTP2FrameFlags = [], streamID: UInt32, payload: [UInt8]) -> ByteBuffer {
        bytes { buffer in
            payload.withUnsafeBytes {
                HTTP2FrameEncoder.encodeFrame(type: type, flags: flags, streamID: HTTP2StreamID(streamID), payload: $0, into: &buffer)
            }
        }
    }

    static func headers(_ stream: UInt32, block: [UInt8], endStream: Bool = true, endHeaders: Bool = true) -> ByteBuffer {
        bytes { buffer in
            block.withUnsafeBytes {
                HTTP2FrameEncoder.encodeHeaders(
                    streamID: HTTP2StreamID(stream), fragment: $0, endStream: endStream, endHeaders: endHeaders, into: &buffer)
            }
        }
    }

    static func data(_ stream: UInt32, _ bytes: [UInt8], endStream: Bool = true) -> ByteBuffer {
        F.bytes { buffer in
            bytes.withUnsafeBytes {
                HTTP2FrameEncoder.encodeData(streamID: HTTP2StreamID(stream), data: $0, endStream: endStream, into: &buffer)
            }
        }
    }

    static func join(_ parts: ByteBuffer...) -> ByteBuffer { join(parts) }

    static func join(_ parts: [ByteBuffer]) -> ByteBuffer {
        var out = ByteBuffer()
        for part in parts { out.append(part) }
        return out
    }
}

/// Encodes request header blocks with a client-side HPACK encoder.
struct RequestEncoder {
    var hpack = HPACKEncoder()

    mutating func block(_ fields: [(String, String)]) -> [UInt8] {
        var block: [UInt8] = []
        hpack.beginHeaderBlock(into: &block)
        for (name, value) in fields {
            let n = Array(name.utf8)
            let v = Array(value.utf8)
            n.withUnsafeBufferPointer { n in
                v.withUnsafeBufferPointer { v in
                    hpack.encode(name: n.span, value: v.span, into: &block)
                }
            }
        }
        return block
    }

    mutating func get(_ path: String, method: String = "GET", extra: [(String, String)] = []) -> [UInt8] {
        block([(":method", method), (":scheme", "http"), (":authority", "localhost"), (":path", path)] + extra)
    }
}

/// Collects decoded fields as strings.
struct StringFieldSink: HPACKFieldSink {
    var fields: [(String, String)] = []

    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
        var n: [UInt8] = []
        var v: [UInt8] = []
        for i in name.indices { n.append(name[i]) }
        for i in value.indices { v.append(value[i]) }
        fields.append((String(decoding: n, as: UTF8.self), String(decoding: v, as: UTF8.self)))
    }
}

func decodeBlock(_ block: [UInt8], with decoder: inout HPACKDecoder) throws -> [(String, String)] {
    var sink = StringFieldSink()
    try block.withUnsafeBufferPointer { try decoder.decode($0.span, into: &sink) }
    return sink.fields
}

// MARK: Handlers

struct ClosureHandler: HTTPHandler {
    let body: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(_ body: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.body = body
    }

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await body(request)
    }
}

/// Answers `hello <path>`.
struct HelloHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .ok, body: .bytes(ByteBuffer(bytes: Array("hello \(request.string(of: request.path))".utf8))))
    }
}

// MARK: Client

/// The client end of an in-memory HTTP/2 connection.
struct H2Client {
    let transport: any ByteStreamTransport
    var reader = H2FrameReader()
    var consumed = 0
    var requests = RequestEncoder()
    var decoder = HPACKDecoder(maxHeaderListSize: 1 << 20)

    init(_ transport: any ByteStreamTransport) {
        self.transport = transport
    }

    func send(_ parts: ByteBuffer...) async throws {
        try await transport.send(F.join(parts), endOfStream: false)
    }

    /// Sends the preface and SETTINGS, and acknowledges the server's SETTINGS once seen.
    mutating func handshake(_ settings: HTTP2Settings = HTTP2Settings()) async throws {
        try await send(F.preface, F.settings(settings))
        let first = try await nextFrame()
        guard case .settings = first else {
            Issue.record("first server frame is \(String(describing: first))")
            return
        }
        try await send(F.settingsAck)
    }

    /// The next frame, or `nil` at end of stream. Throws after `timeout`.
    mutating func nextFrame(timeout: Duration = .seconds(10)) async throws -> H2Frame? {
        let deadline = ContinuousClock.now + timeout
        while consumed == reader.frames.count {
            if reader.error != nil { return nil }
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            var buffer = ByteBuffer()
            let transport = self.transport
            let received: Int
            do {
                received = try await withThrowingTaskGroup(of: (Int, ByteBuffer)?.self) { group in
                    group.addTask {
                        var chunk = ByteBuffer()
                        let n = try await transport.receive(into: &chunk, maxLength: 64 * 1024)
                        return (n, chunk)
                    }
                    group.addTask {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        return nil
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() ?? nil else { throw TimedOut() }
                    buffer = result.1
                    return result.0
                }
            } catch is TransportError {
                return nil
            }
            if received == 0 { return nil }
            reader.feed(buffer)
        }
        consumed += 1
        return reader.frames[consumed - 1]
    }

    /// Frames until (and including) one matching `predicate`, or until end of stream.
    mutating func frames(until predicate: (H2Frame) -> Bool, timeout: Duration = .seconds(10)) async throws -> [H2Frame] {
        var out: [H2Frame] = []
        while let frame = try await nextFrame(timeout: timeout) {
            out.append(frame)
            if predicate(frame) { break }
        }
        return out
    }

    /// Reads to end of stream (the server closed).
    mutating func framesUntilClosed(timeout: Duration = .seconds(10)) async throws -> [H2Frame] {
        try await frames(until: { _ in false }, timeout: timeout)
    }

    /// Reads one complete response on `stream`: its decoded head and body. Frames on other
    /// streams and connection frames are returned in `others`.
    mutating func response(on stream: UInt32, timeout: Duration = .seconds(10)) async throws
        -> (head: [(String, String)], body: [UInt8], others: [H2Frame])
    {
        var block: [UInt8] = []
        var head: [(String, String)] = []
        var body: [UInt8] = []
        var others: [H2Frame] = []
        while let frame = try await nextFrame(timeout: timeout) {
            switch frame {
            case .headers(stream, let endStream, let endHeaders, let fragment):
                block = fragment
                if endHeaders { head = try decodeBlock(block, with: &decoder) }
                if endStream { return (head, body, others) }
            case .continuation(stream, let endHeaders, let fragment):
                block += fragment
                if endHeaders { head = try decodeBlock(block, with: &decoder) }
            case .data(stream, let bytes, let endStream):
                body += bytes
                if endStream { return (head, body, others) }
            case .rstStream(stream, _):
                others.append(frame)
                return (head, body, others)
            default:
                others.append(frame)
                if frame.isGoaway { return (head, body, others) }
            }
        }
        return (head, body, others)
    }
}

struct TimedOut: Error {}

/// Runs `HTTP2` on the server end of an in-memory pair while `body` drives the client end;
/// then closes the client and waits for the server's `run` to return.
func withH2Connection(
    configuration: HTTP2Configuration = HTTP2Configuration(),
    handler: some HTTPHandler = HelloHandler(),
    shutdown: ShutdownSignal = ShutdownSignal(),
    info: ConnectionInfo = ConnectionInfo(),
    server serverTransport: (@Sendable (InMemoryTransport) -> any ByteStreamTransport)? = nil,
    _ body: (inout H2Client) async throws -> Void
) async throws {
    var serverConfig = InMemoryTransport.Configuration()
    serverConfig.info = info
    let (client, server) = InMemoryTransport.makePair(server: serverConfig)
    let wrapped = serverTransport?(server) ?? server
    let context = ConnectionContext(info: info, shutdown: shutdown)
    try await withThrowingTaskGroup { group in
        group.addTask {
            await runHTTP2(HTTP2(configuration: configuration), on: wrapped, handler: handler, context: context)
        }
        var h2 = H2Client(client)
        do {
            try await body(&h2)
        } catch {
            await client.close(.abort)
            throw error
        }
        await client.close(.normal)
        try await group.waitForAll()
    }
}

func runHTTP2<T: ByteStreamTransport>(_ protocol: HTTP2, on transport: T, handler: some HTTPHandler, context: ConnectionContext) async {
    await `protocol`.run(transport, handler: handler, context: context)
}

/// A server transport that counts sends and can hold sends while a gate is closed.
final class CountingTransport<Base: ByteStreamTransport>: ByteStreamTransport {
    struct State {
        var sends = 0
        var gateClosed = false
        var gateWaiters: [CheckedContinuation<Void, Never>] = []
    }

    let base: Base
    let state = Mutex(State())

    init(_ base: Base) {
        self.base = base
    }

    var info: ConnectionInfo { base.info }
    var sends: Int { state.withLock { $0.sends } }

    func closeGate() { state.withLock { $0.gateClosed = true } }

    func openGate() {
        let waiters = state.withLock { state in
            state.gateClosed = false
            defer { state.gateWaiters = [] }
            return state.gateWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        try await base.receive(into: &buffer, maxLength: maxLength)
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = state.withLock { state -> Bool in
                state.sends += 1
                if state.gateClosed { state.gateWaiters.append(continuation) }
                return state.gateClosed
            }
            if !wait { continuation.resume() }
        }
        try await base.send(bytes, endOfStream: endOfStream)
    }

    func close(_ reason: CloseReason) async {
        openGate()
        await base.close(reason)
    }
}

/// A mutable reference for test closures.
final class Box<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)

    var value: Value? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

/// Runs an `HTTP2ConnectionDriver` on the server end of an in-memory pair, so a test can call
/// into it (PINGs, counters, shared state) while `body` drives the client end; then closes the
/// client and waits for the driver to return.
func withH2Driver<H: HTTPHandler>(
    configuration: HTTP2Configuration = HTTP2Configuration(),
    handler: H,
    shutdown: ShutdownSignal = ShutdownSignal(),
    _ body: (inout H2Client, HTTP2ConnectionDriver<InMemoryTransport, H>) async throws -> Void
) async throws {
    let (client, server) = InMemoryTransport.makePair()
    let context = ConnectionContext(info: ConnectionInfo(), shutdown: shutdown)
    let driver = HTTP2ConnectionDriver(transport: server, handler: handler, context: context, configuration: configuration)
    try await withThrowingTaskGroup { group in
        group.addTask { await driver.run() }
        var h2 = H2Client(client)
        do {
            try await body(&h2, driver)
        } catch {
            await client.close(.abort)
            throw error
        }
        await client.close(.normal)
        try await group.waitForAll()
    }
}

func withH2Driver(
    configuration: HTTP2Configuration = HTTP2Configuration(),
    shutdown: ShutdownSignal = ShutdownSignal(),
    _ body: (inout H2Client, HTTP2ConnectionDriver<InMemoryTransport, HelloHandler>) async throws -> Void
) async throws {
    try await withH2Driver(configuration: configuration, handler: HelloHandler(), shutdown: shutdown, body)
}
