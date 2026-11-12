public import HTTPCore
import Synchronization

/// Errors thrown by ``WebSocket``.
public enum WebSocketError: Error, Sendable, Hashable {
    /// The connection is closing or closed; nothing more can be sent.
    case closed
    /// The close code may not be sent (RFC 6455 §7.4).
    case invalidCloseCode(WebSocketCloseCode)
    /// A close reason longer than 123 UTF-8 bytes (a control frame holds 125).
    case closeReasonTooLong
    /// A ping payload longer than 125 bytes.
    case pingPayloadTooLong
}

/// Limits and timeouts of a WebSocket session.
public struct WebSocketConfiguration: Sendable, Hashable {
    /// Largest payload of one received frame (1009 beyond).
    public var maxFrameSize: Int
    /// Largest received message after reassembly (1009 beyond).
    public var maxMessageSize: Int
    /// How long to wait for the peer's Close after ours, or for its end of stream after the
    /// handshake, before the transport is closed anyway.
    public var closeTimeout: Duration
    /// Received messages buffered for the application before reading stops (backpressure).
    public var inboundMessageCapacity: Int
    /// Frames queued for sending before `send` suspends.
    public var outboundFrameCapacity: Int
    /// Largest single read from the transport.
    public var receiveSize: Int

    public init(
        maxFrameSize: Int = 16 * 1024 * 1024,
        maxMessageSize: Int = 16 * 1024 * 1024,
        closeTimeout: Duration = .seconds(5),
        inboundMessageCapacity: Int = 1,
        outboundFrameCapacity: Int = 8,
        receiveSize: Int = 64 * 1024
    ) {
        precondition(maxFrameSize >= 125 && maxMessageSize >= 0 && inboundMessageCapacity >= 1
                     && outboundFrameCapacity >= 1 && receiveSize > 0)
        self.maxFrameSize = maxFrameSize
        self.maxMessageSize = maxMessageSize
        self.closeTimeout = closeTimeout
        self.inboundMessageCapacity = inboundMessageCapacity
        self.outboundFrameCapacity = outboundFrameCapacity
        self.receiveSize = receiveSize
    }
}

/// One server-side WebSocket connection (RFC 6455).
///
/// Received messages arrive through ``messages``, an `AsyncSequence` that ends when the
/// connection closes. Reading is demand-driven: the session buffers at most
/// ``WebSocketConfiguration/inboundMessageCapacity`` messages, then stops reading the
/// transport until the application takes one, so a slow reader slows the peer. ``send(_:)``
/// suspends while ``WebSocketConfiguration/outboundFrameCapacity`` frames wait for the
/// transport. Pings are answered automatically; ``ping(_:)`` sends one and waits for its pong.
///
/// The session runs over any ``ByteStreamTransport`` (an HTTP/1.1 connection after `101`
/// today, an HTTP/2 or HTTP/3 extended CONNECT stream later), started by
/// ``run(over:subprotocol:configuration:handler:)``.
public final class WebSocket: Sendable {
    /// The subprotocol agreed in the handshake, if any.
    public let subprotocol: String?
    /// The underlying connection's addresses.
    public let connectionInfo: ConnectionInfo
    public let configuration: WebSocketConfiguration

    struct Outbound: Sendable {
        var opcode: WSOpcode
        var payload: ByteBuffer
        /// The last frame: shut down the sending side after it.
        var endOfStream = false
    }

    struct PingWaiter: Sendable {
        var payload: ByteBuffer
        var signal: ShutdownSignal
    }

    struct Shared: Sendable {
        var connection: WSConnection
        var pingWaiters: [UInt64: PingWaiter] = [:]
        var answeredPings: Set<UInt64> = []
        var nextPingID: UInt64 = 0
        var readerFinished = false
    }

    let inbound: BoundedAsyncQueue<WebSocketMessage>
    let outbound: BoundedAsyncQueue<Outbound>
    let shared: Mutex<Shared>
    /// Triggered when a Close frame is queued: starts the close timer.
    let closeStarted = ShutdownSignal()

    init(subprotocol: String?, connectionInfo: ConnectionInfo, configuration: WebSocketConfiguration) {
        self.subprotocol = subprotocol
        self.connectionInfo = connectionInfo
        self.configuration = configuration
        inbound = BoundedAsyncQueue(capacity: configuration.inboundMessageCapacity)
        outbound = BoundedAsyncQueue(capacity: configuration.outboundFrameCapacity)
        shared = Mutex(Shared(connection: WSConnection(configuration: .init(
            maxFrameSize: configuration.maxFrameSize, maxMessageSize: configuration.maxMessageSize))))
    }

    // MARK: Application API

    /// Received messages, in order. Iteration ends when the connection closes. Iterate from
    /// one task at a time.
    public var messages: Messages { Messages(queue: inbound) }

    public struct Messages: AsyncSequence, Sendable {
        public typealias Element = WebSocketMessage
        public typealias Failure = Never
        let queue: BoundedAsyncQueue<WebSocketMessage>

