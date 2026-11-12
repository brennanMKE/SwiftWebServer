import Foundation
import HTTPTestSupport
import Testing

/// #0124 acceptance through the shipped `SwiftWebServer` binary configured like
/// `Root/http-config.proxy.json`: static `Root/Public` at `/`, `/api` proxied to the Go example
/// over HTTP/1.1, HTTP/2 and HTTP/3 on the TLS listener (the gitignored test identity, loaded
/// in memory; curl `-k`), a WebSocket through a mount, per-site mounts (`hosts[].proxy`) and
/// config errors. Every child binds 127.0.0.1 port 0 and is SIGKILLed on every path.
@Suite struct ProxyConfigIntegrationTests {
    /// One curl run: the body, then `\n<status> <http version>` from `-w`.
    struct Reply {
        var status: Int
        var version: String
        var body: String
    }

    /// A client protocol for the TLS listener.
    struct Client: CustomStringConvertible, Sendable {
        var curl: String
        var flags: [String]
        var version: String
        var description: String { "h\(version)" }
    }

    static var clients: [Client] {
        var clients = [Client(curl: "/usr/bin/curl", flags: ["--http1.1"], version: "1.1"),
                       Client(curl: "/usr/bin/curl", flags: ["--http2"], version: "2")]
        if ListenersProcessTests.hasH3Curl {
            clients.append(Client(curl: ListenersProcessTests.h3Curl, flags: ["--http3-only"], version: "3"))
        }
        return clients
    }

    func request(_ client: Client, _ url: String, _ extra: [String] = []) async throws -> Reply {
        let output = try await ChildProcess.run(
            URL(fileURLWithPath: client.curl),
            ["-sSk", "--max-time", "10", "-w", "\n%{http_code} %{http_version}"] + client.flags + extra + [url],
            timeout: .seconds(30))
        let text = output.stdout
        guard let newline = text.lastIndex(of: "\n") else {
            Issue.record("\(client) \(url): no status: \(text) \(output.stderr)")
            return Reply(status: 0, version: "", body: text)
        }
        let trailer = text[text.index(after: newline)...].split(separator: " ")
        return Reply(status: trailer.first.flatMap { Int($0) } ?? 0,
                     version: trailer.count > 1 ? String(trailer[1]) : "",
                     body: String(text[..<newline]))
    }

    func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sws-\(name)-\(UInt64.random(in: 0...UInt64.max))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Example config over h1, h2 and h3

