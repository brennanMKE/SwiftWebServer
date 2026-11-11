import HTTPCore
import NetworkTransport

/// Loopback benchmarks for the Network.framework TCP adapter (issue #0078, ROADMAP §7 "known
/// floor"). Exposed only: not wired into a `sws-bench` command yet. Results and the
/// task-executor-preference experiment are in docs/notes/nw-transport.md.
///
/// Everything runs in this process on 127.0.0.1 port 0: a ``TCPListener`` server and a
/// ``TCPTransport`` client. Allocation counts are process-wide (both endpoints plus
/// Network.framework's own threads), so "per round trip" covers two sends and two receives.
enum TransportBench {
    struct Options: Sendable {
        /// Timed echo round trips of `payload` bytes.
        var roundTrips = 20_000
        /// Bytes per echo round trip and per send/receive in the per-call cases.
        var payload = 64
        /// Calls timed in the per-read and per-write cases.
        var perCallOperations = 50_000
        /// Bytes pushed through the echo throughput case.
        var echoBytes = 256 * 1024 * 1024
        /// Send and receive size for the throughput case.
        var chunkSize = 64 * 1024
        /// Runs client and server work with a task-executor preference for the connection's
        /// own queue (``TCPTransport/taskExecutor``).
        var useTaskExecutorPreference = false
    }

    struct Result: Sendable, CustomStringConvertible {
        var name: String
        var value: Double
        var unit: String
        var description: String { "\(name): \(formatted(value)) \(unit)" }
    }

    /// The first byte a client sends selects the server's behaviour for that connection.
    private enum Mode: UInt8 {
        case echo = 0x45      // "E": echo everything back
        case discard = 0x44   // "D": read and drop
        case flood = 0x46     // "F": send `UInt64` big-endian count of bytes, then stop
    }

    static func run(_ options: Options = Options()) async throws -> [Result] {
        let listener = try TCPListener()
        let port = try await listener.start()
        let prefer = options.useTaskExecutorPreference
        let suffix = prefer ? " [executor preference]" : ""

        return try await withThrowingTaskGroup(of: [Result].self) { group in
            group.addTask {
                try await serve(listener, preferExecutor: prefer, chunkSize: options.chunkSize)
                return []
            }
            var results: [Result] = []
            results += try await withClient(port: port, mode: .echo, prefer: prefer) {
                try await echoLatency($0, options: options, suffix: suffix)
            }
            results += try await withClient(port: port, mode: .echo, prefer: prefer) {
                try await echoThroughput($0, options: options, suffix: suffix)
            }
            results += try await withClient(port: port, mode: .discard, prefer: prefer) {
                try await perWrite($0, options: options, suffix: suffix)
            }
            results += try await withClient(port: port, mode: .flood, prefer: prefer) {
                try await perRead($0, options: options, suffix: suffix)
            }
            await listener.close()
            try await group.waitForAll()
            return results
        }
    }

    // MARK: Cases

