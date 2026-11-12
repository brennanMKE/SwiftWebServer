public import HTTPCore
import HTTP1
import NetworkTransport
import Synchronization

/// One upstream connection with its unread bytes.
final class UpstreamConnection: @unchecked Sendable {
    let transport: BSDSocketTransport
    var pending: [UInt8] = []
    var eof = false

    init(transport: BSDSocketTransport) { self.transport = transport }

    /// Reads more bytes into `pending`. Returns false at end of stream. Throws
    /// `UpstreamError.timeout` when nothing arrives within `limit` (#0122); the cancelled
    /// receive closes the transport.
    func fill(limit: Duration? = nil) async throws -> Bool {
        if eof { return false }
        let buffer: ByteBuffer
        if let limit {
            let transport = transport
            buffer = try await withUpstreamTimeout(limit) {
                var b = ByteBuffer(capacity: 16 * 1024)
                _ = try await transport.receive(into: &b, maxLength: 16 * 1024)
                return b
            }
        } else {
            var b = ByteBuffer(capacity: 16 * 1024)
            _ = try await transport.receive(into: &b, maxLength: 16 * 1024)
            buffer = b
        }
        if buffer.readableBytes == 0 { eof = true; return false }
        buffer.withUnsafeReadableBytes { pending.append(contentsOf: $0) }
        return true
    }

    func close() async { await transport.close(.normal) }
}

/// A pooled HTTP/1.1 client for upstream app servers (#0120).
public final class UpstreamHTTP1Client: UpstreamClient {
    public struct Configuration: Sendable {
        /// Idle keep-alive connections kept per target.
        public var maxIdlePerTarget: Int
        public var parserLimits: UpstreamResponseParserLimits
        public init(maxIdlePerTarget: Int = 16, parserLimits: UpstreamResponseParserLimits = UpstreamResponseParserLimits()) {
            self.maxIdlePerTarget = maxIdlePerTarget
            self.parserLimits = parserLimits
        }
    }

