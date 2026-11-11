import Foundation
import HTTPCore
import Network
import NetworkTransport
import Synchronization

/// A bare `NWConnection` client for socket tests, so the adapter is checked against
/// Network.framework directly and not only against itself. Loopback only (AGENTS.md).
final class RawClient: Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "sws.test.rawclient")
    private let ready = Mutex<UnsafeContinuation<Void, any Error>?>(nil)

    init(port: UInt16, host: String = "127.0.0.1") {
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    /// Starts the connection and waits for `.ready` (handlers installed first).
    func start() async throws {
        try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
            ready.withLock { $0 = continuation }
            connection.stateUpdateHandler = { [self] state in
                let error: (any Error)?
                switch state {
                case .ready: error = nil
                case .failed(let e), .waiting(let e): error = e
                case .cancelled: error = TransportError.closed
                default: return
                }
                let pending = ready.withLock { value in
                    defer { value = nil }
                    return value
                }
                if let error { pending?.resume(throwing: error) } else { pending?.resume() }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ bytes: [UInt8], final: Bool = false) async throws {
        try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
            connection.send(
                content: bytes.isEmpty ? nil : Data(bytes),
                contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    /// One receive: the bytes, whether the peer finished, and any error.
    func receive(max: Int = 65536) async -> (bytes: [UInt8], isComplete: Bool, error: NWError?) {
        await withUnsafeContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                continuation.resume(returning: (data.map { [UInt8]($0) } ?? [], isComplete, error))
            }
        }
    }

    /// Receives until `count` bytes arrived or the stream ended.
    func receive(exactly count: Int) async -> [UInt8] {
        var all: [UInt8] = []
        while all.count < count {
            let (bytes, isComplete, error) = await receive(max: count - all.count)
            all += bytes
            if isComplete || error != nil { break }
        }
        return all
    }

    func cancel() { connection.cancel() }
}

extension ByteBuffer {
    var bytes: [UInt8] { withUnsafeReadableBytes { [UInt8]($0) } }
}

/// Receives until `count` bytes are buffered or end of stream.
func receive(_ transport: some ByteStreamTransport, exactly count: Int) async throws -> ByteBuffer {
    var buffer = ByteBuffer(capacity: count)
    while buffer.readableBytes < count {
        let n = try await transport.receive(into: &buffer, maxLength: count - buffer.readableBytes)
        if n == 0 { break }
    }
    return buffer
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A started loopback listener on port 0.
func makeListener(limit: Int = 64) async throws -> TCPListener {
    let listener = try TCPListener(configuration: .init(host: "127.0.0.1", port: 0, pendingConnectionLimit: limit))
    try await listener.start()
    return listener
}

/// Takes the next accepted connection.
func accept(_ listener: TCPListener) async throws -> TCPTransport {
    var iterator = listener.connections.makeAsyncIterator()
    guard let transport = try await iterator.next() else { throw TransportError.closed }
    return transport
}