    private static func echoLatency(_ client: TCPTransport, options: Options, suffix: String) async throws -> [Result] {
        var message = ByteBuffer(capacity: options.payload)
        for i in 0..<options.payload { message.append(UInt8(truncatingIfNeeded: i)) }
        var inbound = ByteBuffer(capacity: max(4096, options.payload))
        func roundTrip() async throws {
            try await client.send(message, endOfStream: false)
            inbound.clear()
            while inbound.readableBytes < options.payload {
                if try await client.receive(into: &inbound, maxLength: 4096) == 0 { throw TransportError.connectionReset }
            }
        }
        for _ in 0..<1_000 { try await roundTrip() }   // warm up

        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(options.roundTrips)
        for _ in 0..<options.roundTrips {
            let start = clock.now
            try await roundTrip()
            samples.append(Stats.nanoseconds(start.duration(to: clock.now)))
        }
        samples.sort()
        let allocationRounds = min(options.roundTrips, 5_000)
        let allocations = try await AllocationCounter.countAsync {
            for _ in 0..<allocationRounds { try await roundTrip() }
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        var results = [
            Result(name: "echo \(options.payload) B round trip p50\(suffix)", value: Stats.percentile(sorted: samples, 50) / 1000, unit: "µs"),
            Result(name: "echo \(options.payload) B round trip p99\(suffix)", value: Stats.percentile(sorted: samples, 99) / 1000, unit: "µs"),
            Result(name: "echo \(options.payload) B round trip mean\(suffix)", value: mean / 1000, unit: "µs"),
        ]
        if let allocations {
            results.append(Result(
                name: "echo round trip allocations (both ends + NW)\(suffix)",
                value: Double(allocations) / Double(allocationRounds), unit: "allocs/round trip"))
        }
        return results
    }

    private static func echoThroughput(_ client: TCPTransport, options: Options, suffix: String) async throws -> [Result] {
        var chunk = ByteBuffer(capacity: options.chunkSize)
        for i in 0..<options.chunkSize { chunk.append(UInt8(truncatingIfNeeded: i &* 7)) }
        let payload = chunk
        let total = options.echoBytes - options.echoBytes % options.chunkSize
        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var sent = 0
                while sent < total {
                    try await client.send(payload, endOfStream: false)
                    sent += payload.readableBytes
                }
            }
            var inbound = ByteBuffer(capacity: options.chunkSize)
            var received = 0
            while received < total {
                inbound.clear()
                let n = try await client.receive(into: &inbound, maxLength: options.chunkSize)
                if n == 0 { throw TransportError.connectionReset }
                received += n
            }
            try await group.waitForAll()
        }
        let seconds = Stats.nanoseconds(start.duration(to: clock.now)) / 1e9
        return [Result(
            name: "echo throughput, \(options.chunkSize / 1024) KiB sends\(suffix)",
            value: Double(total) / seconds / 1_048_576, unit: "MiB/s each way")]
    }

    private static func perWrite(_ client: TCPTransport, options: Options, suffix: String) async throws -> [Result] {
        var message = ByteBuffer(capacity: options.payload)
        for i in 0..<options.payload { message.append(UInt8(truncatingIfNeeded: i)) }
        for _ in 0..<1_000 { try await client.send(message, endOfStream: false) }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<options.perCallOperations { try await client.send(message, endOfStream: false) }
        let ns = Stats.nanoseconds(start.duration(to: clock.now)) / Double(options.perCallOperations)
        let rounds = min(options.perCallOperations, 10_000)
        let allocations = try await AllocationCounter.countAsync {
            for _ in 0..<rounds { try await client.send(message, endOfStream: false) }
        }
        var results = [Result(name: "send \(options.payload) B (until .contentProcessed)\(suffix)", value: ns, unit: "ns/call")]
        if let allocations {
            results.append(Result(
                name: "send \(options.payload) B allocations (incl. server reads)\(suffix)",
                value: Double(allocations) / Double(rounds), unit: "allocs/call"))
        }
        return results
    }

    private static func perRead(_ client: TCPTransport, options: Options, suffix: String) async throws -> [Result] {
        let warmup = 1_000
        let rounds = min(options.perCallOperations, 10_000)
        let reads = warmup + options.perCallOperations + rounds
        var request = ByteBuffer()
        request.append(bigEndian: UInt64(reads * options.payload))
        try await client.send(request, endOfStream: false)
        var inbound = ByteBuffer(capacity: options.payload)
        func readOne() async throws {
            inbound.clear()
            var got = 0
            while got < options.payload {
                let n = try await client.receive(into: &inbound, maxLength: options.payload - got)
                if n == 0 { throw TransportError.connectionReset }
                got += n
            }
        }
        for _ in 0..<warmup { try await readOne() }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<options.perCallOperations { try await readOne() }
        let ns = Stats.nanoseconds(start.duration(to: clock.now)) / Double(options.perCallOperations)
        let allocations = try await AllocationCounter.countAsync {
            for _ in 0..<rounds { try await readOne() }
        }
        var results = [Result(name: "receive \(options.payload) B (data already buffered)\(suffix)", value: ns, unit: "ns/call")]
        if let allocations {
            results.append(Result(
                name: "receive \(options.payload) B allocations (incl. server sends)\(suffix)",
                value: Double(allocations) / Double(rounds), unit: "allocs/call"))
        }
        return results
    }

    // MARK: Plumbing

    private static func withClient(
        port: UInt16, mode: Mode, prefer: Bool,
        _ body: @Sendable (TCPTransport) async throws -> [Result]
    ) async throws -> [Result] {
        let client = try await TCPTransport.connect(host: "127.0.0.1", port: port)
        var hello = ByteBuffer()
        hello.append(mode.rawValue)
        try await client.send(hello, endOfStream: false)
        let results: [Result]
        if prefer {
            results = try await withTaskExecutorPreference(client.taskExecutor) { try await body(client) }
        } else {
            results = try await body(client)
        }
        await client.close(.normal)
        return results
    }

    /// Accepts connections until the listener closes and serves each in a child task.
    private static func serve(_ listener: TCPListener, preferExecutor: Bool, chunkSize: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await connection in listener.connections {
                let executor: (any TaskExecutor)? = preferExecutor ? connection.taskExecutor : nil
                group.addTask(executorPreference: executor) {
                    do { try await handle(connection, chunkSize: chunkSize) } catch {}
                    await connection.close(.normal)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func handle(_ connection: TCPTransport, chunkSize: Int) async throws {
        var buffer = ByteBuffer(capacity: chunkSize)
        guard try await connection.receive(into: &buffer, maxLength: 1) == 1,
              let mode = Mode(rawValue: buffer.readInteger(as: UInt8.self)!) else { return }
        switch mode {
        case .echo:
            while true {
                buffer.clear()
                if try await connection.receive(into: &buffer, maxLength: chunkSize) == 0 { return }
                try await connection.send(buffer, endOfStream: false)
            }
        case .discard:
            while true {
                buffer.clear()
                if try await connection.receive(into: &buffer, maxLength: chunkSize) == 0 { return }
            }
        case .flood:
            buffer.clear()
            while buffer.readableBytes < 8 {
                if try await connection.receive(into: &buffer, maxLength: 8 - buffer.readableBytes) == 0 { return }
            }
            var remaining = Int(buffer.readInteger(as: UInt64.self)!)
            var chunk = ByteBuffer(capacity: chunkSize)
            for i in 0..<chunkSize { chunk.append(UInt8(truncatingIfNeeded: i)) }
            while remaining > 0 {
                let count = min(remaining, chunkSize)
                if count < chunkSize {
                    var last = ByteBuffer(capacity: count)
                    last.append(ByteView(offset: chunk.readerIndex, length: count), from: chunk)
                    try await connection.send(last, endOfStream: false)
                } else {
                    try await connection.send(chunk, endOfStream: false)
                }
                remaining -= count
            }
            // Hold the connection until the client closes.
            buffer.clear()
            _ = try await connection.receive(into: &buffer, maxLength: 1)
        }
    }

    private static func formatted(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return "\(rounded)"
    }
}