        public func makeAsyncIterator() -> Iterator { Iterator(queue: queue) }

        public struct Iterator: AsyncIteratorProtocol {
            let queue: BoundedAsyncQueue<WebSocketMessage>
            public mutating func next() async -> WebSocketMessage? { await queue.next() }
        }
    }

    /// The connection state.
    public var state: WSConnection.State { shared.withLock { $0.connection.state } }

    /// The code the peer closed with (``WebSocketCloseCode/noStatusReceived`` for a Close
    /// without one, ``WebSocketCloseCode/abnormalClosure`` if the stream ended without a
    /// Close), or `nil` while no Close was received.
    public var closeCode: WebSocketCloseCode? { shared.withLock { $0.connection.receivedCloseCode } }

    /// The reason in the peer's Close frame.
    public var closeReason: String { shared.withLock { $0.connection.receivedCloseReason } }

    /// The code that failed the connection when the peer violated the protocol.
    public var failureCode: WebSocketCloseCode? { shared.withLock { $0.connection.failure } }

    /// Sends a message as one frame. Suspends while the outbound queue is full.
    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text):
            var payload = ByteBuffer(capacity: text.utf8.count)
            payload.append(contentsOf: text.utf8)
            try await enqueue(Outbound(opcode: .text, payload: payload))
        case .binary(let bytes):
            try await enqueue(Outbound(opcode: .binary, payload: bytes))
        }
    }

    /// Sends a text message.
    public func send(text: String) async throws {
        try await send(.text(text))
    }

    /// Sends a binary message.
    public func send(binary: ByteBuffer) async throws {
        try await send(.binary(binary))
    }

    /// Sends a ping and waits for a pong with the same payload.
    ///
    /// - Throws: ``WebSocketError/closed`` if the connection closes first.
    public func ping(_ payload: ByteBuffer = ByteBuffer()) async throws {
        guard payload.readableBytes <= 125 else { throw WebSocketError.pingPayloadTooLong }
        let signal = ShutdownSignal()
        let id = try shared.withLock { shared throws(WebSocketError) -> UInt64 in
            guard shared.connection.state == .open, !shared.readerFinished else { throw .closed }
            let id = shared.nextPingID
            shared.nextPingID &+= 1
            shared.pingWaiters[id] = PingWaiter(payload: payload, signal: signal)
            return id
        }
        do {
            try await enqueue(Outbound(opcode: .ping, payload: payload))
        } catch {
            _ = shared.withLock { $0.pingWaiters.removeValue(forKey: id) }
            throw error
        }
        await signal.wait()
        let answered = shared.withLock { shared -> Bool in
            shared.pingWaiters.removeValue(forKey: id)
            return shared.answeredPings.remove(id) != nil
        }
        try Task.checkCancellation()
        guard answered else { throw WebSocketError.closed }
    }

    /// Starts the close handshake with `code` and `reason`. Returns once the Close frame is
    /// queued; ``messages`` ends when the peer answers (or the close timeout passes). Closing
    /// a connection that is already closing does nothing.
    public func close(code: WebSocketCloseCode = .normalClosure, reason: String = "") async throws {
        guard code.isValidOnTheWire else { throw WebSocketError.invalidCloseCode(code) }
        guard reason.utf8.count <= 123 else { throw WebSocketError.closeReasonTooLong }
        let action = shared.withLock { $0.connection.handle(.closeRequested(code, reason: reason)) }
        guard case .sendClose(let code, let reason, _) = action else { return }
        closeStarted.trigger()
        try? await outbound.send(Outbound(opcode: .close, payload: WSFrameWriter.closePayload(code: code, reason: reason)))
    }

    func enqueue(_ frame: Outbound) async throws {
        guard state == .open else { throw WebSocketError.closed }
        do {
            try await outbound.send(frame)
        } catch is BoundedAsyncQueueFinishedError {
            throw WebSocketError.closed
        }
    }

    // MARK: Session

    enum Role { case reader, writer, handler, timer, shutdownWatcher }

    /// Runs a WebSocket session over `transport` (after the handshake) until the connection
    /// closes and `handler` returns, then closes the transport.
    ///
    /// When `handler` returns while the connection is open, the session closes it with 1000;
    /// when it throws, with 1011. When `shutdown` triggers (the server is draining, from the
    /// tunnel's ``TunnelContext``), the session starts the close handshake with 1001 Going
    /// Away; the handler sees ``messages`` end once the peer answers (#0116). The session
    /// reads, writes and times the close handshake in child tasks of one task group; nothing
    /// outlives this call.
    public static func run<T: ByteStreamTransport>(
        over transport: T,
        subprotocol: String? = nil,
        configuration: WebSocketConfiguration = WebSocketConfiguration(),
        shutdown: ShutdownSignal? = nil,
        handler: @escaping @Sendable (WebSocket) async throws -> Void
    ) async {
        let socket = WebSocket(subprotocol: subprotocol, connectionInfo: transport.info, configuration: configuration)
        await withTaskGroup(of: Role.self) { group in
            group.addTask { await socket.readLoop(transport); return .reader }
            group.addTask { await socket.writeLoop(transport); return .writer }
            group.addTask { await socket.closeTimer(transport); return .timer }
            if let shutdown {
                group.addTask {
                    await shutdown.wait()
                    if shutdown.isTriggered && !Task.isCancelled {
                        try? await socket.close(code: .goingAway)
                    }
                    return .shutdownWatcher
                }
            }
            group.addTask {
                do {
                    try await handler(socket)
                    try? await socket.close(code: .normalClosure)
                } catch {
                    try? await socket.close(code: .internalServerError)
                }
                socket.abandonInbound()
                return .handler
            }
            var running = 3
            while let role = await group.next() {
                if role != .timer && role != .shutdownWatcher {
                    running -= 1
                    if running == 0 { group.cancelAll() }
                }
            }
        }
        await transport.close(.normal)
    }

    /// The application stopped reading: drop what is buffered and whatever arrives later, so
    /// the reader never waits for it.
    func abandonInbound() {
        inbound.finish()
        while inbound.tryNext() != nil {}
    }

    func readLoop<T: ByteStreamTransport>(_ transport: T) async {
        var buffer = ByteBuffer(capacity: configuration.receiveSize)
        /// After our final Close: discard input until the peer's end of stream.
        var draining = false
        reading: while true {
            if !draining {
                processing: while true {
                    let action = shared.withLock { $0.connection.process(&buffer) }
                    switch action {
                    case .needMoreBytes, .none:
                        break processing
                    case .deliver(let message):
                        // Suspends while the application is behind: no more reads until it catches up.
                        try? await inbound.send(message)
                    case .sendPong(let payload):
                        try? await outbound.send(Outbound(opcode: .pong, payload: payload))
                    case .receivedPong(let payload):
                        answerPings(payload)
                    case .sendClose(let code, let reason, let thenCloseTransport):
                        closeStarted.trigger()
                        let payload = WSFrameWriter.closePayload(code: code, reason: reason)
                        try? await outbound.send(Outbound(opcode: .close, payload: payload, endOfStream: thenCloseTransport))
                        if thenCloseTransport {
                            endApplicationSide()
                            draining = true
                            break processing
                        }
                    case .closeTransport:
                        break reading
                    }
                }
            }
            if draining { buffer.clear() } else { buffer.discardReadBytes() }
            let count: Int
            do {
                count = try await transport.receive(into: &buffer, maxLength: configuration.receiveSize)
            } catch {
                _ = shared.withLock { $0.connection.handle(.endOfStream) }
                break reading
            }
            if count == 0 {
                _ = shared.withLock { $0.connection.handle(.endOfStream) }
                break reading
            }
        }
        shared.withLock { $0.readerFinished = true }
        endApplicationSide()
    }

    /// Ends ``messages``, stops accepting frames once the queued ones are written, and fails
    /// waiting pings.
    func endApplicationSide() {
        inbound.finish()
        outbound.finish()
        let waiters = shared.withLock { shared -> [PingWaiter] in
            defer { shared.pingWaiters = [:] }
            return Array(shared.pingWaiters.values)
        }
        for waiter in waiters { waiter.signal.trigger() }
    }

    func answerPings(_ payload: ByteBuffer) {
        let signals = shared.withLock { shared -> [ShutdownSignal] in
            var signals: [ShutdownSignal] = []
            for (id, waiter) in shared.pingWaiters where waiter.payload == payload {
                shared.answeredPings.insert(id)
                signals.append(waiter.signal)
            }
            return signals
        }
        for signal in signals { signal.trigger() }
    }

    func writeLoop<T: ByteStreamTransport>(_ transport: T) async {
        var frame = ByteBuffer(capacity: 256)
        var closeSent = false
        for await item in outbound {
            // Nothing follows a Close (RFC 6455 §5.5.1); late frames are dropped.
            if closeSent { continue }
            closeSent = item.opcode == .close
            frame.clear()
            WSFrameWriter.appendHeader(opcode: item.opcode, payloadLength: item.payload.readableBytes, into: &frame)
            do {
                if item.payload.readableBytes <= 16 * 1024 {
                    frame.append(item.payload)
                    try await transport.send(frame, endOfStream: item.endOfStream)
                } else {
                    try await transport.send(frame, endOfStream: false)
                    try await transport.send(item.payload, endOfStream: item.endOfStream)
                }
            } catch {
                // The peer is gone: unblock the reader and drop the rest.
                outbound.finish()
                while outbound.tryNext() != nil {}
                await transport.close(.abort)
                return
            }
        }
    }

    func closeTimer<T: ByteStreamTransport>(_ transport: T) async {
        await closeStarted.wait()
        guard !Task.isCancelled else { return }
        do {
            try await Task.sleep(for: configuration.closeTimeout)
        } catch {
            return
        }
        let readerFinished = shared.withLock { shared -> Bool in
            _ = shared.connection.handle(.closeTimedOut)
            return shared.readerFinished
        }
        if !readerFinished { await transport.close(.timeout) }
    }
}
