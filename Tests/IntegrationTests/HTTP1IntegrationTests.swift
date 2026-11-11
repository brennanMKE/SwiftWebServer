import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
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

    /// #0081: `curl --data-binary @file` to the serve echo handler gets the file back; a 3 MiB
    /// body makes curl send `Expect: 100-continue`, so the 100 path runs over real TCP. The
    /// same file uploaded with `curl -T` (PUT) reports its length.
    @Test(.timeLimit(.minutes(1)))
    func curlPostEchoesAFile() async throws {
        let directory = FileManager.default.temporaryDirectory
        let tag = UInt64.random(in: 0...UInt64.max)
        let input = directory.appending(path: "sws-echo-in-\(tag).bin")
        let output = directory.appending(path: "sws-echo-out-\(tag).bin")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        var generator = SystemRandomNumberGenerator()
        let content = Data((0..<(3 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try content.write(to: input)

        let serve = try ChildProcess.launch(["serve", "--port", "0", "--drain-timeout", "0.5"])
        defer { serve.kill() }
        let port = try await serve.listeningPort()
        let url = "http://127.0.0.1:\(port)/echo"

        let (status, log) = try await runCurl(["-sS", "-v", "--max-time", "20", "--data-binary", "@\(input.path)",
                                               "-H", "Content-Type: application/octet-stream",
                                               "-o", output.path, url])
        #expect(status == 0, "\(log)")
        #expect(log.contains("HTTP/1.1 100 Continue"), "curl did not get 100 Continue:\n\(log)")
        #expect(log.contains("HTTP/1.1 200 OK"), "\(log)")
        let echoed = try Data(contentsOf: output)
        #expect(echoed.count == content.count)
        #expect(echoed == content)

        let (putStatus, putOutput) = try await runCurl(["-sS", "--max-time", "20", "-T", input.path, url])
        #expect(putStatus == 0, "\(putOutput)")
        #expect(putOutput == "\(content.count)\n")

        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    /// #0082 (legacy #0012): a slowloris client writing one header byte per second gets `408`
    /// and end of stream when the header limit passes, however long it keeps trickling.
    @Test(.timeLimit(.minutes(1)))
    func slowlorisIsClosedWithinTheHeaderTimeout() async throws {
        let listener = try TCPListener(configuration: TCPListener.Configuration(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let timeouts = HTTP1Timeouts(header: .seconds(2), linger: .milliseconds(500))
        let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                            listeners: [listener],
                            protocols: [HTTP1(configuration: HTTP1Configuration(timeouts: timeouts))],
                            handler: TextHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address"); return
            }
            let client = try await TCPTransport.connect(host: "127.0.0.1", port: port)
            let head = Array("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Slow: \(String(repeating: "s", count: 60))\r\n\r\n".utf8)
            let start = ContinuousClock.now
            let received = await withTaskGroup(of: ByteBuffer?.self) { inner -> ByteBuffer in
                inner.addTask {
                    // One byte per second, until the server stops reading or the test is done.
                    for byte in head {
                        var one = ByteBuffer()
                        one.append(contentsOf: [byte])
                        guard (try? await client.send(one, endOfStream: false)) != nil else { break }
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { break }
                    }
                    return nil
                }
                inner.addTask {
                    var buffer = ByteBuffer()
                    while (try? await client.receive(into: &buffer, maxLength: 4096)) ?? 0 > 0 {}
                    return buffer
                }
                var result = ByteBuffer()
                while let next = await inner.next() {
                    if let next {
                        result = next
                        break
                    }
                }
                inner.cancelAll()
                return result
            }
            let elapsed = ContinuousClock.now - start
            let text = String(decoding: received.withReadableSpan { s in (0..<s.count).map { s[$0] } }, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"), "\(text)")
            #expect(text.lowercased().contains("connection: close"), "\(text)")
            #expect(elapsed >= .milliseconds(1500) && elapsed < .seconds(4), "closed after \(elapsed)")
            await client.close(.normal)

            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    /// Runs `/usr/bin/curl` with a deadline and returns its status and combined output. A
    /// timeout or a cancellation SIGKILLs curl (#0114).
    func runCurl(_ arguments: [String]) async throws -> (Int32, String) {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return (output.status, output.stdout)
    }
}
