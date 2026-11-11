import Foundation
import HTTPCore
import NetworkTransport
import Testing

/// Child-process tests of the new stack's entry point, `sws-bench serve` (#0079; legacy #0003,
/// #0004). The child binds 127.0.0.1 port 0. Every child is killed on every path.
@Suite struct ServeProcessTests {
    static let drainTimeout: Duration = .milliseconds(500)

    @Test(.timeLimit(.minutes(1)))
    func sigtermDrainsAndExitsZero() async throws {
        let child = try ChildProcess.launch(["serve", "--port", "0", "--drain-timeout", "0.5"])
        defer { child.kill() }
        let port = try await child.listeningPort()

        // An open, idle keep-alive connection: the drain deadline must cancel it.
        let client = try await TCPTransport.connect(host: "127.0.0.1", port: port)
        let reply = await roundTrip(client, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(reply)")

        let start = ContinuousClock.now
        child.signal(SIGTERM)
        let status = try await child.waitForExit(timeout: Self.drainTimeout + .seconds(3))
        let elapsed = ContinuousClock.now - start
        #expect(status == 0, "stderr: \(child.stderr)")
        #expect(child.process.terminationReason == .exit)
        #expect(elapsed < Self.drainTimeout + .seconds(2))
        #expect(await peerClosed(client))
        await client.close(.normal)
    }

    @Test(.timeLimit(.minutes(1)))
    func sigintExitsZero() async throws {
        let child = try ChildProcess.launch(["serve", "--port", "0", "--drain-timeout", "0.5"])
        defer { child.kill() }
        _ = try await child.listeningPort()
        child.signal(SIGINT)
        let status = try await child.waitForExit(timeout: .seconds(3))
        #expect(status == 0, "stderr: \(child.stderr)")
        #expect(child.process.terminationReason == .exit)
    }

    @Test(.timeLimit(.minutes(1)))
    func badConfigFileExitsOneWithAMessage() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "sws-bad-config-\(UInt64.random(in: 0...UInt64.max)).json")
        try Data("{ not json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let start = ContinuousClock.now
        let child = try ChildProcess.launch(["serve", "--config", file.path])
        defer { child.kill() }
        let status = try await child.waitForExit(timeout: .seconds(2))
        #expect(status == 1)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(child.stderr.contains("config file"))
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidConfigValueExitsOne() async throws {
        let child = try ChildProcess.launch(["serve", "--port", "0", "--max-connections", "0"])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(2)) == 1)
        #expect(child.stderr.contains("maxConnections"))
    }

    @Test(.timeLimit(.minutes(1)))
    func portInUseExitsOne() async throws {
        let holder = try ChildProcess.launch(["serve", "--port", "0"])
        defer { holder.kill() }
        let port = try await holder.listeningPort()

        let clash = try ChildProcess.launch(["serve", "--port", "\(port)"])
        defer { clash.kill() }
        #expect(try await clash.waitForExit(timeout: .seconds(2)) == 1)
        #expect(clash.stderr.contains("cannot serve"))

        holder.signal(SIGTERM)
        #expect(try await holder.waitForExit(timeout: .seconds(5)) == 0)
    }
}

/// A launched `sws-bench` with captured stdout and stderr.
final class ChildProcess: @unchecked Sendable {
    let process: Process
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    static func executable() throws -> URL {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appending(path: "sws-bench"))
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(packageRoot.appending(path: ".build/debug/sws-bench"))
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ChildError.executableNotFound(candidates.map(\.path))
        }
        return found
    }

    static func launch(_ arguments: [String]) throws -> ChildProcess {
        let child = ChildProcess(executable: try executable(), arguments: arguments)
        try child.process.run()
        return child
    }

    private init(executable: URL, arguments: [String]) {
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.withLock { self.stdoutData.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.withLock { self.stderrData.append(data) }
        }
    }

    var stdout: String { lock.withLock { String(decoding: stdoutData, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: stderrData, as: UTF8.self) } }

    /// The port from the child's `listening 127.0.0.1:PORT` line.
    func listeningPort(timeout: Duration = .seconds(10)) async throws -> UInt16 {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix("listening ") }),
               let colon = line.lastIndex(of: ":"), let port = UInt16(line[line.index(after: colon)...]) {
                return port
            }
            if !process.isRunning { throw ChildError.exitedEarly(stderr) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChildError.timedOut("no listening line; stderr: \(stderr)")
    }

    func signal(_ number: Int32) {
        if process.isRunning { Foundation.kill(process.processIdentifier, number) }
    }

    /// The exit status, once the child exits within `timeout`.
    func waitForExit(timeout: Duration) async throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline { throw ChildError.timedOut("still running after \(timeout)") }
            try await Task.sleep(for: .milliseconds(10))
        }
        process.waitUntilExit()
        // Let the readability handlers deliver what is left.
        try await Task.sleep(for: .milliseconds(20))
        return process.terminationStatus
    }

    /// Kills the child if it is still running and stops reading its output.
    func kill() {
        if process.isRunning {
            Foundation.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    enum ChildError: Error {
        case executableNotFound([String])
        case exitedEarly(String)
        case timedOut(String)
    }
}
