import Testing
import HTTPCore

/// Yields until `condition` holds (bounded by the suite's time limit).
private func waitUntil(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

@Suite(.timeLimit(.minutes(1))) struct BoundedAsyncQueueTests {
    @Test func deliversInFIFOOrderWithinCapacity() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 4)
        for i in 0..<4 { try await queue.send(i) }
        #expect(queue.bufferedCount == 4)
        #expect(queue.suspendedProducerCount == 0)
        var received: [Int] = []
        for _ in 0..<4 { received.append(await queue.next()!) }
        #expect(received == [0, 1, 2, 3])
        #expect(queue.bufferedCount == 0)
    }

    @Test func producerSuspendsAtCapacityAndResumesWhenConsumerReads() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        try await queue.send(1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await queue.send(2) }
            await waitUntil { queue.suspendedProducerCount == 1 }
            #expect(queue.bufferedCount == 1)
            #expect(await queue.next() == 1)
            // Reading moved the suspended producer's element into the buffer and resumed it.
            try await group.next()
            #expect(queue.suspendedProducerCount == 0)
            #expect(queue.bufferedCount == 1)
            #expect(await queue.next() == 2)
        }
    }

    @Test func cancellingSuspendedProducerRemovesItsWaiter() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        try await queue.send(1)
        let producer = Task { try await queue.send(99) }
        await waitUntil { queue.suspendedProducerCount == 1 }
        producer.cancel()
        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(queue.suspendedProducerCount == 0)
        #expect(await queue.next() == 1)
        queue.finish()
        #expect(await queue.next() == nil)   // the cancelled element was dropped
    }

    @Test func sendFromCancelledTaskThrowsWithoutEnqueueing() async {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        let producer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await queue.send(1)
        }
        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(queue.bufferedCount == 0)
    }

    @Test func consumerWaitsForProducerHandOff() async throws {
        let queue = BoundedAsyncQueue<String>(capacity: 2)
        async let received = queue.next()
        try await Task.sleep(for: .milliseconds(10))
        try await queue.send("hello")
        #expect(await received == "hello")
        #expect(queue.bufferedCount == 0)
    }

    @Test func cancellingWaitingConsumerReturnsNil() async {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        let consumer = Task { await queue.next() }
        try? await Task.sleep(for: .milliseconds(10))
        consumer.cancel()
        #expect(await consumer.value == nil)
    }

    @Test func finishDrainsThenEndsAndRejectsSends() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 2)
        try await queue.send(1)
        try await queue.send(2)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await queue.send(3) }   // suspended before finish
            await waitUntil { queue.suspendedProducerCount == 1 }
            queue.finish()
            await #expect(throws: BoundedAsyncQueueFinishedError.self) { try await queue.send(4) }
            var received: [Int] = []
            for await value in queue { received.append(value) }
            #expect(received == [1, 2, 3])
            try await group.waitForAll()
        }
    }

    @Test func finishWakesWaitingConsumer() async {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        async let received = queue.next()
        try? await Task.sleep(for: .milliseconds(10))
        queue.finish()
        #expect(await received == nil)
    }

    @Test func manyProducersOneConsumerDeliversEverything() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 3)
        let producers = 8, perProducer = 200
        try await withThrowingTaskGroup(of: Void.self) { group in
            for p in 0..<producers {
                group.addTask {
                    for i in 0..<perProducer { try await queue.send(p * perProducer + i) }
                }
            }
            var received: [Int] = []
            for _ in 0..<(producers * perProducer) { received.append(await queue.next()!) }
            try await group.waitForAll()
            #expect(received.sorted() == Array(0..<(producers * perProducer)))
            // Each producer's own elements stay in order.
            for p in 0..<producers {
                let mine = received.filter { $0 / perProducer == p }
                #expect(mine == mine.sorted())
            }
        }
        #expect(queue.bufferedCount == 0)
    }

    @Test func carriesByteBuffers() async throws {
        let queue = BoundedAsyncQueue<ByteBuffer>(capacity: 1)
        try await queue.send(ByteBuffer("chunk"))
        #expect(await queue.next() == ByteBuffer("chunk"))
    }

    /// `trySend` never suspends: it accepts while there is room, hands off to a waiting
    /// consumer, and refuses when full or finished (#0090).
    @Test func trySendAcceptsHandsOffAndRefuses() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 2)
        #expect(queue.trySend(1))
        #expect(queue.trySend(2))
        #expect(!queue.trySend(3))
        #expect(queue.bufferedCount == 2)
        #expect(await queue.next() == 1)
        #expect(await queue.next() == 2)

        // Delivered whether the consumer is already waiting (hand-off) or not yet (buffered).
        async let waiting = queue.next()
        for _ in 0..<10 { await Task.yield() }
        #expect(queue.trySend(4))
        #expect(await waiting == 4)

        queue.finish()
        #expect(!queue.trySend(5))
        #expect(await queue.next() == nil)
    }
}

@Suite struct DeadlineTests {
    @Test func expiryAndRemaining() {
        let now = ContinuousClock.now
        let deadline = Deadline.after(.seconds(5), now: now)
        #expect(!deadline.hasExpired(now: now))
        #expect(deadline.remaining(now: now) == .seconds(5))
        #expect(deadline.hasExpired(now: now.advanced(by: .seconds(5))))
        #expect(deadline.remaining(now: now.advanced(by: .seconds(6))) == .zero)
        #expect(Deadline.after(.zero, now: now).hasExpired(now: now))
    }

    @Test func neverExpiresAndSortsLast() {
        let now = ContinuousClock.now
        let finite = Deadline(now)
        #expect(!Deadline.never.hasExpired(now: now.advanced(by: .seconds(1_000_000))))
        #expect(Deadline.never.remaining(now: now) == nil)
        #expect(finite < .never)
        #expect(!(Deadline.never < finite))
        #expect(!(Deadline.never < .never))
        #expect(finite.earliest(.never) == finite)
        #expect(Deadline.never.earliest(finite) == finite)
        let later = Deadline.after(.seconds(1), now: now)
        #expect(later.earliest(finite) == finite)
    }
}
