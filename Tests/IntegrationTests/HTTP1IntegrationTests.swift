import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import Testing

/// HTTP/1.1 over real TCP on 127.0.0.1 port 0 (#0080): curl keep-alive and a short
/// `sws-bench load --keepalive` run against `sws-bench serve`.
@Suite struct HTTP1IntegrationTests {
    struct TextHandler: HTTPHandler {
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            var body = ByteBuffer()
            body.append(contentsOf: Array("path=\(request.string(of: request.path))\n".utf8))
            return HTTPResponse(body: .bytes(body))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func curlReusesTheConnection() async throws {
        let listener = try TCPListener(configuration: TCPListener.Configuration(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                            listeners: [listener], protocols: [HTTP1()], handler: TextHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address"); return
            }
            let base = "http://127.0.0.1:\(port)"
            let (status, output) = try await runCurl(["-sv", "--max-time", "10", "\(base)/a", "\(base)/b"])
            #expect(status == 0, "\(output)")
            #expect(output.contains("path=/a"))
            #expect(output.contains("path=/b"))
            #expect(output.contains("Re-using existing connection") || output.contains("Reusing existing"),
                    "curl did not reuse the connection:\n\(output)")
            #expect(server.acceptedConnectionCount == 1)

            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loadClientKeepAliveAgainstServe() async throws {
        let serve = try ChildProcess.launch(["serve", "--port", "0", "--drain-timeout", "0.5"])
        defer { serve.kill() }
        let port = try await serve.listeningPort()

        let load = try ChildProcess.launch(["load", "--url", "http://127.0.0.1:\(port)/", "--keepalive",
                                            "--connections", "4", "--duration", "2", "--json"])
        defer { load.kill() }
        #expect(try await load.waitForExit(timeout: .seconds(20)) == 0, "stderr: \(load.stderr)")
        let report = try JSONSerialization.jsonObject(with: Data(load.stdout.utf8)) as? [String: Any]
        let result = report?["result"] as? [String: Any]
        let requests = result?["requests"] as? Int ?? 0
        #expect(requests > 100, "\(load.stdout)")
        #expect(result?["errors"] as? Int == 0, "\(load.stdout)")
        #expect(result?["connectionsOpened"] as? Int == 4, "\(load.stdout)")
        #expect((result?["statusCounts"] as? [String: Int])?["200"] == requests)

        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    /// Runs `/usr/bin/curl` with a deadline and returns its status and combined output.
    func runCurl(_ arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(15)
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                process.terminate()
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
