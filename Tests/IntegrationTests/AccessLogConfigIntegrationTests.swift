import Foundation
import HTTPTestSupport
import Testing

/// The shipped `SwiftWebServer` binary writes an access log configured in `http-config.json`
/// (#0125): one line per request for static files, a proxied path (the upstream is a second
/// `SwiftWebServer`) and an auth rejection. Everything binds 127.0.0.1 port 0 and lives under
/// `$TMPDIR`; both children are SIGKILLed on every path.
@Suite struct AccessLogConfigIntegrationTests {
    func curl(_ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sS", "--max-time", "10"] + arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return output.stdout
    }

    @Test(.timeLimit(.minutes(1)))
    func staticProxiedAndRejectedRequestsAreLogged() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "sws-accesslog-\(UInt64.random(in: 0...UInt64.max))")
        let fm = FileManager.default
        try fm.createDirectory(at: temp.appending(path: "Public"), withIntermediateDirectories: true)
        try fm.createDirectory(at: temp.appending(path: "Upstream"), withIntermediateDirectories: true)
        try fm.createDirectory(at: temp.appending(path: "logs"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try Data("front\n".utf8).write(to: temp.appending(path: "Public/hello.txt"))
        try Data("upstream\n".utf8).write(to: temp.appending(path: "Upstream/data.txt"))

        let upstream = try ParityTests.launch(["--root", temp.appending(path: "Upstream").path, "--port", "0"])
        defer { upstream.kill() }
        let upstreamPort = try await upstream.listeningPort()

        let config = temp.appending(path: "http-config.json")
        try Data("""
        {
          "host": "127.0.0.1",
          "port": 0,
          "root": "Public",
          "accessLog": { "path": "logs/access.log", "format": "json", "metrics": "/_metrics" },
          "auth": [{ "paths": ["/private"], "tokens": [{ "name": "ci", "sha256": "\(String(repeating: "ab", count: 32))" }] }],
          "proxy": [{ "path": "/api", "upstream": "http://127.0.0.1:\(upstreamPort)", "stripPrefix": true }]
        }
        """.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let base = "http://127.0.0.1:\(try await server.listeningPort())"
        #expect(!server.stderr.contains("warning"), "\(server.stderr)")

        #expect(try await curl(["\(base)/hello.txt"]) == "front\n")
        #expect(try await curl(["\(base)/api/data.txt"]) == "upstream\n")
        #expect(try await curl(["-o", "/dev/null", "-w", "%{http_code}", "\(base)/private/x"]) == "401")
        #expect(try await curl(["\(base)/_metrics"]).contains("# TYPE"))

        // A graceful stop writes everything still buffered.
        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 0, "\(server.stderr)")

        let log = try String(contentsOf: temp.appending(path: "logs/access.log"), encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        #expect(lines.count == 4, "\(log)")
        let entries = try lines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "\(line)")
        }
        let observed = entries.map { "\($0["method"] ?? "") \($0["path"] ?? "") \($0["status"] ?? "")" }
        #expect(observed == ["GET /hello.txt 200", "GET /api/data.txt 200", "GET /private/x 401", "GET /_metrics 200"],
                "\(log)")
        #expect(entries.allSatisfy { $0["remote"] as? String == "127.0.0.1" }, "\(log)")
        #expect(entries.first?["bytes"] as? Int == 6, "\(log)")

        upstream.kill()
    }

    @Test(.timeLimit(.minutes(1)))
    func unwritableLogPathExitsOneNamingTheKey() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "sws-accesslog-bad-\(UInt64.random(in: 0...UInt64.max))")
        try FileManager.default.createDirectory(at: temp.appending(path: "Public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = temp.appending(path: "http-config.json")
        try Data(#"{"port": 0, "accessLog": {"path": "missing/dir/access.log"}}"#.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        #expect(try await server.waitForExit(timeout: .seconds(5)) == 1)
        #expect(server.stderr.contains("accessLog.path"), "\(server.stderr)")
    }
}
