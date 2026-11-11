public import HTTPCore
import Synchronization

/// An in-memory ``ByteStreamTransport`` for protocol tests (docs/ROADMAP.md §4, §5.2).
///
/// Two modes:
///
/// - **Paired** (``makePair(client:server:)``): two connected endpoints. Bytes sent on one are
///   received on the other through a bounded ``BoundedAsyncQueue``, so backpressure is real: a
///   sender suspends once the reader stops and the pipe holds ``Configuration/bufferBound``
///   bytes.
/// - **Scripted** (``scripted(_:configuration:)``): inbound traffic is a fixed list of
///   ``Event``s (bytes, delays, end of stream, errors); sent bytes are captured and never block.
///
/// Every endpoint captures the bytes it sent (``sentBytes``) and splits what it receives
/// according to ``Configuration/receiveChunking`` (for example one byte per receive), so parsers
/// can be driven through every split boundary. No `DispatchQueue`, no unstructured tasks, no
/// unbounded in-flight buffering.
public final class InMemoryTransport: ByteStreamTransport {
    /// One unit of inbound traffic.
    public enum Event: Sendable {
        /// Bytes to deliver (split further by the receiver's chunking).
        case bytes(ByteBuffer)
        /// The receiver pauses for this long when it reaches the event (cancellable).
        case delay(Duration)
        /// The peer shut down its sending direction: receives return 0 from here on.
        case endOfStream
        /// The receive that reaches this event, and every later one, throws `error`.
        case error(TransportError)
    }

    /// How a receiver splits inbound bytes across `receive` calls.
    public enum Chunking: Sendable, Hashable {
        /// Return as much of the current segment as `maxLength` allows.
        case unlimited
        /// Return at most `n` bytes per receive.
        case fixed(Int)
        /// Return at most `sizes[i]` bytes on the i-th receive that delivers bytes, cycling.
        /// `[k, .max]` splits a single segment at offset `k`.
        case pattern([Int])

        /// One byte per receive.
        public static let bytewise = Chunking.fixed(1)

        func limit(at index: Int) -> Int {
            switch self {
            case .unlimited: .max
            case .fixed(let n): n
            case .pattern(let sizes): sizes[index % sizes.count]
            }
        }
    }

    /// Settings for one endpoint. The receiver's configuration sizes the pipe it reads from.
    public struct Configuration: Sendable {
        /// Approximate bytes the inbound pipe buffers before senders suspend.
        public var bufferCapacity: Int
        /// Largest piece a peer's send is split into before it enters the pipe this endpoint
        /// reads from (so the pipe's byte bound holds whatever the sender writes).
        public var segmentSize: Int
        /// How received bytes are split across `receive` calls.
        public var receiveChunking: Chunking
        /// Whether ``sentBytes`` records sent bytes (turn off for very large transfers).
        public var capturesSentBytes: Bool
        /// Reported by ``InMemoryTransport/info``.
        public var info: ConnectionInfo

        public init(
            bufferCapacity: Int = 64 * 1024,
            segmentSize: Int = 4 * 1024,
            receiveChunking: Chunking = .unlimited,
            capturesSentBytes: Bool = true,
            info: ConnectionInfo = ConnectionInfo(
                localAddress: TransportAddress(host: "127.0.0.1", port: 8080),
                remoteAddress: TransportAddress(host: "127.0.0.1", port: 50000))
        ) {
            precondition(bufferCapacity > 0 && segmentSize > 0)
            if case .fixed(let n) = receiveChunking { precondition(n > 0, "chunk size must be positive") }
            if case .pattern(let sizes) = receiveChunking {
                precondition(!sizes.isEmpty && sizes.allSatisfy { $0 > 0 }, "chunk sizes must be positive")
            }
            self.bufferCapacity = bufferCapacity
            self.segmentSize = segmentSize
            self.receiveChunking = receiveChunking
            self.capturesSentBytes = capturesSentBytes
            self.info = info
        }

        /// Queue slots in the pipe.
        var queueCapacity: Int { max(1, bufferCapacity / segmentSize) }

        /// Upper bound on bytes a pipe read by this endpoint holds at once: a full queue, the
        /// segment the receiver is consuming, and the segment one suspended sender is offering.
        public var bufferBound: Int { (queueCapacity + 2) * segmentSize }
    }

    // MARK: Pipe

    /// One direction of traffic. Byte accounting counts a segment from the moment a sender
    /// offers it until the receiver has delivered its last byte, so it over-approximates what
    /// is held and the high-water mark is a safe upper bound.
    final class Pipe: Sendable {
        struct State {
            var script: [Event] = []
            var scriptIndex = 0
            var bufferedBytes = 0
            var highWater = 0
            var readerClosed = false
            var reset = false
        }

        /// `nil` for the outbound side of a scripted endpoint: sends are only captured.
        let queue: BoundedAsyncQueue<Event>?
        let state: Mutex<State>

