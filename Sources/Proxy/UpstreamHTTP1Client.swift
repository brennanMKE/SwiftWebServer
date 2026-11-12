public import HTTPCore
import HTTP1
import NetworkTransport
import Synchronization

/// One upstream connection with its unread bytes. Used by one exchange at a time.
final class UpstreamConnection: @unchecked Sendable {
    let transport: BSDSocketTransport
    var pending: [UInt8] = []
    var eof = false
    /// Reused for every receive and every request head, so a kept-alive connection does not
    /// allocate them per request.
    private var readBuffer = ByteBuffer()
    var headBuffer = ByteBuffer()

    static let readSize = 16 * 1024

    init(transport: BSDSocketTransport) { self.transport = transport }

    /// Reads more bytes into `pending`. Returns false at end of stream. Throws
    /// `UpstreamError.timeout` when nothing arrives within `limit` (#0122); the cancelled
    /// receive closes the transport.
    func fill(limit: Duration? = nil) async throws -> Bool {
        if eof { return false }
        var buffer = readBuffer
        readBuffer = ByteBuffer()
        buffer.clear()
        if let limit {
            let transport = transport
            let start = buffer
            buffer = ByteBuffer()
            buffer = try await withUpstreamTimeout(limit) {
                var b = start
                _ = try await transport.receive(into: &b, maxLength: Self.readSize)
                return b
            }
        } else {
            _ = try await transport.receive(into: &buffer, maxLength: Self.readSize)
        }
        defer { readBuffer = buffer }
        if buffer.readableBytes == 0 { eof = true; return false }
        buffer.withUnsafeReadableBytes { pending.append(contentsOf: $0) }
        return true
    }

    func close() async { await transport.close(.normal) }
}

/// A pooled HTTP/1.1 client for upstream app servers (#0120).
///
/// Per upstream address it keeps up to ``UpstreamPoolPolicy/maxIdle`` keep-alive connections,
/// opens at most ``UpstreamPoolPolicy/maxConnections`` at once and queues the requests over
/// that limit (bounded, with a timeout; ``UpstreamError/poolExhausted`` when full). A pooled
/// connection is reused only after a complete, well-framed exchange, when it is younger than
/// ``UpstreamPoolPolicy/idleTimeout`` and a non-blocking peek finds it still open with
/// nothing unread (so a request does not go out on a connection the upstream already closed).
/// The policy comes with each request (``UpstreamSendOptions/pool``), so mounts configure it.
public final class UpstreamHTTP1Client: UpstreamClient {
    public struct Configuration: Sendable {
        /// Idle keep-alive connections kept per target, an upper bound on the per-request
        /// ``UpstreamPoolPolicy/maxIdle``.
        public var maxIdlePerTarget: Int
        public var parserLimits: UpstreamResponseParserLimits
        public init(maxIdlePerTarget: Int = 16, parserLimits: UpstreamResponseParserLimits = UpstreamResponseParserLimits()) {
            self.maxIdlePerTarget = maxIdlePerTarget
            self.parserLimits = parserLimits
        }
    }

    public let configuration: Configuration
    let pools = UpstreamPools()
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
    public func idleCount(for address: UpstreamAddress) -> Int { pools.idleCount(address) }

    /// Connections open (or being opened) to `address`, idle ones included.
    public func openCount(for address: UpstreamAddress) -> Int { pools.openCount(address) }

    /// Requests waiting for a connection to `address`.
    public func waitingCount(for address: UpstreamAddress) -> Int { pools.waiterCount(address) }

    /// Closes every idle connection.
    public func shutdown() async {
        await evictIdleConnections(all: true)
    }

    public func evictIdleConnections(all: Bool) async {
        for c in pools.takeIdle(all: all, now: .now) { await c.close() }
    }

    private func effective(_ policy: UpstreamPoolPolicy) -> UpstreamPoolPolicy {
        var p = policy
        p.maxIdle = min(p.maxIdle, configuration.maxIdlePerTarget)
        return p
    }