    /// The example config with test ports: `/` is the static index and `/api/items` CRUD and
    /// `/api/echo` reach the Go app over every protocol, with the forwarded headers set.
    @Test(.enabled(if: GoProxyIntegrationTests.goExecutable != nil, "Go is not installed"),
          .timeLimit(.minutes(3)))
    func exampleConfigServesStaticAndProxiesOverEveryProtocol() async throws {
        let go = try #require(GoProxyIntegrationTests.goExecutable)
        let temp = try Self.temporaryDirectory("proxy-example")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let (api, apiPort) = try await GoProxyIntegrationTests.startGoAPI(go: go, in: temp) else { return }
        defer { api.kill() }

        // Root/http-config.proxy.json with port 0, the test identity and the Go app's port.
        let root = ParityTests.packageRoot.appending(path: "Root/Public").path
        let config = temp.appending(path: "http-config.json")
        try Data("""
        {
          "host": "127.0.0.1",
          "port": 0,
          "root": "\(root)",
          "drainTimeout": 2,
          "tls": { "identity": "\(try ListenersProcessTests.identityPath())", "password": "\(TestIdentity.password)", "port": 0 },
          "http2": true,
          "http3": { "enabled": true, "altSvcMaxAge": 86400 },
          "proxy": [
            {
              "path": "/api",
              "upstream": "http://127.0.0.1:\(apiPort)",
              "stripPrefix": false,
              "preserveHost": false,
              "forwardedHeaders": "x-forwarded",
              "rewriteLocation": true,
              "websocket": false,
              "timeouts": { "connect": 2, "response": 30, "idle": 60 }
            }
          ]
        }
        """.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let ports = try await ListenersProcessTests.ports(server, expecting: 3)
        #expect(!server.stderr.contains("warning"), "\(server.stderr)")
        let https = try #require(ports.https)
        let base = "https://127.0.0.1:\(https)"
        let index = try String(contentsOfFile: root + "/index.html", encoding: .utf8)

        for client in Self.clients {
            var reply = try await request(client, "\(base)/")
            #expect(reply.status == 200 && reply.version == client.version, "\(client) /: \(reply)")
            #expect(reply.body == index, "\(client) /")

            reply = try await request(client, "\(base)/api/items", [
                "-X", "POST", "-H", "Content-Type: application/json",
                "--data", #"{"name":"via-\#(client)","done":false}"#])
            #expect(reply.status == 201 && reply.version == client.version, "\(client) POST: \(reply)")
            let id = try #require(json(reply.body)["id"] as? Int, "\(client) POST: \(reply)")

            reply = try await request(client, "\(base)/api/items/\(id)")
            #expect(reply.status == 200, "\(client) GET: \(reply)")
            #expect(json(reply.body)["name"] as? String == "via-\(client)", "\(client) GET: \(reply)")

            reply = try await request(client, "\(base)/api/items/\(id)", [
                "-X", "PUT", "-H", "Content-Type: application/json",
                "--data", #"{"name":"renamed-\#(client)","done":true}"#])
            #expect(reply.status == 200, "\(client) PUT: \(reply)")
            #expect(json(reply.body)["done"] as? Bool == true, "\(client) PUT: \(reply)")

            reply = try await request(client, "\(base)/api/items")
            #expect(reply.status == 200 && reply.body.contains("renamed-\(client)"), "\(client) list: \(reply)")

            reply = try await request(client, "\(base)/api/items/\(id)", ["-X", "DELETE"])
            #expect(reply.status == 204, "\(client) DELETE: \(reply)")
            reply = try await request(client, "\(base)/api/items/\(id)")
            #expect(reply.status == 404, "\(client) GET after DELETE: \(reply)")

            reply = try await request(client, "\(base)/api/echo?q=1")
            #expect(reply.status == 200 && reply.version == client.version, "\(client) echo: \(reply)")
            let echo = json(reply.body)
            let headers = echo["headers"] as? [String: String] ?? [:]
            #expect(headers["X-Forwarded-For"] == "127.0.0.1", "\(client) echo: \(reply.body)")
            #expect(headers["X-Forwarded-Proto"] == "https", "\(client) echo: \(reply.body)")
            #expect(headers["X-Forwarded-Host"] == "127.0.0.1:\(https)", "\(client) echo: \(reply.body)")
            #expect(echo["host"] as? String == "127.0.0.1:\(apiPort)", "preserveHost false: \(reply.body)")
            #expect(echo["path"] as? String == "/api/echo" && echo["query"] as? String == "q=1", "\(reply.body)")
        }

        // Cleartext too: the proto is http there.
        let plain = try await request(Self.clients[0], "http://127.0.0.1:\(ports.http)/api/echo")
        let headers = json(plain.body)["headers"] as? [String: String] ?? [:]
        #expect(headers["X-Forwarded-Proto"] == "http", "\(plain)")

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(15)) == 0, "\(server.stderr)")
        api.kill()
    }

    // MARK: WebSocket through a mount

    /// `URLSessionWebSocketTask` to the front server; the mount (`"websocket": true`) passes the
    /// upgrade to an `sws-bench serve --websocket-echo` upstream.
    @Test(.timeLimit(.minutes(1)))
    func websocketUpgradeThroughAMount() async throws {
        let upstream = try ChildProcess.launch(["serve", "--port", "0", "--drain-timeout", "0.5",
                                                "--websocket-echo", "/ws/echo"])
        defer { upstream.kill() }
        let upstreamPort = try await upstream.listeningPort()

        let fixture = try ParityTests.Fixture(config: """
            {"host": "127.0.0.1", "drainTimeout": 1,
             "proxy": [{"path": "/ws", "upstream": "http://127.0.0.1:\(upstreamPort)", "websocket": true}]}
            """)
        let (server, base) = try await ParityTests.serve(fixture)
        defer { server.kill() }
        #expect(!server.stderr.contains("warning"), "\(server.stderr)")

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let wsURL = URL(string: base.replacingOccurrences(of: "http://", with: "ws://") + "/ws/echo")!
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        try await task.send(.string("through the proxy"))
        guard case .string(let text) = try await task.receive() else { Issue.record("not text"); return }
        #expect(text == "through the proxy")
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try await task.send(.data(bytes))
        guard case .data(let echoed) = try await task.receive() else { Issue.record("not binary"); return }
        #expect(echoed == bytes)
        task.cancel(with: .normalClosure, reason: nil)

        // Plain requests still work on both sides of the mount.
        let (body, response) = try await session.data(from: URL(string: "\(base)/")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "<h1>home</h1>")
        let (proxied, _) = try await session.data(from: URL(string: "\(base)/ws/plain")!)
        #expect(String(decoding: proxied, as: UTF8.self) == "Hello, World!\n")

        upstream.kill()
    }

    // MARK: Per-site mounts

    /// `hosts[].proxy`: a site's mount wins over the server-level mount of the same prefix for
    /// that site; other sites get the server-level mount; everything else is the site's files.
    @Test(.timeLimit(.minutes(1)))
    func perSiteMountsTakePrecedenceForTheirSite() async throws {
        let temp = try Self.temporaryDirectory("proxy-hosts")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        for name in ["site-up/api", "server-up/api", "a", "fallback"] {
            try fm.createDirectory(at: temp.appending(path: name), withIntermediateDirectories: true)
        }
        try Data("site\n".utf8).write(to: temp.appending(path: "site-up/api/who.txt"))
        try Data("server\n".utf8).write(to: temp.appending(path: "server-up/api/who.txt"))
        try Data("a index\n".utf8).write(to: temp.appending(path: "a/index.html"))
        try Data("fallback index\n".utf8).write(to: temp.appending(path: "fallback/index.html"))

        let siteUp = try ParityTests.launch(["--root", temp.appending(path: "site-up").path, "--port", "0"])
        defer { siteUp.kill() }
        let serverUp = try ParityTests.launch(["--root", temp.appending(path: "server-up").path, "--port", "0"])
        defer { serverUp.kill() }
        let sitePort = try await siteUp.listeningPort()
        let serverPort = try await serverUp.listeningPort()

        let config = temp.appending(path: "http-config.json")
        try Data("""
        {
          "host": "127.0.0.1",
          "port": 0,
          "proxy": [{ "path": "/api", "upstream": "http://127.0.0.1:\(serverPort)" }],
          "hosts": [
            { "names": ["a.test"], "root": "a",
              "proxy": [{ "path": "/api", "upstream": "http://127.0.0.1:\(sitePort)" }] },
            { "default": true, "root": "fallback" }
          ]
        }
        """.utf8).write(to: config)
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let base = "http://127.0.0.1:\(try await server.listeningPort())"
        #expect(!server.stderr.contains("warning"), "\(server.stderr)")

        let client = Self.clients[0]
        var reply = try await request(client, "\(base)/api/who.txt", ["-H", "Host: a.test"])
        #expect(reply.status == 200 && reply.body == "site\n", "\(reply)")
        reply = try await request(client, "\(base)/api/who.txt", ["-H", "Host: other.test"])
        #expect(reply.status == 200 && reply.body == "server\n", "\(reply)")
        reply = try await request(client, "\(base)/", ["-H", "Host: a.test"])
        #expect(reply.body == "a index\n", "\(reply)")
        reply = try await request(client, "\(base)/", ["-H", "Host: other.test"])
        #expect(reply.body == "fallback index\n", "\(reply)")

        server.kill()
        siteUp.kill()
        serverUp.kill()
    }

    // MARK: Config errors

    @Test(.timeLimit(.minutes(1)), arguments: [
        (#"{"port": 0, "proxy": [{"path": "/api", "upstream": "https://127.0.0.1:9000"}]}"#, "\"proxy[0].upstream\""),
        (#"{"port": 0, "proxy": [{"path": "api", "upstream": "http://127.0.0.1:9000"}]}"#, "\"proxy[0].path\""),
        (#"{"port": 0, "proxy": [{"path": "/api"}]}"#, "\"proxy[0]\""),
        (#"{"port": 0, "proxy": [{"path": "/api", "upstream": "http://127.0.0.1:9000", "forwardedHeaders": "all"}]}"#,
         "\"proxy[0].forwardedHeaders\""),
        (#"{"port": 0, "hosts": [{"names": ["a.test"], "root": "Public", "proxy": [{"upstream": "unix:"}]}]}"#,
         "\"hosts[0].proxy[0].upstream\""),
    ])
    func proxyConfigErrorsExitOneNamingTheKey(config: String, key: String) async throws {
        let fixture = try ParityTests.Fixture(config: config)
        let server = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { server.kill() }
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 1, "\(server.stdout)")
        #expect(server.stderr.contains(key), "\(server.stderr)")
    }
}