        /// Largest `.bytes` event a sender puts into this pipe (the reader's segment size).
        let segmentSize: Int

        init(queueCapacity: Int?, segmentSize: Int, script: [Event] = []) {
            queue = queueCapacity.map { BoundedAsyncQueue(capacity: $0) }
            self.segmentSize = segmentSize
            var initial = State()
            initial.script = script
            state = Mutex(initial)
        }

        var isReset: Bool { state.withLock { $0.reset } }

        /// Offers one event to the reader, suspending while the pipe is full.
        func write(_ event: Event, byteCount: Int) async throws {
            // Checked before the scripted early return so an injected peer STOP_SENDING
            // (`InMemoryMultiplexedTransport`) also refuses captured-only sends.
            try state.withLock { state throws(TransportError) in
                if state.readerClosed || state.reset { throw .connectionReset }
                guard queue != nil else { return }
                state.bufferedBytes += byteCount
                state.highWater = max(state.highWater, state.bufferedBytes)
            }
            guard let queue else { return }
            do {
                try await queue.send(event)
            } catch {
                release(byteCount)
                if error is CancellationError { throw error }
                throw TransportError.connectionReset   // the queue was finished by a close
            }
        }

        /// The next event: script first, then the queue. `nil` once the queue is finished and
        /// drained, a scripted pipe is exhausted, or the calling task is cancelled.
        func next() async -> Event? {
            let scripted: Event? = state.withLock { state in
                guard state.scriptIndex < state.script.count else { return nil }
                defer { state.scriptIndex += 1 }
                return state.script[state.scriptIndex]
            }
            if let scripted { return scripted }
            return await queue?.next()
        }

        func release(_ byteCount: Int) {
            guard byteCount > 0 else { return }
            state.withLock { $0.bufferedBytes -= byteCount }
        }

        /// Finishes the queue and empties it, resuming any senders still waiting to be
        /// accepted. Never suspends: `next()` on a finished queue returns at once, so this does
        /// not compete with a receiver for the single consumer slot.
        func drainAsync() async {
            guard let queue else { return }
            queue.finish()
            while let event = await queue.next() {
                if case .bytes(let bytes) = event { release(bytes.readableBytes) }
            }
        }
    }

    // MARK: Endpoint state

    struct State {
        var closed = false
        var outputShutdown = false
        var receiving = false
        /// The segment being delivered; its unread bytes are still counted by the inbound pipe.
        var pending = ByteBuffer()
        var inputEnded = false
        var inputError: TransportError?
        var chunkIndex = 0
        var captured = ByteBuffer()
        var failNextSend: TransportError?
    }

    let inbound: Pipe
    let outbound: Pipe
    let configuration: Configuration
    let state = Mutex(State())

    public var info: ConnectionInfo { configuration.info }

    init(inbound: Pipe, outbound: Pipe, configuration: Configuration) {
        self.inbound = inbound
        self.outbound = outbound
        self.configuration = configuration
    }

    // MARK: Construction

    /// A connected pair. Each side's configuration sizes the pipe it reads from and its
    /// receive chunking.
    public static func makePair(
        client: Configuration = Configuration(),
        server: Configuration = Configuration()
    ) -> (client: InMemoryTransport, server: InMemoryTransport) {
        let toServer = Pipe(queueCapacity: server.queueCapacity, segmentSize: server.segmentSize)
        let toClient = Pipe(queueCapacity: client.queueCapacity, segmentSize: client.segmentSize)
        return (
            InMemoryTransport(inbound: toClient, outbound: toServer, configuration: client),
            InMemoryTransport(inbound: toServer, outbound: toClient, configuration: server)
        )
    }

    /// An endpoint whose inbound traffic is `script`; after the script, receives return 0.
    /// Sent bytes are captured in ``sentBytes`` and never suspend.
    public static func scripted(
        _ script: [Event],
        configuration: Configuration = Configuration()
    ) -> InMemoryTransport {
        InMemoryTransport(
            inbound: Pipe(queueCapacity: nil, segmentSize: configuration.segmentSize, script: script),
            outbound: Pipe(queueCapacity: nil, segmentSize: configuration.segmentSize),
            configuration: configuration)
    }

    /// Convenience: a scripted endpoint that receives `bytes` and then end of stream.
    public static func scripted(
        _ bytes: ByteBuffer,
        configuration: Configuration = Configuration()
    ) -> InMemoryTransport {
        scripted([.bytes(bytes), .endOfStream], configuration: configuration)
    }

    // MARK: Inspection and injection

    /// Every byte this endpoint's sends have had accepted, in order.
    public var sentBytes: ByteBuffer { state.withLock { $0.captured } }

    /// Bytes currently held by the pipe this endpoint reads from.
    public var inboundBufferedBytes: Int { inbound.state.withLock { $0.bufferedBytes } }

