@testable import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0107: RFC 9218 priorities for HTTP/3. PRIORITY_UPDATE frames on the control stream, the
/// per-stream priority table, and the send budget serving waiting sends by priority.
@Suite(.timeLimit(.minutes(1)))
struct H3PriorityTests {
    static let control = H3FrameParser.Configuration(streamKind: .control, role: .server)
    static let request = H3FrameParser.Configuration(streamKind: .request, role: .server)

    static func update(_ id: UInt64, _ value: String, push: Bool = false) -> [UInt8] {
        H3Wire.frame(push ? .priorityUpdatePush : .priorityUpdateRequest, H3Wire.varint(id) + Array(value.utf8))
    }

    // MARK: Frames

    @Test func parserReadsPriorityUpdateOnControlStream() {
        let bytes = H3Wire.settings() + Self.update(8, "u=1, i") + Self.update(3, "u=2", push: true)
        for chunks in everySplit(of: bytes) {
            let frames = parse(chunks, configuration: Self.control).frames
            #expect(frames.dropFirst() == [
                .priorityUpdate(push: false, 8, Array("u=1, i".utf8)), .priorityUpdate(push: true, 3, Array("u=2".utf8)),
            ])
        }
    }

    @Test func parserRejectsPriorityUpdateElsewhereOrMalformed() {
        // On a request stream: H3_FRAME_UNEXPECTED (RFC 9218 §7.2).
        #expect(parse([H3Wire.headers(H3Wire.request()) + Self.update(0, "u=1")], configuration: Self.request).frames.last
                == .error(.frameUnexpected))
        // No element ID.
        #expect(parse([H3Wire.settings() + H3Wire.frame(.priorityUpdateRequest, [])], configuration: Self.control).frames.last
                == .error(.frameError))
        // Far longer than a priority field.
        let long = H3Wire.frame(.priorityUpdateRequest, [0] + Array(repeating: 0x20, count: H3FrameParser.maxPriorityUpdateLength))
        #expect(parse([H3Wire.settings() + long], configuration: Self.control).frames.last == .error(.excessiveLoad))
    }

    // MARK: Priority table

    @Test func updatesBeforeAndAfterOpen() {
        let table = H3Priorities(maxEarly: 4)
        Array("u=1".utf8).withUnsafeBytes { table.update(8, field: $0) }
        #expect(table.earlyCount == 1)
        let cell = table.open(8, requested: HTTPPriority(urgency: 6))
        // The update that arrived first wins over the request's field.
        #expect(cell.value == HTTPPriority(urgency: 1))
        #expect(table.earlyCount == 0)
        Array("u=4, i".utf8).withUnsafeBytes { table.update(8, field: $0) }
        #expect(cell.value == HTTPPriority(urgency: 4, incremental: true))
        // The handler's response field merges on top.
        var fields = HTTPFields()
        fields.append(.priority, "u=0")
        cell.apply(from: fields)
        #expect(cell.value == HTTPPriority(urgency: 0, incremental: true))
        // After close: ignored, not kept.
        table.close(8)
        Array("u=2".utf8).withUnsafeBytes { table.update(8, field: $0) }
        Array("u=2".utf8).withUnsafeBytes { table.update(4, field: $0) }
        #expect(table.earlyCount == 0)
        // Invalid values are ignored; the early buffer is bounded.
        Array("u=2,".utf8).withUnsafeBytes { table.update(100, field: $0) }
        #expect(table.earlyCount == 0)
        for id in stride(from: UInt64(200), to: 300, by: 4) {
            Array("u=2".utf8).withUnsafeBytes { table.update(id, field: $0) }
        }
        #expect(table.earlyCount == 4)
    }

    // MARK: Send budget

    /// Waits until `condition` holds, polling briefly.
    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    /// Sends waiting for an exhausted budget are served lower urgency first.
    @Test func budgetServesUrgentWaitersFirst() async throws {
        let budget = H3SendBudget(capacity: 100)
        let held = try await budget.acquire(100)
        let order = Mutex<[UInt64]>([])
        let streams: [(UInt64, HTTPPriority)] = [
            (0, HTTPPriority(urgency: 6)), (4, HTTPPriority(urgency: 0)), (8, .default), (12, HTTPPriority(urgency: 1)),
        ]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, (id, priority)) in streams.enumerated() {
                // Queue in this order.
                try await Self.eventually { budget.waiting == index }
                group.addTask {
                    let amount = try await budget.acquire(100, priority: H3StreamPriority(streamID: id, priority))
                    order.withLock { $0.append(id) }
                    budget.release(amount)
                }
            }
            try await Self.eventually { budget.waiting == streams.count }
            budget.release(held)
            try await group.waitForAll()
        }
        #expect(order.withLock { $0 } == [4, 12, 8, 0])
    }

    /// Incremental streams of one urgency take turns; each send queues behind the others.
    @Test func budgetInterleavesIncrementalStreams() async throws {
        let budget = H3SendBudget(capacity: 100)
        let held = try await budget.acquire(100)
        let order = Mutex<[UInt64]>([])
        let gate = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in [UInt64(0), 4].enumerated() {
                try await Self.eventually { budget.waiting == index }
                group.addTask {
                    let cell = H3StreamPriority(streamID: id, HTTPPriority(urgency: 2, incremental: true))
                    for _ in 0..<3 {
                        _ = try await budget.acquire(100, priority: cell)
                        order.withLock { $0.append(id) }
                        gate.withLock { $0 += 1 }
                    }
                }
            }
            try await Self.eventually { budget.waiting == 2 }
            budget.release(held)
            // Give the budget back one send at a time, once the sender queued again.
            for sent in 1..<6 {
                try await Self.eventually { gate.withLock { $0 } == sent && budget.waiting == (sent < 5 ? 2 : 1) }
                budget.release(100)
            }
            try await group.waitForAll()
        }
        #expect(order.withLock { $0 } == [0, 4, 0, 4, 0, 4])
    }

    /// Strict priority would starve the background stream: one grant in
    /// ``H3SendBudget/fairShareInterval`` goes to the oldest waiter.
    @Test func budgetKeepsAShareForLowPriority() async throws {
        let budget = H3SendBudget(capacity: 100)
        let held = try await budget.acquire(100)
        let background = H3StreamPriority(streamID: 0, HTTPPriority(urgency: 7))
        let urgent = H3StreamPriority(streamID: 4, HTTPPriority(urgency: 0, incremental: true))
        let order = Mutex<[UInt64]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await budget.acquire(100, priority: background)
                order.withLock { $0.append(0) }
            }
            try await Self.eventually { budget.waiting == 1 }
            // Many urgent sends, queued after the background one.
            for index in 0..<(2 * H3SendBudget.fairShareInterval) {
                group.addTask {
                    _ = try await budget.acquire(100, priority: urgent)
                    order.withLock { $0.append(4) }
                }
                try await Self.eventually { budget.waiting == index + 2 }
            }
            budget.release(held)
            for sent in 1...(2 * H3SendBudget.fairShareInterval) {
                try await Self.eventually { order.withLock { $0.count } == sent }
                budget.release(100)
            }
            try await group.waitForAll()
        }
        let position = try #require(order.withLock { $0 }.firstIndex(of: 0))
        #expect(position == H3SendBudget.fairShareInterval - 1, "\(order.withLock { $0 })")
    }

    // MARK: Connection

    @Test func priorityUpdatesOnControlStreamAreAccepted() async throws {
        try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            // Before stream 0 opens, and for a later stream.
            try await h3.openControlStream([0x00] + H3Wire.settings() + Self.update(0, "u=0") + Self.update(400, "u=7, i"))
            let response = try await h3.send(H3Wire.request(path: "/p", extra: [("priority", "u=5")]))
            #expect(response.status == "200")
            #expect(response.bodyString == "hello /p")
            #expect(!client.isClosed)
        }
    }

    @Test(arguments: [
        (UInt64(2), false),  // not a client-initiated bidirectional stream
        (UInt64(1), false),
        (UInt64(0), true),   // a push, but the client sent no MAX_PUSH_ID
    ])
    func badPriorityUpdateIDIsIDError(id: UInt64, push: Bool) async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openControlStream(
                [0x00] + H3Wire.settings() + Self.update(id, "u=1", push: push))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.idError.rawValue)
    }

    @Test func priorityUpdateOnRequestStreamIsFrameUnexpected() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            _ = try await h3.openRequest(H3Wire.headers(H3Wire.request()) + Self.update(0, "u=1"))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.frameUnexpected.rawValue)
    }
}
