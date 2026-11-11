import Darwin
import Foundation
import HTTP1
import HTTPCore
import HTTPServer
@_spi(Benchmark) import NetworkTransport
import Synchronization

/// `sws-bench accept`: where the time goes for a new connection (#0113).
///
/// Runs the full server stack (``Server`` + HTTP/1.1 + ``HelloHandler``) in process over the
/// chosen transport, and drives it from `--concurrency` client threads using blocking BSD
/// sockets: each one connects, sends a `Connection: close` request, reads to end of stream and
/// closes. The client closes with `SO_LINGER` 0 (a reset after the server's FIN), so neither
/// side keeps the 4-tuple in `TIME_WAIT` and any number of connections fits in the ephemeral
/// port range.
///
/// Every connection gets a timeline on one clock (`CLOCK_UPTIME_RAW`), matched by the client's
/// source port:
///
/// | Phase | From | To |
/// |---|---|---|
/// | connect | client calls `connect` | `connect` returns (kernel handshake done) |
/// | handover | `connect` returns | the listener hands the connection over (NW `newConnectionHandler`, or `accept(2)`) |
/// | ready | handover | the transport is ready |
/// | taken | ready | the server's accept loop takes it from the listener |
/// | first read | taken | the first `receive` returns the request |
/// | respond | first read | the client sees the first response byte |
/// | close | first byte | the client sees end of stream |
///
/// Allocations are counted process-wide over the whole run (server, client threads, Network
/// framework) and divided by the number of connections.
enum AcceptBench {
    static let usage = """
        usage: sws-bench accept [--transport nw|bsd] [--connections N] [--concurrency N]
                                [--warmup N] [--rounds N] [--pause SECONDS] [--json]

          --transport T     nw (Network.framework TCPListener, default) or bsd (BSDSocketListener)
          --connections N   connections per round (default 5000)
          --concurrency N   client threads (default 16)
          --warmup N        untimed connections first (default 500)
          --rounds N        rounds; the median round is reported (default 3)
          --pause S         idle seconds before each round after the first (default 0)
        """

    static func run(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, valueOptions: ["transport", "connections", "concurrency", "warmup", "rounds", "pause"])
        if args.flag("help") == true { print(usage); return 0 }
        let kind = try TransportKind(argument: args.string("transport") ?? "nw")
        let connections = try args.int("connections") ?? 5000
        let concurrency = try args.int("concurrency") ?? 16
        let warmup = try args.int("warmup") ?? 500
        let rounds = max(1, try args.int("rounds") ?? 3)
        let pause = try args.seconds("pause") ?? 0
        let json = args.flag("json") ?? false
        try args.checkAllConsumed()

