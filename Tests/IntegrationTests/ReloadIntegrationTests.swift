import Foundation
import HTTPTestSupport
import Testing

/// #0127 acceptance through the shipped `SwiftWebServer` binary: SIGHUP reopens the access log
/// (a renamed log is followed by a new file at the path), reloads `http-config.json` (a new
/// proxy mount takes effect while a slow download in flight completes), and keeps the running
/// configuration when the new file is invalid. Everything binds 127.0.0.1 port 0 and lives
/// under `$TMPDIR`; every child is SIGKILLed on every path.
@Suite struct ReloadIntegrationTests {
    func curl(_ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sS", "--max-time", "20"] + arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return output.stdout
    }

    /// Waits until `text` occurs `count` times on the child's stderr.
    func waitForStderr(_ child: ChildProcess, _ text: String, count: Int = 1) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while child.stderr.components(separatedBy: text).count - 1 < count {
            guard clock.now < deadline else {
                Issue.record("no \"\(text)\" ×\(count) on stderr: \(child.stderr)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sws-\(name)-\(UInt64.random(in: 0...UInt64.max))")
        try FileManager.default.createDirectory(at: url.appending(path: "Public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appending(path: "logs"), withIntermediateDirectories: true)
        return url
    }

    @Test(.timeLimit(.minutes(1)))
    func hangupReopensARenamedAccessLog() async throws {
        let temp = try temporaryDirectory("reload-log")
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data("hi\n".utf8).write(to: temp.appending(path: "Public/a.txt"))
        let config = temp.appending(path: "http-config.json")
        try Data(#"{"port": 0, "accessLog": {"path": "logs/access.log", "flushInterval": 0.05}}"#.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let base = "http://127.0.0.1:\(try await server.listeningPort())"
        let log = temp.appending(path: "logs/access.log")
        let rotated = temp.appending(path: "logs/access.log.1")

        #expect(try await curl(["\(base)/a.txt?before"]) == "hi\n")
        try await waitFor { lines(log).count == 1 }
        try FileManager.default.moveItem(at: log, to: rotated)

        server.signal(SIGHUP)
        try await waitForStderr(server, "reloaded the configuration")
        #expect(try await curl(["\(base)/a.txt?after"]) == "hi\n")
        try await waitFor { lines(log).count == 1 }

        // With a config that no longer loads, the running log is still reopened.
        let rotatedAgain = temp.appending(path: "logs/access.log.2")
        try FileManager.default.moveItem(at: log, to: rotatedAgain)
        try Data("{".utf8).write(to: config)
        server.signal(SIGHUP)
        try await waitForStderr(server, "reload failed, keeping the running configuration")
        #expect(try await curl(["\(base)/a.txt?third"]) == "hi\n")
        try await waitFor { lines(log).count == 1 }

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 0, "\(server.stderr)")
        #expect(lines(rotated).count == 1 && lines(rotated)[0].contains("?before"), "\(lines(rotated))")
        #expect(lines(rotatedAgain).count == 1 && lines(rotatedAgain)[0].contains("?after"), "\(lines(rotatedAgain))")
        #expect(lines(log).count == 1 && lines(log)[0].contains("?third"), "\(lines(log))")
    }

    @Test(.timeLimit(.minutes(1)))
    func hangupReloadsWithoutDroppingInFlightRequestsAndKeepsAValidConfig() async throws {
        let temp = try temporaryDirectory("reload-config")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        try fm.createDirectory(at: temp.appending(path: "Upstream"), withIntermediateDirectories: true)
        try Data("upstream\n".utf8).write(to: temp.appending(path: "Upstream/data.txt"))
        let big = Data((0..<(6 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        try big.write(to: temp.appending(path: "Public/big.bin"))

        let upstream = try ParityTests.launch(["--root", temp.appending(path: "Upstream").path, "--port", "0"])
        defer { upstream.kill() }
        let upstreamPort = try await upstream.listeningPort()

        let config = temp.appending(path: "http-config.json")
        try Data(#"{"port": 0, "root": "Public"}"#.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let port = try await server.listeningPort()
        let base = "http://127.0.0.1:\(port)"
        #expect(try await curl(["-o", "/dev/null", "-w", "%{http_code}", "\(base)/api/data.txt"]) == "404")

        // A slow download (about 3 s) is in flight across the reload.
        let download = temp.appending(path: "download.bin")
        async let slow = ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                          ["-sS", "--max-time", "30", "--limit-rate", "2M", "-o", download.path,
                                           "-w", "%{http_code}", "\(base)/big.bin"],
                                          timeout: .seconds(40), mergeStandardError: true)
        try await Task.sleep(for: .milliseconds(500))

        try Data("""
        {"port": 0, "host": "127.0.0.2", "root": "Public",
         "proxy": [{"path": "/api", "upstream": "http://127.0.0.1:\(upstreamPort)", "stripPrefix": true}]}
        """.utf8).write(to: config)
        server.signal(SIGHUP)
        try await waitForStderr(server, "reloaded the configuration")
        #expect(server.stderr.contains("host changed; needs a restart"), "\(server.stderr)")
        #expect(try await curl(["\(base)/api/data.txt"]) == "upstream\n")

        // Invalid: reported, and the reloaded configuration keeps serving.
        try Data(#"{"port": 0, "root": "#.utf8).write(to: config)
        server.signal(SIGHUP)
        try await waitForStderr(server, "reload failed, keeping the running configuration")
        #expect(try await curl(["\(base)/api/data.txt"]) == "upstream\n")
        // Valid JSON whose root does not exist: the chain cannot be built, same outcome.
        try Data(#"{"port": 0, "root": "Missing"}"#.utf8).write(to: config)
        server.signal(SIGHUP)
        try await waitForStderr(server, "reload failed, keeping the running configuration", count: 2)
        #expect(try await curl(["\(base)/api/data.txt"]) == "upstream\n")

        let finished = try await slow
        #expect(finished.stdout == "200", "\(finished.stdout) \(finished.stderr)")
        #expect(try Data(contentsOf: download) == big)

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 0, "\(server.stderr)")
        upstream.kill()
    }

    func waitFor(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("condition not met in 10 s")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
