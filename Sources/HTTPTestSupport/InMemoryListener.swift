public import HTTPCore
import Synchronization

/// An in-memory ``TransportListener`` for server tests (#0079): ``connect(client:server:)``
/// creates an ``InMemoryTransport`` pair, queues the server side for ``connections`` and
/// returns the client side.
///
/// The pending queue is bounded by ``pendingLimit``, like `TCPListener`'s: a connection that
/// arrives while it is full is refused (the client sees end of stream) and counted in
/// ``refusedCount``. ``pendingCount`` shows connections the server has not pulled yet, so a
/// test can observe accept backpressure.
public final class InMemoryListener: TransportListener {
    public typealias Transport = InMemoryTransport

    private struct State {
        var listening = false
        var closed = false
        var pending: [InMemoryTransport] = []
        var consumer: CheckedContinuation<InMemoryTransport?, any Error>?
        var refused = 0
    }

    private let state = Mutex(State())
    /// Most connections queued before the server takes them.
    public let pendingLimit: Int
    /// The address ``listen()`` reports.
    public let address: TransportAddress
    private let failure: (any Error & Sendable)?

    /// - Parameters:
    ///   - failure: when set, ``listen()`` throws it (simulates a port already in use).
    public init(
        address: TransportAddress = TransportAddress(host: "memory", port: 1),
        pendingLimit: Int = 16,
        failure: (any Error & Sendable)? = nil
    ) {
        precondition(pendingLimit > 0, "pendingLimit must be positive")
        self.address = address
        self.pendingLimit = pendingLimit
        self.failure = failure
    }

    public func listen() async throws -> TransportAddress {
        if let failure { throw failure }
        try state.withLock { state throws(TransportError) in
            if state.closed { throw .closed }
            state.listening = true
        }
        return address
    }

    /// Opens a connection to the listener and returns the client end. If the listener is not
    /// listening, is closed, or its queue is full, the connection is refused: the server end
    /// is closed at once, so the client's first receive returns 0.
    public func connect(
        client: InMemoryTransport.Configuration = InMemoryTransport.Configuration(),
        server: InMemoryTransport.Configuration = InMemoryTransport.Configuration()
    ) async -> InMemoryTransport {
        let pair = InMemoryTransport.makePair(client: client, server: server)
        enum Outcome { case handOff(CheckedContinuation<InMemoryTransport?, any Error>), queued, refused }
        let outcome = state.withLock { state -> Outcome in
            guard state.listening, !state.closed else { state.refused += 1; return .refused }
            if let consumer = state.consumer {
                state.consumer = nil
                return .handOff(consumer)
            }
            guard state.pending.count < pendingLimit else { state.refused += 1; return .refused }
            state.pending.append(pair.server)
            return .queued
        }
        switch outcome {
        case .handOff(let consumer): consumer.resume(returning: pair.server)
        case .queued: break
        case .refused: await pair.server.close(.normal)
        }
        return pair.client
    }

    /// Connections queued and not yet taken by ``connections``.
    public var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Connections refused because the listener was full, closed, or not listening.
    public var refusedCount: Int { state.withLock { $0.refused } }

    /// True after ``close()``.
    public var isClosed: Bool { state.withLock { $0.closed } }

    public func close() async {
        let (pending, consumer) = state.withLock { state -> ([InMemoryTransport], CheckedContinuation<InMemoryTransport?, any Error>?) in
            state.closed = true
            defer { state.pending = []; state.consumer = nil }
            return (state.pending, state.consumer)
        }
        consumer?.resume(returning: nil)
        for transport in pending { await transport.close(.shutdown) }
    }

    public var connections: Connections { Connections(listener: self) }

    fileprivate func next() async throws -> InMemoryTransport? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InMemoryTransport?, any Error>) in
                let immediate = state.withLock { state -> Result<InMemoryTransport?, any Error>? in
                    if !state.pending.isEmpty { return .success(state.pending.removeFirst()) }
                    if state.closed { return .success(nil) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    precondition(state.consumer == nil, "InMemoryListener.connections: concurrent next() calls")
                    state.consumer = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let consumer = state.withLock { state in
                defer { state.consumer = nil }
                return state.consumer
            }
            consumer?.resume(throwing: CancellationError())
        }
    }

    /// Accepted connections; `next()` takes one or suspends.
    public struct Connections: AsyncSequence, Sendable {
        public typealias Element = InMemoryTransport
        public typealias Failure = any Error
        let listener: InMemoryListener

        public func makeAsyncIterator() -> Iterator { Iterator(listener: listener) }

        public struct Iterator: AsyncIteratorProtocol {
            public typealias Element = InMemoryTransport
            public typealias Failure = any Error
            let listener: InMemoryListener

            public mutating func next() async throws -> InMemoryTransport? {
                try await listener.next()
            }
        }
    }
}