    public let configuration: Configuration
    private let idle = Mutex<[UpstreamAddress: [UpstreamConnection]]>([:])
    private let opened = Atomic<Int>(0)
    /// Test seam: runs before every connect (loopback cannot black-hole a SYN on macOS, so
    /// tests delay here to exercise the connect timeout).
    let beforeConnect: (@Sendable () async throws -> Void)?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.beforeConnect = nil
    }

    init(configuration: Configuration = Configuration(), beforeConnect: @escaping @Sendable () async throws -> Void) {
        self.configuration = configuration
        self.beforeConnect = beforeConnect
    }

    /// Number of connections this client has opened (for tests and metrics).
    public var connectionsOpened: Int { opened.load(ordering: .relaxed) }

    /// Number of idle pooled connections for `address`.
    public func idleCount(for address: UpstreamAddress) -> Int {
        idle.withLock { $0[address]?.count ?? 0 }
    }

    /// Closes every idle connection.
    public func shutdown() async {
        let all = idle.withLock { state -> [UpstreamConnection] in
            let a = state.values.flatMap { $0 }
            state.removeAll()
            return a
        }
        for c in all { await c.close() }
    }

    private func checkout(_ address: UpstreamAddress) -> UpstreamConnection? {
        idle.withLock { state in
            guard var list = state[address], !list.isEmpty else { return nil }
            let c = list.removeLast()
            state[address] = list
            return c
        }
    }

    private func checkin(_ connection: UpstreamConnection, _ address: UpstreamAddress) async {
        guard connection.pending.isEmpty, !connection.eof else {
            await connection.close(); return
        }
        let accepted = idle.withLock { state -> Bool in
            var list = state[address] ?? []
            guard list.count < configuration.maxIdlePerTarget else { return false }
            list.append(connection)
            state[address] = list
            return true
        }
        if !accepted { await connection.close() }
    }

    private func connect(_ address: UpstreamAddress, limit: Duration?) async throws -> UpstreamConnection {
        guard let limit else { return try await connect(address) }
        return try await withUpstreamTimeout(limit, error: .connectTimeout, discard: { await $0.close() }) {
            try await self.connect(address)
        }
    }

    private func connect(_ address: UpstreamAddress) async throws -> UpstreamConnection {
        do {
            try await beforeConnect?()
            switch address {
            case .tcp(let host, let port):
                let t = try await BSDSocketTransport.connect(host: host, port: port)
                opened.add(1, ordering: .relaxed)
                return UpstreamConnection(transport: t)
            case .unix(let path):
                let t = try await BSDSocketTransport.connect(unixPath: path)
                opened.add(1, ordering: .relaxed)
                return UpstreamConnection(transport: t)
            }
        } catch let e as UpstreamError {
            throw e
        } catch is CancellationError {
            throw UpstreamError.cancelled
        } catch {
            throw UpstreamError.connectFailed("\(error)")
        }
    }

    static func serializeHead(_ request: UpstreamRequest, target: UpstreamTarget, framing: UpstreamBodyFraming) -> ByteBuffer {
        var buffer = ByteBuffer(capacity: 512)
        // `request.target` is final: the proxy already prepended `target.basePath` (#0122).
        let path = request.target
        buffer.append(contentsOf: "\(request.method) \(path) HTTP/1.1\r\nhost: \(request.host)\r\n".utf8)
        let h = request.headers
        for i in 0..<h.count {
            let name = h.nameString(at: i).lowercased()
            if name == "host" || name == "content-length" || name == "transfer-encoding" || name == "connection" { continue }
            h.withName(at: i) { buffer.append(contentsOf: $0) }
            buffer.append(contentsOf: ": ".utf8)
            h.withValue(at: i) { buffer.append(contentsOf: $0) }
            buffer.append(contentsOf: "\r\n".utf8)
        }
        switch framing {
        case .length(let n): buffer.append(contentsOf: "content-length: \(n)\r\n".utf8)
        case .chunked: buffer.append(contentsOf: "transfer-encoding: chunked\r\n".utf8)
        case .none, .close: break
        }
        buffer.append(contentsOf: "\r\n".utf8)
        return buffer
    }

    public func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget) async throws -> UpstreamResponse {
        try await send(request, body: body, to: target, options: UpstreamSendOptions())
    }

    public func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget,
                     options: UpstreamSendOptions) async throws -> UpstreamResponse {
        let timeouts = options.timeouts
        let deadline = options.deadline ?? timeouts.total.map { ContinuousClock.now + $0 }
        // A pooled connection may have been closed by the upstream. Resend once on a fresh one
        // only for an idempotent method with no request body, and only when the pooled
        // connection failed before a single response byte arrived (#0122).
        let bodiless = body.isEmpty || body.knownLength == 0
        let mayRetry = options.retriesStaleConnection && request.method.isIdempotent && bodiless
        if let pooled = checkout(target.address) {
            do {
                return try await exchange(request, body: body, target: target, connection: pooled,
                                          timeouts: timeouts, deadline: deadline, pooled: true)
            } catch is StaleConnection {
                guard mayRetry else { throw UpstreamError.closedEarly }
            }
        }
        let limit = try UpstreamTimeouts.limit(timeouts.connect, deadline: deadline, error: .connectTimeout)
        let fresh = try await connect(target.address, limit: limit)
        return try await exchange(request, body: body, target: target, connection: fresh,
                                  timeouts: timeouts, deadline: deadline, pooled: false)
    }

    /// A pooled connection failed before any response byte arrived.
    struct StaleConnection: Error {}

    private func exchange(_ request: UpstreamRequest, body: HTTPRequestBody, target: UpstreamTarget,
                          connection: UpstreamConnection, timeouts: UpstreamTimeouts,
                          deadline: ContinuousClock.Instant?, pooled: Bool) async throws -> UpstreamResponse {
        let framing: UpstreamBodyFraming
        if let n = body.knownLength {
            framing = n == 0 ? .none : .length(n)
        } else if body.isEmpty {
            framing = .none
        } else {
            framing = .chunked
        }
        do {
            try await connection.transport.send(Self.serializeHead(request, target: target, framing: framing), endOfStream: false)
            if framing != .none {
                for try await chunk in body {
                    if chunk.readableBytes == 0 { continue }
                    if framing == .chunked {
                        var b = ByteBuffer(capacity: chunk.readableBytes + 16)
                        b.append(contentsOf: (String(chunk.readableBytes, radix: 16) + "\r\n").utf8)
                        b.append(chunk)
                        b.append(contentsOf: "\r\n".utf8)
                        try await connection.transport.send(b, endOfStream: false)
                    } else {
                        try await connection.transport.send(chunk, endOfStream: false)
                    }
                }
                if framing == .chunked {
                    try await connection.transport.send(ByteBuffer("0\r\n\r\n"), endOfStream: false)
                }
            }
            // Read the head, skipping interim 1xx responses, within the response timeout
            // (measured from the end of the request) and the total deadline.
            let headDeadline = timeouts.response.map { ContinuousClock.now + $0 }
            let parser = UpstreamResponseParser(limits: configuration.parserLimits)
            var head: UpstreamResponseHead
            var received = false
            while true {
                if let (h, used) = try parser.parseHead(connection.pending, requestMethod: request.method) {
                    connection.pending.removeFirst(used)
                    if (100..<200).contains(h.status.code) && h.status.code != 101 { continue }
                    head = h
                    break
                }
                let limit = try UpstreamTimeouts.limit(
                    UpstreamTimeouts.limit(nil, deadline: headDeadline), deadline: deadline)
                guard try await connection.fill(limit: limit) else {
                    if pooled && !received { throw StaleConnection() }
                    throw UpstreamError.closedEarly
                }
                received = true
            }
            return makeResponse(head, connection: connection, address: target.address,
                                idle: timeouts.idle, deadline: deadline)
        } catch {
            await connection.close()
            if error is StaleConnection { throw error }
            if let e = error as? UpstreamError { throw e }
            if error is CancellationError { throw UpstreamError.cancelled }
            if error is TransportError {
                // A reset or broken pipe on a reused connection before any response byte.
                if pooled && connection.pending.isEmpty && !connection.eof { throw StaleConnection() }
                throw UpstreamError.closedEarly
            }
            throw error
        }
    }

    private func makeResponse(_ head: UpstreamResponseHead, connection: UpstreamConnection, address: UpstreamAddress,
                              idle: Duration?, deadline: ContinuousClock.Instant?) -> UpstreamResponse {
        let reader = BodyReader(framing: head.framing, connection: connection, reusable: !head.closeAfter,
                                idle: idle, deadline: deadline) { [self] conn, reuse in
            if reuse { await self.checkin(conn, address) } else { await conn.close() }
        }
        let knownLength: Int? = switch head.framing {
        case .none: 0
        case .length(let n): n
        default: nil
        }
        if head.framing == .none {
            let reuse = !head.closeAfter
            // Body is empty: return the connection right away.
            Task { await reader.finish(reuse: reuse) }
            return UpstreamResponse(status: head.status, headers: head.headers, body: .empty)
        }
        return UpstreamResponse(status: head.status, headers: head.headers,
                                body: UpstreamResponseBody(knownLength: knownLength,
                                                           next: { try await reader.next() },
                                                           discard: { await reader.finish(reuse: false) }))
    }
}