    /// A live pooled connection, or nil with a slot reserved for opening a new one.
    private func acquire(_ address: UpstreamAddress, policy: UpstreamPoolPolicy) async throws -> UpstreamConnection? {
        // Expired idle connections close when released at the end of this call.
        var expired: [UpstreamConnection] = []
        var grant: UpstreamPoolState.Grant
        switch pools.checkout(address, policy: policy, now: .now, expired: &expired) {
        case .grant(let g): grant = g
        case .full: throw UpstreamError.poolExhausted
        case .wait: grant = try await pools.wait(address, policy: policy)
        }
        while case .connection(let connection) = grant {
            if connection.pending.isEmpty, !connection.eof, connection.transport.isIdleAndOpen { return connection }
            // The upstream closed it (or sent something unasked) while it sat idle.
            await connection.close()
            pools.releaseSlot(address)
            switch pools.checkout(address, policy: policy, now: .now, expired: &expired) {
            case .grant(let g): grant = g
            case .full: throw UpstreamError.poolExhausted
            case .wait: grant = try await pools.wait(address, policy: policy)
            }
        }
        return nil
    }

    /// Releases a connection after its exchange: pooled when `reuse`, closed otherwise.
    func release(_ connection: UpstreamConnection, _ address: UpstreamAddress, reuse: Bool,
                 policy: UpstreamPoolPolicy) async {
        if reuse, connection.pending.isEmpty, !connection.eof {
            if let close = pools.checkin(connection, address, policy: policy, now: .now) { await close.close() }
        } else {
            await connection.close()
            pools.releaseSlot(address)
        }
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

    /// Writes the request head straight from the request's bytes: no `String` building and no
    /// lowercasing (field names are matched by their resolved ``HTTPFieldName``). `Host`,
    /// framing and (unless `keepConnection`) `Connection` fields are replaced by the client's.
    static func writeHead(_ request: UpstreamRequest, framing: UpstreamBodyFraming, keepConnection: Bool = false,
                          into buffer: inout ByteBuffer) {
        request.method.append(to: &buffer)
        buffer.append(UInt8(ascii: " "))
        buffer.append(contentsOf: request.target.utf8)
        buffer.append(" HTTP/1.1\r\nhost: ")
        buffer.append(contentsOf: request.host.utf8)
        buffer.append("\r\n")
        request.headers.withFieldStorage { index, arena in
            let names = index.names
            let nameViews = index.nameViews
            let valueViews = index.valueViews
            for i in 0..<index.count {
                let name = names[i]
                switch name {
                case .host, .contentLength, .transferEncoding: continue
                case .connection where !keepConnection: continue
                case .unknown: buffer.append(nameViews[i], from: arena)
                default: buffer.append(name.canonicalName)
                }
                buffer.append(": ")
                buffer.append(valueViews[i], from: arena)
                buffer.append("\r\n")
            }
        }
        switch framing {
        case .length(let n):
            buffer.append("content-length: ")
            buffer.append(decimal: n)
            buffer.append("\r\n")
        case .chunked: buffer.append("transfer-encoding: chunked\r\n")
        case .none, .close: break
        }
        buffer.append("\r\n")
    }

    /// For `sws-bench`: ``writeHead(_:framing:keepConnection:into:)`` for a bodiless request.
    @_spi(Benchmark) public static func benchWriteHead(_ request: UpstreamRequest, into buffer: inout ByteBuffer) {
        writeHead(request, framing: .none, into: &buffer)
    }

    static func serializeHead(_ request: UpstreamRequest, target: UpstreamTarget, framing: UpstreamBodyFraming) -> ByteBuffer {
        var buffer = ByteBuffer(capacity: 512)
        writeHead(request, framing: framing, into: &buffer)
        return buffer
    }

    public func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget) async throws -> UpstreamResponse {
        try await send(request, body: body, to: target, options: UpstreamSendOptions())
    }