        switch kind {
        case .nw:
            let listener = try TCPListener(configuration: .init(host: "127.0.0.1", port: 0))
            return try await measure(listener, kind: kind, connections: connections, concurrency: concurrency,
                                     warmup: warmup, rounds: rounds, pause: pause, json: json)
        case .bsd:
            let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 0))
            return try await measure(listener, kind: kind, connections: connections, concurrency: concurrency,
                                     warmup: warmup, rounds: rounds, pause: pause, json: json)
        }
    }

    static func measure<L: TransportListener>(
        _ base: L, kind: TransportKind, connections: Int, concurrency: Int, warmup: Int, rounds: Int, pause: Double,
        json: Bool
    ) async throws -> Int32 where L.Transport: AcceptTimed {
        let recorder = TimelineRecorder()
        let listener = TracingListener(base: base, recorder: recorder)
        let server = Server(listeners: [listener], protocols: [HTTP1()], handler: HelloHandler(bodySize: 626))

        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run() }
            let addresses = try await server.waitUntilRunning()
            let port = addresses[0].port

            if warmup > 0 {
                _ = await ClientPool.run(port: port, connections: warmup, concurrency: concurrency, recorder: nil)
            }
            var results: [RoundResult] = []
            for round in 0..<rounds {
                if round > 0 && pause > 0 { try await Task.sleep(for: .seconds(pause)) }
                recorder.reset()
                var clientResult = ClientPool.Result()
                let clock = ContinuousClock()
                let start = clock.now
                let allocations = await AllocationCounter.countAsync {
                    clientResult = await ClientPool.run(
                        port: port, connections: connections, concurrency: concurrency, recorder: recorder)
                }
                let elapsed = start.duration(to: clock.now)
                results.append(RoundResult(
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                    failures: clientResult.failures,
                    allocationsPerConnection: allocations.map { Double($0) / Double(connections) },
                    phases: recorder.phases()))
            }
            await server.shutdown()
            try await group.waitForAll()

            let sorted = results.sorted { $0.seconds < $1.seconds }
            let median = sorted[sorted.count / 2]
            report(median, all: results, kind: kind, connections: connections, concurrency: concurrency, json: json)
            return 0
        }
    }

    struct RoundResult {
        var seconds: Double
        var failures: Int
        var allocationsPerConnection: Double?
        var phases: [(String, Summary)]
    }

    static func report(_ r: RoundResult, all: [RoundResult], kind: TransportKind, connections: Int, concurrency: Int, json: Bool) {
        let rate = Double(connections) / r.seconds
        let rates = all.map { Double(connections) / $0.seconds }.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        if json {
            var phases: [String: [String: Double]] = [:]
            for (name, s) in r.phases { phases[name] = ["p50_us": s.median / 1000, "p90_us": s.p90 / 1000, "p99_us": s.p99 / 1000] }
            let object: [String: Any] = [
                "transport": kind.rawValue, "connections": connections, "concurrency": concurrency,
                "connectionsPerSecond": rate, "failures": r.failures,
                "allocationsPerConnection": r.allocationsPerConnection ?? -1, "phases": phases,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        print("transport \(kind.rawValue), \(connections) connections x \(all.count) rounds, concurrency \(concurrency)")
        print(String(format: "connections/s: %.0f (median round; all rounds: %@), failures %d", rate, rates, r.failures))
        if let allocs = r.allocationsPerConnection {
            print(String(format: "allocations per connection (process-wide): %.1f", allocs))
        }
        print("phase          p50 us    p90 us    p99 us")
        for (name, s) in r.phases {
            print(name.padding(toLength: 12, withPad: " ", startingAt: 0)
                  + String(format: "%9.1f %9.1f %9.1f", s.median / 1000, s.p90 / 1000, s.p99 / 1000))
        }
    }
}

enum TransportKind: String {
    case nw, bsd

    init(argument: String) throws(Arguments.Failure) {
        guard let kind = TransportKind(rawValue: argument) else { throw .invalidValue("transport", argument) }
        self = kind
    }
}

/// A transport that knows when its listener handed it over and when it became ready.
protocol AcceptTimed {
    var acceptTimestamps: (handedOver: UInt64, ready: UInt64) { get }
}

extension TCPTransport: AcceptTimed {}
extension BSDSocketTransport: AcceptTimed {}

@inline(__always) func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// MARK: - Timeline

/// Per-connection timestamps, indexed by the client's source port (preallocated, so recording
/// does not allocate).
final class TimelineRecorder: Sendable {
    struct Timeline {
        var connectStart: UInt64 = 0
        var connected: UInt64 = 0
        var handedOver: UInt64 = 0
        var ready: UInt64 = 0
        var taken: UInt64 = 0
        var firstRead: UInt64 = 0
        var firstByte: UInt64 = 0
        var end: UInt64 = 0
    }

    private let slots = Mutex<[Timeline]>(Array(repeating: Timeline(), count: 65536))
    private let used = Mutex<[UInt16]>([])

    func reset() {
        slots.withLock { slots in
            for i in slots.indices { slots[i] = Timeline() }
        }
        used.withLock { $0.removeAll(keepingCapacity: true); $0.reserveCapacity(65536) }
    }

    func update(_ port: UInt16, _ body: (inout Timeline) -> Void) {
        slots.withLock { body(&$0[Int(port)]) }
    }

    func client(port: UInt16, connectStart: UInt64, connected: UInt64, firstByte: UInt64, end: UInt64) {
        slots.withLock { slots in
            slots[Int(port)].connectStart = connectStart
            slots[Int(port)].connected = connected
            slots[Int(port)].firstByte = firstByte
            slots[Int(port)].end = end
        }
        used.withLock { $0.append(port) }
    }

    func phases() -> [(String, Summary)] {
        let ports = used.withLock { $0 }
        let timelines = slots.withLock { slots in ports.map { slots[Int($0)] } }
        func phase(_ name: String, _ value: (Timeline) -> (UInt64, UInt64)) -> (String, Summary)? {
            let samples = timelines.compactMap { t -> Double? in
                let (a, b) = value(t)
                guard a != 0, b != 0, b >= a else { return nil }
                return Double(b - a)
            }
            return Summary(samples).map { (name, $0) }
        }
        return [
            phase("connect") { ($0.connectStart, $0.connected) },
            phase("handover") { ($0.connected, $0.handedOver) },
            phase("ready") { ($0.handedOver, $0.ready) },
            phase("taken") { ($0.ready, $0.taken) },
            phase("first read") { ($0.taken, $0.firstRead) },
            phase("respond") { ($0.firstRead, $0.firstByte) },
            phase("close") { ($0.firstByte, $0.end) },
            phase("total") { ($0.connectStart, $0.end) },
        ].compactMap { $0 }
    }
}

/// Wraps a listener so the bench sees when the accept loop takes each connection and when
/// its first receive returns.
struct TracingListener<Base: TransportListener>: TransportListener where Base.Transport: AcceptTimed {
    let base: Base
    let recorder: TimelineRecorder

    func listen() async throws -> TransportAddress { try await base.listen() }
    func close() async { await base.close() }

    var connections: Connections { Connections(base: base.connections, recorder: recorder) }

    struct Connections: AsyncSequence {
        typealias Element = TracingTransport<Base.Transport>
        typealias Failure = any Error
        let base: Base.Connections
        let recorder: TimelineRecorder

        func makeAsyncIterator() -> Iterator { Iterator(base: base.makeAsyncIterator(), recorder: recorder) }

        struct Iterator: AsyncIteratorProtocol {
            var base: Base.Connections.AsyncIterator
            let recorder: TimelineRecorder

            mutating func next() async throws -> TracingTransport<Base.Transport>? {
                guard let transport = try await base.next() else { return nil }
                let taken = uptimeNanoseconds()
                let port = transport.info.remoteAddress?.port ?? 0
                let (handedOver, ready) = transport.acceptTimestamps
                recorder.update(port) {
                    $0.handedOver = handedOver
                    $0.ready = ready
                    $0.taken = taken
                }
                return TracingTransport(base: transport, port: port, recorder: recorder)
            }
        }
    }
}

/// Records the first receive that returns bytes. A struct, so wrapping allocates nothing.
struct TracingTransport<Base: ByteStreamTransport>: ByteStreamTransport {
    let base: Base
    let port: UInt16
    let recorder: TimelineRecorder

    var info: ConnectionInfo { base.info }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        let n = try await base.receive(into: &buffer, maxLength: maxLength)
        if n > 0 {
            let now = uptimeNanoseconds()
            recorder.update(port) { if $0.firstRead == 0 { $0.firstRead = now } }
        }
        return n
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try await base.send(bytes, endOfStream: endOfStream)
    }

    func sendFile(_ region: FileRegion) async throws { try await base.sendFile(region) }
    func close(_ reason: CloseReason) async { await base.close(reason) }
}