    /// The most bytes the pipe this endpoint reads from has held at once. Never exceeds
    /// ``Configuration/bufferBound``.
    public var inboundHighWaterMark: Int { inbound.state.withLock { $0.highWater } }

    /// Senders suspended on the pipe this endpoint reads from (for backpressure tests).
    public var suspendedPeerSenders: Int { inbound.queue?.suspendedProducerCount ?? 0 }

    /// True after ``close(_:)``.
    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Makes the next ``send(_:endOfStream:)`` throw `error` without sending anything.
    public func failNextSend(with error: TransportError) {
        state.withLock { $0.failNextSend = error }
    }

    /// Sends `events` to the peer in order with backpressure: bytes are sent (and captured) as
    /// by ``send(_:endOfStream:)``; delays and errors are delivered to the peer's receive in
    /// sequence; ``Event/endOfStream`` shuts down this side's output.
    public func play(_ events: [Event]) async throws {
        for event in events {
            switch event {
            case .bytes(let bytes):
                try await send(bytes, endOfStream: false)
            case .endOfStream:
                try await send(ByteBuffer(), endOfStream: true)
            case .delay, .error:
                try checkCanSend()
                try await outbound.write(event, byteCount: 0)
            }
        }
    }

    // MARK: ByteStreamTransport

    public func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        try state.withLock { state throws(TransportError) in
            if state.closed { throw .closed }
            if state.receiving { throw .receiveAlreadyPending }
            state.receiving = true
        }
        defer { state.withLock { $0.receiving = false } }

        while true {
            try Task.checkCancellation()
            // A local close takes precedence over a peer reset.
            try state.withLock { state throws(TransportError) in if state.closed { throw .closed } }
            if inbound.isReset { throw TransportError.connectionReset }
            // Deliver from the current segment, or report a sticky end or error.
            let delivered: Int? = try state.withLock { state throws(TransportError) -> Int? in
                if state.closed { throw .closed }
                let available = state.pending.readableBytes
                if available > 0 {
                    let limit = configuration.receiveChunking.limit(at: state.chunkIndex)
                    let count = min(maxLength, available, limit)
                    state.chunkIndex &+= 1
                    buffer.append(ByteView(offset: state.pending.readerIndex, length: count), from: state.pending)
                    state.pending.moveReaderIndex(forwardBy: count)
                    if state.pending.isEmpty { state.pending.clear() }
                    return count
                }
                if let error = state.inputError { throw error }
                if state.inputEnded { return 0 }
                return nil
            }
            if let delivered {
                inbound.release(delivered)
                return delivered
            }

            guard let event = await inbound.next() else {
                try Task.checkCancellation()
                try state.withLock { state throws(TransportError) in if state.closed { throw .closed } }
                if inbound.isReset { throw TransportError.connectionReset }
                state.withLock { state in
                    state.inputEnded = true   // peer closed gracefully, or the script ended
                }
                return 0
            }
            switch event {
            case .bytes(let bytes):
                state.withLock { $0.pending = bytes }
            case .delay(let duration):
                try await Task.sleep(for: duration)
            case .endOfStream:
                state.withLock { $0.inputEnded = true }
            case .error(let error):
                state.withLock { $0.inputError = error }
            }
        }
    }

    public func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try checkCanSend(claimingEndOfStream: endOfStream)
        let segmentSize = outbound.segmentSize
        let capture = configuration.capturesSentBytes
        var remaining = bytes
        while !remaining.isEmpty {
            let count = min(segmentSize, remaining.readableBytes)
            var segment = ByteBuffer(capacity: count)
            segment.append(ByteView(offset: remaining.readerIndex, length: count), from: remaining)
            remaining.moveReaderIndex(forwardBy: count)
            try await outbound.write(.bytes(segment), byteCount: count)
            if capture {
                state.withLock { $0.captured.append(segment) }
            }
        }
        if endOfStream {
            try await outbound.write(.endOfStream, byteCount: 0)
        }
    }

    public func close(_ reason: CloseReason) async {
        let wasClosed = state.withLock { state in
            defer { state.closed = true }
            return state.closed
        }
        guard !wasClosed else { return }
        if reason.isAbortive {
            outbound.state.withLock { $0.reset = true }
            await outbound.drainAsync()
        } else {
            outbound.queue?.finish()   // the peer drains what was accepted, then sees EOF
        }
        inbound.state.withLock { $0.readerClosed = true }
        await inbound.drainAsync()
        let pending = state.withLock { state in
            defer { state.pending = ByteBuffer() }
            return state.pending.readableBytes
        }
        inbound.release(pending)
    }

    private func checkCanSend(claimingEndOfStream: Bool = false) throws(TransportError) {
        try state.withLock { state throws(TransportError) in
            if state.closed { throw .closed }
            if state.outputShutdown { throw .outputShutdown }
            if let error = state.failNextSend {
                state.failNextSend = nil
                throw error
            }
            if claimingEndOfStream { state.outputShutdown = true }
        }
    }
}
