import Synchronization

/// Thrown by ``BoundedAsyncQueue/send(_:)`` after ``BoundedAsyncQueue/finish()``.
public struct BoundedAsyncQueueFinishedError: Error, Sendable, Equatable {
    public init() {}
}

/// A fixed-capacity FIFO queue whose producers suspend when it is full (docs/ROADMAP.md §5.4).
///
/// Used for byte and frame flows where `AsyncStream` would buffer without bound. Many producers
/// may `send` concurrently; there is one consumer at a time (iterate it from a single task).
///
/// - A full queue suspends `send` until the consumer takes an element.
/// - Cancelling a suspended producer removes its waiter, drops its element, and makes `send`
///   throw `CancellationError`. Cancelling a suspended consumer makes `next()` return `nil`.
/// - `finish()` rejects further sends. Buffered elements and already-suspended producers'
///   elements are still delivered, then iteration ends.
///
/// State lives in a `Mutex` with non-suspending critical sections; continuations are resumed
/// after the lock is released.
public final class BoundedAsyncQueue<Element: Sendable>: Sendable, AsyncSequence {
    public typealias Failure = Never

    struct Producer {
        let id: UInt64
        let element: Element
        let continuation: CheckedContinuation<Void, any Error>
    }

    struct Consumer {
        let id: UInt64
        let continuation: CheckedContinuation<Element?, Never>
    }

    /// What `send` does after leaving the critical section.
    enum SendAction {
        case accepted
        case handOff(CheckedContinuation<Element?, Never>)
        case suspended
        case fail(any Error)
    }

    /// What `next` does after leaving the critical section.
    enum NextAction {
        case deliver(Element, resuming: CheckedContinuation<Void, any Error>?)
        case end
        case suspended
    }

    struct State {
        /// Ring buffer, preallocated to `capacity`, so steady-state traffic does not allocate.
        var ring: [Element?]
        var head = 0
        var count = 0
        var producers: [Producer] = []
        var consumer: Consumer?
        var finished = false
        var nextID: UInt64 = 0

        init(capacity: Int) {
            ring = Array(repeating: nil, count: capacity)
        }

        mutating func makeID() -> UInt64 {
            nextID &+= 1
            return nextID
        }

        mutating func push(_ element: Element) {
            assert(count < ring.count)
            var tail = head + count
            if tail >= ring.count { tail -= ring.count }
            ring[tail] = element
            count += 1
        }

        mutating func pop() -> Element {
            assert(count > 0)
            let element = ring[head].take()!
            head += 1
            if head == ring.count { head = 0 }
            count -= 1
            return element
        }
    }

    /// Maximum number of buffered elements.
    public let capacity: Int
    let state: Mutex<State>

    /// Creates a queue that buffers up to `capacity` elements (at least 1).
    public init(capacity: Int) {
        precondition(capacity >= 1, "BoundedAsyncQueue capacity must be at least 1")
        self.capacity = capacity
        self.state = Mutex(State(capacity: capacity))
    }

    /// Number of buffered elements (for tests and metrics).
    public var bufferedCount: Int { state.withLock { $0.count } }

    /// Number of producers suspended because the queue is full (for tests and metrics).
    public var suspendedProducerCount: Int { state.withLock { $0.producers.count } }

    // MARK: Producing

    /// Enqueues `element`, suspending while the queue is full.
    ///
    /// - Throws: `CancellationError` if the task is cancelled before the element is accepted
    ///   (the element is dropped), or ``BoundedAsyncQueueFinishedError`` after `finish()`.
    public func send(_ element: Element) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.makeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let action: SendAction = state.withLock { state in
                    if state.finished { return .fail(BoundedAsyncQueueFinishedError()) }
                    if let consumer = state.consumer {
                        // A waiting consumer implies an empty buffer: hand the element over directly.
                        assert(state.count == 0)
                        state.consumer = nil
                        return .handOff(consumer.continuation)
                    }
                    if state.count < state.ring.count {
                        state.push(element)
                        return .accepted
                    }
                    // Checked under the lock: if cancellation lands after this, the
                    // cancellation handler takes the lock afterwards and finds the waiter.
                    if Task.isCancelled { return .fail(CancellationError()) }
                    state.producers.append(Producer(id: id, element: element, continuation: continuation))
                    return .suspended
                }
                switch action {
                case .accepted:
                    continuation.resume()
                case .handOff(let consumer):
                    consumer.resume(returning: element)
                    continuation.resume()
                case .suspended:
                    break
                case .fail(let error):
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let producer: Producer? = state.withLock { state in
                guard let index = state.producers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.producers.remove(at: index)
            }
            producer?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Rejects further sends. Elements already buffered or held by suspended producers are
    /// still delivered; after them, iteration returns `nil`.
    public func finish() {
        let consumer: Consumer? = state.withLock { state in
            state.finished = true
            // A waiting consumer implies nothing is buffered or pending.
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.continuation.resume(returning: nil)
    }

    // MARK: Consuming

    /// Removes the next element, suspending while the queue is empty. Returns `nil` once the
    /// queue is finished and drained, or if the calling task is cancelled while waiting.
    public func next() async -> Element? {
        let id = state.withLock { $0.makeID() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                let action: NextAction = state.withLock { state in
                    if state.count > 0 {
                        let element = state.pop()
                        var resumed: CheckedContinuation<Void, any Error>?
                        if !state.producers.isEmpty {
                            let producer = state.producers.removeFirst()
                            state.push(producer.element)
                            resumed = producer.continuation
                        }
                        return .deliver(element, resuming: resumed)
                    }
                    if state.finished || Task.isCancelled { return .end }
                    precondition(state.consumer == nil, "BoundedAsyncQueue supports one consumer at a time")
                    state.consumer = Consumer(id: id, continuation: continuation)
                    return .suspended
                }
                switch action {
                case .deliver(let element, let producer):
                    producer?.resume()
                    continuation.resume(returning: element)
                case .end:
                    continuation.resume(returning: nil)
                case .suspended:
                    break
                }
            }
        } onCancel: {
            let consumer: Consumer? = state.withLock { state in
                guard let consumer = state.consumer, consumer.id == id else { return nil }
                state.consumer = nil
                return consumer
            }
            consumer?.continuation.resume(returning: nil)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let queue: BoundedAsyncQueue

        public mutating func next() async -> Element? {
            await queue.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(queue: self)
    }
}
