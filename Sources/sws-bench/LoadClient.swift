import Dispatch
import Foundation
import Network
import Synchronization

/// One HTTP/1.1 client connection on `NWConnection`, wrapped in async functions.
///
/// Network.framework requires a dispatch queue; each worker passes its own
/// serial queue so workers do not serialize behind one another. Cancelling the
/// awaiting task cancels the connection, which completes any pending operation.
final class LoadConnection: Sendable {
    enum Failure: Error, Sendable {
        case connect(String)
        case send(String)
        case receive(String)
        case cancelled
    }

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(host: String, port: UInt16, queue: DispatchQueue) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            // Skips path evaluation of other interfaces; also keeps the client on loopback.
            parameters.requiredInterfaceType = .loopback
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters)
        self.queue = queue
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let once = ResumeOnce()
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        connection.cancel()
                        if once.claim() { continuation.resume(throwing: Failure.connect("\(error)")) }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: Failure.cancelled) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: Failure.send("\(error)"))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Returns received bytes (possibly empty) and whether the peer finished sending.
    func receive() async throws -> (Data, isComplete: Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, isComplete: Bool), any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: Failure.receive("\(error)"))
                    } else {
                        continuation.resume(returning: (data ?? Data(), isComplete))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// Lets exactly one of several callbacks resume a continuation.
private final class ResumeOnce: Sendable {
    private let claimed = Atomic<Bool>(false)

    func claim() -> Bool {
        !claimed.exchange(true, ordering: .acquiringAndReleasing)
    }
}

struct LoadOptions: Sendable {
    var host = "127.0.0.1"
    var port: UInt16 = 8080
    var path = "/"
    var connections = 16
    var duration = 10.0
    var keepAlive = true
    /// Extra time after `duration` for in-flight requests before they count as timeouts.
    var grace = 5.0
}

/// Per-worker tallies, merged after the run.
struct WorkerStats: Sendable {
    var latencies: [Double] = []
    var requests = 0
    var bodyBytes = 0
    var connectionsOpened = 0
    var staleRetries = 0
    var statusCounts: [Int: Int] = [:]
    var errors: [String: Int] = [:]

    mutating func merge(_ other: WorkerStats) {
        latencies += other.latencies
        requests += other.requests
        bodyBytes += other.bodyBytes
        connectionsOpened += other.connectionsOpened
        staleRetries += other.staleRetries
        statusCounts.merge(other.statusCounts, uniquingKeysWith: +)
        errors.merge(other.errors, uniquingKeysWith: +)
    }
}

struct LoadResult: Codable, Sendable {
    struct Latency: Codable, Sendable {
        var p50: Double
        var p90: Double
        var p99: Double
        var max: Double
        var mean: Double
    }

    var url: String
    var connections: Int
    var keepAlive: Bool
    var durationSeconds: Double
    var requests: Int
    var requestsPerSecond: Double
    var bodyMegabytesPerSecond: Double
    /// Milliseconds, measured from first byte of the request (including connect
    /// when a new connection is opened) to the last byte of the response.
    var latencyMilliseconds: Latency?
    var errors: Int
    var errorsByKind: [String: Int]
    var statusCounts: [String: Int]
    var connectionsOpened: Int
    var staleConnectionRetries: Int
}

enum LoadRunner {
    static func run(_ options: LoadOptions) async -> LoadResult {
        var request = "GET \(options.path) HTTP/1.1\r\nHost: \(options.host):\(options.port)\r\n"
            + "User-Agent: sws-bench\r\nAccept: */*\r\n"
        if !options.keepAlive { request += "Connection: close\r\n" }
        request += "\r\n"
        let requestData = Data(request.utf8)

        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + .milliseconds(Int(options.duration * 1000))
        let hardStop = deadline + .milliseconds(Int(options.grace * 1000))

        var total = WorkerStats()
        await withTaskGroup(of: WorkerStats?.self) { group in
            for index in 0..<options.connections {
                group.addTask {
                    await worker(index: index, options: options, request: requestData, deadline: deadline)
                }
            }
            // Watchdog: cancel stuck workers once the grace period ends.
            group.addTask {
                try? await Task.sleep(until: hardStop, clock: clock)
                return nil
            }
            var finished = 0
            for await stats in group {
                guard let stats else {
                    group.cancelAll() // watchdog fired (or was cancelled after all workers finished)
                    continue
                }
                total.merge(stats)
                finished += 1
                if finished == options.connections { group.cancelAll() }
            }
        }
        let elapsed = Stats.nanoseconds(clock.now - start) / 1e9
        return makeResult(total, options: options, elapsed: elapsed)
    }

    private static func worker(index: Int, options: LoadOptions, request: Data, deadline: ContinuousClock.Instant) async -> WorkerStats {
        let clock = ContinuousClock()
        var stats = WorkerStats()
        stats.latencies.reserveCapacity(100_000)
        var connection: LoadConnection?
        var framer = ResponseFramer()
        var reused = false
        let queue = DispatchQueue(label: "sws-bench.worker.\(index)")

        while clock.now < deadline && !Task.isCancelled {
            let started = clock.now
            var attempt = 0
            while true {
                attempt += 1
                do {
                    if connection == nil {
                        let fresh = LoadConnection(host: options.host, port: options.port, queue: queue)
                        connection = fresh
                        reused = false
                        try await fresh.start()
                        stats.connectionsOpened += 1
                    }
                    guard let active = connection else { break }
                    try await active.send(request)
                    framer.reset()
                    let response = try await readResponse(active, framer: &framer)
                    let latency = Stats.nanoseconds(clock.now - started)
                    stats.latencies.append(latency)
                    stats.requests += 1
                    stats.bodyBytes += response.bodyBytes
                    stats.statusCounts[response.status, default: 0] += 1
                    if options.keepAlive && response.keepAlive {
                        reused = true
                    } else {
                        active.cancel()
                        connection = nil
                    }
                    break
                } catch {
                    connection?.cancel()
                    connection = nil
                    if Task.isCancelled {
                        stats.errors["timeout", default: 0] += 1
                        break
                    }
                    // A kept-alive connection the server already closed: retry once on a new one,
                    // as HTTP clients do for idempotent requests.
                    if reused, attempt == 1, case ResponseFramer.Failure.closedBeforeResponse = error {
                        stats.staleRetries += 1
                        continue
                    }
                    stats.errors[errorKind(error), default: 0] += 1
                    if case LoadConnection.Failure.connect = error {
                        try? await Task.sleep(for: .milliseconds(10)) // avoid spinning on refused connects
                    }
                    break
                }
            }
        }
        connection?.cancel()
        return stats
    }

    private static func readResponse(_ connection: LoadConnection, framer: inout ResponseFramer) async throws -> ResponseFramer.Response {
        while true {
            let (data, isComplete) = try await connection.receive()
            if !data.isEmpty {
                let (event, consumed) = data.withUnsafeBytes { framer.consume($0) }
                switch event {
                case .complete(let response):
                    if consumed < data.count { throw ResponseFramer.Failure.unsolicitedBytes }
                    return response
                case .invalid(let failure):
                    throw failure
                case .needMore:
                    break
                }
            }
            if isComplete {
                switch framer.finish() {
                case .complete(let response): return response
                case .invalid(let failure): throw failure
                case .needMore: throw ResponseFramer.Failure.unexpectedEOF
                }
            }
        }
    }

    private static func errorKind(_ error: any Error) -> String {
        switch error {
        case LoadConnection.Failure.connect: "connect"
        case LoadConnection.Failure.send: "send"
        case LoadConnection.Failure.receive: "receive"
        case LoadConnection.Failure.cancelled: "cancelled"
        case let failure as ResponseFramer.Failure: "protocol.\(failure)"
        default: "other"
        }
    }

    private static func makeResult(_ stats: WorkerStats, options: LoadOptions, elapsed: Double) -> LoadResult {
        let latency = Summary(stats.latencies).map {
            LoadResult.Latency(p50: $0.median / 1e6, p90: $0.p90 / 1e6, p99: $0.p99 / 1e6, max: $0.max / 1e6, mean: $0.mean / 1e6)
        }
        var statusCounts: [String: Int] = [:]
        for (status, count) in stats.statusCounts { statusCounts[String(status)] = count }
        return LoadResult(
            url: "http://\(options.host):\(options.port)\(options.path)",
            connections: options.connections,
            keepAlive: options.keepAlive,
            durationSeconds: elapsed,
            requests: stats.requests,
            requestsPerSecond: elapsed > 0 ? Double(stats.requests) / elapsed : 0,
            bodyMegabytesPerSecond: elapsed > 0 ? Double(stats.bodyBytes) / elapsed / 1_048_576 : 0,
            latencyMilliseconds: latency,
            errors: stats.errors.values.reduce(0, +),
            errorsByKind: stats.errors,
            statusCounts: statusCounts,
            connectionsOpened: stats.connectionsOpened,
            staleConnectionRetries: stats.staleRetries)
    }
}