// MARK: - Client

/// Blocking BSD-socket clients on their own threads, so the client neither allocates per
/// connection nor competes with the server for the cooperative pool.
enum ClientPool {
    struct Result {
        var failures = 0
    }

    static func run(port: UInt16, connections: Int, concurrency: Int, recorder: TimelineRecorder?) async -> Result {
        let remaining = Atomic<Int>(connections)
        let failures = Atomic<Int>(0)
        let request: [UInt8] = Array("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let done = Atomic<Int>(0)
            let threads = max(1, concurrency)
            for _ in 0..<threads {
                let thread = Thread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while remaining.subtract(1, ordering: .relaxed).newValue >= 0 {
                        if !oneConnection(port: port, request: request, buffer: &buffer, recorder: recorder) {
                            failures.add(1, ordering: .relaxed)
                        }
                    }
                    if done.add(1, ordering: .acquiringAndReleasing).newValue == threads { continuation.resume() }
                }
                thread.stackSize = 1 << 20
                thread.start()
            }
        }
        return Result(failures: failures.load(ordering: .relaxed))
    }

    static func oneConnection(port: UInt16, request: [UInt8], buffer: inout [UInt8], recorder: TimelineRecorder?) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectStart = uptimeNanoseconds()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }
        let connectedAt = uptimeNanoseconds()

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let localPort = UInt16(bigEndian: local.sin_port)

        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else { return false }
        var firstByte: UInt64 = 0
        var total = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return false }
            if n == 0 { break }
            if firstByte == 0 { firstByte = uptimeNanoseconds() }
            total += n
        }
        let end = uptimeNanoseconds()
        guard total > 0 else { return false }
        recorder?.client(port: localPort, connectStart: connectStart, connected: connectedAt, firstByte: firstByte, end: end)
        return true
    }
}
