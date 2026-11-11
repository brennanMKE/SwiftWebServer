import Foundation
import HTTPCore
import HTTPTestSupport
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
        #expect(child.terminationReason == .exit)
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
        #expect(child.terminationReason == .exit)
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

/// `sws-bench` children. The process handling (non-blocking, cancellation-aware, SIGKILL on
/// every exit path) is `HTTPTestSupport.ChildProcess` (#0114).
extension ChildProcess {
    static func executable() throws -> URL {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appending(path: "sws-bench"))
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(packageRoot.appending(path: ".build/debug/sws-bench"))
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure.executableNotFound(candidates.map(\.path))
        }
        return found
    }

    /// Starts `sws-bench` with `arguments`.
    static func launch(_ arguments: [String]) throws -> ChildProcess {
        try ChildProcess(executable: executable(), arguments: arguments)
    }

    /// The port from the child's `listening 127.0.0.1:PORT` line.
    func listeningPort(timeout: Duration = .seconds(10)) async throws -> UInt16 {
        try await waitForLine(timeout: timeout) { line in
            guard line.hasPrefix("listening "), let colon = line.lastIndex(of: ":") else { return nil }
            return UInt16(line[line.index(after: colon)...])
        }
    }
}