/// Streams one response body off a connection, then releases the connection.
actor BodyReader {
    enum State { case length(Int), chunked(ChunkedDecoder), close, done }
    private var state: State
    private var connection: UpstreamConnection?
    private let reusable: Bool
    private let release: @Sendable (UpstreamConnection, Bool) async -> Void
    /// Limit between two body reads, and the end of the whole exchange (#0122).
    private let idle: Duration?
    private let deadline: ContinuousClock.Instant?

    init(framing: UpstreamBodyFraming, connection: UpstreamConnection, reusable: Bool,
         idle: Duration? = nil, deadline: ContinuousClock.Instant? = nil,
         release: @escaping @Sendable (UpstreamConnection, Bool) async -> Void) {
        self.idle = idle
        self.deadline = deadline
        switch framing {
        case .none: state = .done
        case .length(let n): state = .length(n)
        case .chunked: state = .chunked(ChunkedDecoder())
        case .close: state = .close
        }
        self.connection = connection
        self.reusable = reusable
        self.release = release
    }

    func finish(reuse: Bool) async {
        state = .done
        guard let c = connection else { return }
        connection = nil
        await release(c, reuse && reusable)
    }

    func next() async throws -> ByteBuffer? {
        guard let c = connection else { return nil }
        do {
            while true {
                switch state {
                case .done:
                    await finish(reuse: true)
                    return nil
                case .length(let remaining):
                    if c.pending.isEmpty {
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { throw UpstreamError.closedEarly }
                    }
                    let take = min(remaining, c.pending.count)
                    let out = ByteBuffer(bytes: c.pending[0..<take])
                    c.pending.removeFirst(take)
                    state = remaining - take == 0 ? .done : .length(remaining - take)
                    if case .done = state { await finish(reuse: true) }
                    return out
                case .close:
                    if c.pending.isEmpty {
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { await finish(reuse: false); return nil }
                    }
                    let out = ByteBuffer(bytes: c.pending)
                    c.pending.removeAll(keepingCapacity: true)
                    return out
                case .chunked(var decoder):
                    if c.pending.isEmpty {
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { throw UpstreamError.closedEarly }
                    }
                    let step = ByteBuffer(bytes: c.pending).withReadableSpan { decoder.decode($0) }
                    state = .chunked(decoder)
                    switch step.kind {
                    case .data:
                        let out = ByteBuffer(bytes: c.pending[step.range])
                        c.pending.removeFirst(step.consumed)
                        if out.readableBytes > 0 { return out }
                    case .needMoreBytes:
                        c.pending.removeFirst(step.consumed)
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { throw UpstreamError.closedEarly }
                    case .end:
                        c.pending.removeFirst(step.consumed)
                        state = .done
                    case .error(let e):
                        throw UpstreamError.malformedResponse("chunked: \(e)")
                    }
                }
            }
        } catch {
            await finish(reuse: false)
            if let e = error as? UpstreamError { throw e }
            throw UpstreamError.closedEarly
        }
    }
}
