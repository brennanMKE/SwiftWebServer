import Foundation
import HTTPTestSupport
import Testing

/// End to end through the shipped `SwiftWebServer` binary (#0124): static files from
/// `Root/Public` at `/`, and `/api` proxied to the `Examples/go-api` app. Both children bind
/// 127.0.0.1 only and are SIGKILLed on every path (`ChildProcess`). Skips without Go.
@Suite struct GoProxyIntegrationTests {
    static var goExecutable: URL? {
        var candidates = ["/opt/homebrew/bin/go"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/go" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Builds `Examples/go-api` into `directory` and starts it on 127.0.0.1 port 0. Returns
    /// nil (after recording an issue) when the build fails. Caches stay under $TMPDIR; no
    /// network (`GOPROXY=off`, `GOTOOLCHAIN=local`).
    static func startGoAPI(go: URL, in directory: URL) async throws -> (ChildProcess, UInt16)? {
        let cache = FileManager.default.temporaryDirectory.appending(path: "sws-go-cache")
        let binary = directory.appending(path: "go-api")
        let build = try await ChildProcess.run(
            URL(fileURLWithPath: "/usr/bin/env"),
            ["GOCACHE=\(cache.path)/build", "GOPATH=\(cache.path)/path", "GOTOOLCHAIN=local", "GOPROXY=off",
             go.path, "build", "-C", ParityTests.packageRoot.appending(path: "Examples/go-api").path,
             "-o", binary.path, "."],
            timeout: .seconds(120), mergeStandardError: true)
        #expect(build.status == 0, "go build: \(build.stdout)")
        guard build.status == 0 else { return nil }

        // Port 0: the app logs its bound address ("go-api listening on 127.0.0.1:NNNN").
        let api = try ChildProcess(executable: binary, arguments: ["-addr", "127.0.0.1:0"], mergeStandardError: true)
        do {
            let port = try await api.waitForLine { line -> UInt16? in
                guard let range = line.range(of: "listening on 127.0.0.1:") else { return nil }
                return UInt16(line[range.upperBound...].prefix { $0.isNumber })
            }
            return (api, port)
        } catch {
            api.kill()
            throw error
        }
    }

    func curl(_ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sS", "--max-time", "10"] + arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return output.stdout
    }

    @Test(.enabled(if: GoProxyIntegrationTests.goExecutable != nil, "Go is not installed"),
          .timeLimit(.minutes(3)))
    func staticRootAndProxiedGoAPI() async throws {
        let go = try #require(Self.goExecutable)
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "sws-go-proxy-\(UInt64.random(in: 0...UInt64.max))")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let (api, apiPort) = try await Self.startGoAPI(go: go, in: temp) else { return }
        defer { api.kill() }

        let config = temp.appending(path: "http-config.json")
        let root = ParityTests.packageRoot.appending(path: "Root/Public").path
        try Data("""
        {
          "host": "127.0.0.1",
          "port": 0,
          "root": "\(root)",
          "proxy": [
            { "path": "/api", "upstream": "http://127.0.0.1:\(apiPort)", "forwardedHeaders": "x-forwarded" }
          ]
        }
        """.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let base = "http://127.0.0.1:\(try await server.listeningPort())"

        let index = try await curl(["-i", "\(base)/"])
        let expectedIndex = try String(contentsOfFile: root + "/index.html", encoding: .utf8)
        #expect(index.hasPrefix("HTTP/1.1 200"), "\(index)")
        #expect(index.hasSuffix(expectedIndex), "\(index)")

        let health = try await curl(["\(base)/api/health"])
        #expect(health.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"status":"ok"}"#, "\(health)")

        let created = try await curl(["-i", "-X", "POST", "-H", "Content-Type: application/json",
                                      "--data", #"{"name":"from-swift","done":false}"#, "\(base)/api/items"])
        #expect(created.hasPrefix("HTTP/1.1 201"), "\(created)")
        #expect(created.contains("from-swift"), "\(created)")
        let list = try await curl(["\(base)/api/items"])
        #expect(list.contains(#""name":"from-swift""#), "\(list)")

        let echo = try await curl(["\(base)/api/echo"])
        #expect(echo.contains(#""X-Forwarded-For":"127.0.0.1""#), "\(echo)")
        #expect(echo.contains(#""X-Forwarded-Proto":"http""#), "\(echo)")

        server.kill()
        api.kill()
    }
}