    public func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget,
                     options: UpstreamSendOptions) async throws -> UpstreamResponse {
        let timeouts = options.timeouts
        let deadline = options.deadline ?? timeouts.total.map { ContinuousClock.now + $0 }
        let policy = effective(options.pool)
        let address = target.address
        // A pooled connection may have been closed by the upstream after the liveness check.
        // Resend once on a fresh one only for an idempotent method with no request body, and
        // only when the pooled connection failed before a single response byte arrived (#0122).
        let bodiless = body.isEmpty || body.knownLength == 0
        let mayRetry = options.retriesStaleConnection && request.method.isIdempotent && bodiless
        var connection = try await acquire(address, policy: policy)
        if let pooled = connection {
            do {
                return try await exchange(request, body: body, address: address, connection: pooled,
                                          timeouts: timeouts, deadline: deadline, policy: policy, pooled: true)
            } catch is StaleConnection {
                guard mayRetry else { throw UpstreamError.closedEarly }
                // `exchange` gave the slot back; take another (no further stale retry).
                connection = try await acquire(address, policy: policy)
            }
        }
        if connection == nil {
            // Holding a slot: open a connection, or give the slot back when that fails.
            do {
                let limit = try UpstreamTimeouts.limit(timeouts.connect, deadline: deadline, error: .connectTimeout)
                connection = try await connect(address, limit: limit)
            } catch {
                pools.releaseSlot(address)
                throw error
            }
        }
        do {
            return try await exchange(request, body: body, address: address, connection: connection!,
                                      timeouts: timeouts, deadline: deadline, policy: policy, pooled: false)
        } catch is StaleConnection {
            throw UpstreamError.closedEarly
        }
    }

    /// A pooled connection failed before any response byte arrived.
    struct StaleConnection: Error {}

    private func exchange(_ request: UpstreamRequest, body: HTTPRequestBody, address: UpstreamAddress,
                          connection: UpstreamConnection, timeouts: UpstreamTimeouts,
                          deadline: ContinuousClock.Instant?, policy: UpstreamPoolPolicy,
                          pooled: Bool) async throws -> UpstreamResponse {
        let framing: UpstreamBodyFraming
        if let n = body.knownLength {
            framing = n == 0 ? .none : .length(n)
        } else if body.isEmpty {
            framing = .none
        } else {
            framing = .chunked
        }
        do {
            var head = connection.headBuffer
            connection.headBuffer = ByteBuffer()
            head.clear()
            Self.writeHead(request, framing: framing, into: &head)
            try await connection.transport.send(head, endOfStream: false)
            connection.headBuffer = head
            if framing != .none {
                for try await chunk in body {
                    if chunk.readableBytes == 0 { continue }
                    if framing == .chunked {
                        // Framed in the connection's reused buffer: one copy, one send.
                        var framed = connection.headBuffer
                        connection.headBuffer = ByteBuffer()
                        framed.clear()
                        framed.append(hex: UInt64(chunk.readableBytes))
                        framed.append("\r\n")
                        framed.append(chunk)
                        framed.append("\r\n")
                        try await connection.transport.send(framed, endOfStream: false)
                        connection.headBuffer = framed
                    } else {
                        try await connection.transport.send(chunk, endOfStream: false)
                    }
                }
                if framing == .chunked {
                    try await connection.transport.send(ByteBuffer("0\r\n\r\n"), endOfStream: false)
                }
            }
            // Read the final head within the response timeout (measured from the end of the
            // request) and the total deadline. Interim 1xx responses other than 101 (`100
            // Continue`, `103 Early Hints`) are consumed here and not relayed: the downstream
            // protocols answer `Expect: 100-continue` themselves and have no interim-response
            // API, and early hints are advisory.
            let headDeadline = timeouts.response.map { ContinuousClock.now + $0 }
            let parser = UpstreamResponseParser(limits: configuration.parserLimits)
            var responseHead: UpstreamResponseHead
            var received = false
            while true {
                if let (h, used) = try parser.parseHead(connection.pending, requestMethod: request.method) {
                    connection.pending.removeFirst(used)
                    if (100..<200).contains(h.status.code) && h.status.code != 101 { continue }
                    responseHead = h
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
            return await makeResponse(responseHead, connection: connection, address: address,
                                      idle: timeouts.idle, deadline: deadline, policy: policy)
        } catch {
            await connection.close()
            pools.releaseSlot(address)
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
                              idle: Duration?, deadline: ContinuousClock.Instant?,
                              policy: UpstreamPoolPolicy) async -> UpstreamResponse {
        if head.framing == .none {
            // Body is empty: return the connection right away.
            await release(connection, address, reuse: !head.closeAfter, policy: policy)
            return UpstreamResponse(status: head.status, headers: head.headers, body: .empty)
        }
        let pools = pools
        let reader = BodyReader(framing: head.framing, connection: connection, reusable: !head.closeAfter,
                                idle: idle, deadline: deadline,
                                abandoned: { pools.releaseSlot(address) }) { [self] conn, reuse in
            await self.release(conn, address, reuse: reuse, policy: policy)
        }
        let knownLength: Int? = if case .length(let n) = head.framing { n } else { nil }
        return UpstreamResponse(status: head.status, headers: head.headers,
                                body: UpstreamResponseBody(knownLength: knownLength,
                                                           next: { try await reader.next() },
                                                           discard: { await reader.finish(reuse: false) }))
    }
}

/// Streams one response body off a connection, then releases the connection.
///
/// Single consumer: the response writer calls ``next()`` until it returns nil, or ``finish(reuse:)``
/// to abandon the body; calls do not overlap (an overlapping one fails with `closedEarly`).
final class BodyReader: @unchecked Sendable {
    enum State { case length(Int), chunked(ChunkedDecoder), close, done }
    private var state: State
    private var connection: UpstreamConnection?
    private let reusable: Bool
    private let release: @Sendable (UpstreamConnection, Bool) async -> Void
    /// Limit between two body reads, and the end of the whole exchange (#0122).
    private let idle: Duration?
    private let deadline: ContinuousClock.Instant?
    private let busy = Atomic<Bool>(false)
    /// Called from `deinit` when the body was neither read to the end nor discarded (the
    /// response was dropped unsent): gives the pool slot back. The connection closes with it.
    private let abandoned: (@Sendable () -> Void)?

    init(framing: UpstreamBodyFraming, connection: UpstreamConnection, reusable: Bool,
         idle: Duration? = nil, deadline: ContinuousClock.Instant? = nil,
         abandoned: (@Sendable () -> Void)? = nil,
         release: @escaping @Sendable (UpstreamConnection, Bool) async -> Void) {
        self.abandoned = abandoned
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

    deinit {
        if connection != nil { abandoned?() }
    }

    private func enter() -> Bool {
        busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
    }

    private func leave() { busy.store(false, ordering: .releasing) }

    func finish(reuse: Bool) async {
        guard enter() else { return }
        defer { leave() }
        await finishLocked(reuse: reuse)
    }

    private func finishLocked(reuse: Bool) async {
        state = .done
        guard let c = connection else { return }
        connection = nil
        await release(c, reuse && reusable)
    }

    func next() async throws -> ByteBuffer? {
        guard enter() else { throw UpstreamError.closedEarly }
        defer { leave() }
        guard let c = connection else { return nil }
        do {
            while true {
                switch state {
                case .done:
                    await finishLocked(reuse: true)
                    return nil
                case .length(let remaining):
                    if c.pending.isEmpty {
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { throw UpstreamError.closedEarly }
                    }
                    let take = min(remaining, c.pending.count)
                    let out = ByteBuffer(bytes: c.pending[0..<take])
                    c.pending.removeFirst(take)
                    state = remaining - take == 0 ? .done : .length(remaining - take)
                    if case .done = state { await finishLocked(reuse: true) }
                    return out
                case .close:
                    if c.pending.isEmpty {
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { await finishLocked(reuse: false); return nil }
                    }
                    let out = ByteBuffer(bytes: c.pending)
                    c.pending.removeAll(keepingCapacity: true)
                    return out
                case .chunked(var decoder):
                    if c.pending.isEmpty {
                        guard try await c.fill(limit: UpstreamTimeouts.limit(idle, deadline: deadline)) else { throw UpstreamError.closedEarly }
                    }
                    let step = c.pending.withUnsafeBufferPointer { decoder.decode($0.span) }
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
            await finishLocked(reuse: false)
            if let e = error as? UpstreamError { throw e }
            throw UpstreamError.closedEarly
        }
    }
}
