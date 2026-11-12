import Foundation
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// Parity with the legacy server (#0086): the shipped `SwiftWebServer` binary, launched as a
/// child process on 127.0.0.1 port 0, passes the repro steps of legacy issues #0003–#0025
/// and keeps every legacy behaviour still worth having (GET, HEAD, index files, MIME types,
/// ETag and 304, 405 with Allow, blocked paths, traversal, signals, config errors).
///
/// Every child is SIGKILLed on every exit path (`ChildProcess`, #0114). Clients are curl and
/// raw loopback sockets.
@Suite struct ParityTests {
    // MARK: Fixture

    /// A temporary server root: `http-config.json`, `Public/` with test files, and an
    /// `outside/` directory next to `Public/` that must never be served.
    final class Fixture {
        let root: URL
        var publicDirectory: URL { root.appending(path: "Public") }
        var configPath: String { root.appending(path: "http-config.json").path }

        init(config: String = "{}") throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "sws-parity-\(UInt64.random(in: 0...UInt64.max))")
            let fm = FileManager.default
            try fm.createDirectory(at: root.appending(path: "Public/sub folder"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appending(path: "Public/.git"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appending(path: "outside"), withIntermediateDirectories: true)
            try write("<h1>home</h1>", "Public/index.html")
            try write("<h1>sub</h1>", "Public/sub folder/index.html")
            try write("body { color: red }", "Public/style.css")
            try write("{\"a\": 1}", "Public/data.json")
            try write("binary?", "Public/blob.unknownext")
            try write("hi\n", "Public/100%25.txt")
            try write("junk", "Public/.DS_Store")
            try write("[core]", "Public/.git/config")
            try write("secret", "outside/secret.txt")
            try write("locked", "Public/locked.txt")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.appending(path: "Public/locked.txt").path)
            try fm.createSymbolicLink(atPath: root.appending(path: "Public/escape").path, withDestinationPath: "../outside")
            let png = ParityTests.packageRoot.appending(path: "Root/Public/swift.png")
            try fm.copyItem(at: png, to: root.appending(path: "Public/swift.png"))
            try write(config, "http-config.json")
        }

        func write(_ text: String, _ relative: String) throws {
            try Data(text.utf8).write(to: root.appending(path: relative))
        }

        deinit {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: root.appending(path: "Public/locked.txt").path)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The `SwiftWebServer` executable next to the test bundle, or in `.build/debug`.
    static func binary() throws -> URL {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appending(path: "SwiftWebServer"))
        }
        candidates.append(packageRoot.appending(path: ".build/debug/SwiftWebServer"))
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ChildProcess.Failure.executableNotFound(candidates.map(\.path))
        }
        return found
    }

    /// Starts `SwiftWebServer` with `arguments`; `environment` entries are set through
    /// `/usr/bin/env`, which execs the server (so the child's pid is the server's).
    static func launch(_ arguments: [String], environment: [String: String] = [:]) throws -> ChildProcess {
        let server = try binary()
        if environment.isEmpty { return try ChildProcess(executable: server, arguments: arguments) }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return try ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                arguments: assignments + [server.path] + arguments)
    }

    /// Starts the server on `fixture` (its config, port 0) and returns it with its base URL.
    static func serve(_ fixture: Fixture, _ extra: [String] = []) async throws -> (ChildProcess, String) {
        let child = try launch(["--config", fixture.configPath, "--port", "0"] + extra)
        do {
            let port = try await child.listeningPort()
            return (child, "http://127.0.0.1:\(port)")
        } catch {
            child.kill()
            throw error
        }
    }

    func curl(_ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sS", "--max-time", "10"] + arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return output.stdout
    }

    /// The value of `name` (lowercase) in a `curl -i` / `-I` head.
    func header(_ name: String, in output: String) -> String? {
        for line in output.split(separator: "\r\n") where line.lowercased().hasPrefix(name + ": ") {
            return String(line.dropFirst(name.count + 2))
        }
        return nil
    }

    /// The body after the head of a `curl -i` output.
    func body(_ output: String) -> String {
        guard let range = output.range(of: "\r\n\r\n") else { return "" }
        return String(output[range.upperBound...])
    }

    // MARK: Legacy behaviours worth keeping

    /// The shipped `Root/http-config.json` serves `Root/Public`: index, MIME, sub-folder index,
    /// custom error pages, 405 with `Allow`, and a blocked config file.
    @Test(.timeLimit(.minutes(1)))
    func shippedConfigServesRootPublic() async throws {
        let child = try Self.launch(["--config", Self.packageRoot.appending(path: "Root/http-config.json").path, "--port", "0"])
        defer { child.kill() }
        let base = "http://127.0.0.1:\(try await child.listeningPort())"
        #expect(!child.stderr.contains("warning"), "\(child.stderr)")

        var output = try await curl(["-i", "\(base)/"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "\(output)")
        #expect(header("content-type", in: output) == "text/html")
        output = try await curl(["-I", "\(base)/swift.png"])
        #expect(header("content-type", in: output) == "image/png", "\(output)")
        output = try await curl(["-i", "\(base)/sub%20folder/"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "\(output)")
        output = try await curl(["-i", "\(base)/Tab1/"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "\(output)")
        output = try await curl(["-i", "\(base)/missing.html"])
        #expect(output.hasPrefix("HTTP/1.1 404 Not Found"), "\(output)")
        #expect(body(output).contains("HTTP Status 404"), "custom page from Custom/404.html")
        output = try await curl(["-i", "-X", "POST", "\(base)/"])
        #expect(output.hasPrefix("HTTP/1.1 405 Method Not Allowed"), "\(output)")
        #expect(header("allow", in: output) == "GET, HEAD")
        output = try await curl(["-i", "\(base)/http-config.json"])
        #expect(output.hasPrefix("HTTP/1.1 403 Forbidden"), "\(output)")

        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0)
    }

    /// GET, HEAD (#0016), index, MIME, Date and Connection (#0020), 405 + Allow (#0022), error
    /// page bodies but never on 304 (#0018).
    @Test(.timeLimit(.minutes(1)))
    func getHeadIndexMIMEAndHeaders() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }

        var output = try await curl(["-i", "\(base)/"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "\(output)")
        #expect(body(output) == "<h1>home</h1>")
        #expect(header("date", in: output) != nil, "#0020 Date")
        #expect(header("content-length", in: output) == "13")
        #expect(header("cache-control", in: output) == "public, max-age=3600")

        output = try await curl(["-i", "\(base)/sub%20folder/"])
        #expect(body(output) == "<h1>sub</h1>", "\(output)")
        output = try await curl(["-i", "\(base)/sub%20folder"])
        #expect(output.hasPrefix("HTTP/1.1 301"), "\(output)")

        for (path, type) in [("style.css", "text/css"), ("data.json", "application/json"),
                             ("swift.png", "image/png"), ("blob.unknownext", "application/octet-stream")] {
            output = try await curl(["-I", "\(base)/\(path)"])
            #expect(header("content-type", in: output) == type, "\(path): \(output)")
        }

        // #0016: HEAD has the GET head and no body.
        let head = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                              ["-s", "-X", "HEAD", "--max-time", "2", "\(base)/index.html"])
        #expect(head.stdout.isEmpty, "HEAD body: \(head.stdout)")
        output = try await curl(["-I", "\(base)/index.html"])
        #expect(header("content-length", in: output) == "13")

        // #0020: Connection: close is honoured and stated.
        output = try await curl(["-i", "-H", "Connection: close", "\(base)/"])
        #expect(header("connection", in: output) == "close", "\(output)")

        // #0022: 405 with Allow.
        output = try await curl(["-i", "-X", "POST", "\(base)/"])
        #expect(output.hasPrefix("HTTP/1.1 405 Method Not Allowed"), "\(output)")
        #expect(header("allow", in: output) == "GET, HEAD")
        #expect(body(output).contains("405"), "generated error page")

        output = try await curl(["-i", "\(base)/nothing-here"])
        #expect(output.hasPrefix("HTTP/1.1 404 Not Found"))
        #expect(body(output).contains("<h1>404 Not Found</h1>"))
    }

    /// ETag and conditional requests: #0017 (If-Modified-Since), #0018 (304 has no body),
    /// #0019 (If-None-Match lists and `*`, precedence over If-Modified-Since), #0025 (the ETag
    /// is metadata, stable across requests).
    @Test(.timeLimit(.minutes(1)))
    func etagAndNotModified() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }

        let first = try await curl(["-I", "\(base)/index.html"])
        let etag = try #require(header("etag", in: first))
        let lastModified = try #require(header("last-modified", in: first))
        #expect(etag.hasPrefix("\"") && etag.hasSuffix("\""), "strong ETag: \(etag)")
        #expect(header("etag", in: try await curl(["-I", "\(base)/index.html"])) == etag)

        var output = try await curl(["-i", "\(base)/index.html", "-H", "If-None-Match: \(etag)"])
        #expect(output.hasPrefix("HTTP/1.1 304 Not Modified"), "\(output)")
        #expect(body(output).isEmpty, "#0018: \(output)")
        #expect(header("etag", in: output) == etag)

        output = try await curl(["-i", "\(base)/index.html", "-H", "If-Modified-Since: \(lastModified)"])
        #expect(output.hasPrefix("HTTP/1.1 304 Not Modified"), "#0017: \(output)")

        output = try await curl(["-i", "\(base)/index.html", "-H", "If-None-Match: W/\"stale\", \(etag)"])
        #expect(output.hasPrefix("HTTP/1.1 304 Not Modified"), "#0019 list: \(output)")
        output = try await curl(["-i", "\(base)/index.html", "-H", "If-None-Match: *"])
        #expect(output.hasPrefix("HTTP/1.1 304 Not Modified"), "#0019 *: \(output)")
        output = try await curl(["-i", "\(base)/index.html", "-H", "If-None-Match: \"stale\"",
                                 "-H", "If-Modified-Since: \(lastModified)"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "#0019 If-None-Match wins: \(output)")
    }

    /// #0013 block list and dotfiles, #0014 traversal and symlinks, #0015 decode once,
    /// #0009 an unreadable file still gets a reply.
    @Test(.timeLimit(.minutes(1)))
    func blockedPathsTraversalAndDecoding() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }

        for path in ["/.DS_Store", "/.git/config", "/.ds_store", "/http-config.json"] {
            let output = try await curl(["-i", "\(base)\(path)"])
            #expect(output.hasPrefix("HTTP/1.1 403 Forbidden"), "#0013 \(path): \(output)")
        }
        for path in ["/../outside/secret.txt", "/%2e%2e/outside/secret.txt", "/escape/secret.txt",
                     "/sub%20folder/../../outside/secret.txt"] {
            let output = try await curl(["-i", "--path-as-is", "\(base)\(path)"])
            #expect(output.hasPrefix("HTTP/1.1 403 Forbidden"), "#0014 \(path): \(output)")
            #expect(!output.contains("secret\n") && !body(output).hasPrefix("secret"))
        }

        var output = try await curl(["-i", "\(base)/100%2525.txt"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "#0015: \(output)")
        #expect(body(output) == "hi\n")

        output = try await curl(["-i", "\(base)/locked.txt"])
        #expect(output.hasPrefix("HTTP/1.1 4") || output.hasPrefix("HTTP/1.1 5"), "#0009: \(output)")
        output = try await curl(["-i", "\(base)/"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "still serving: \(output)")
    }

    // MARK: Connection handling

    /// #0006 a head split across writes is answered once complete, #0007 the next request on
    /// the connection (and a pipelined pair) is answered too, #0021 conflicting Content-Length
    /// is refused.
    @Test(.timeLimit(.minutes(1)))
    func splitHeadsPipeliningAndFraming() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }
        let port = UInt16(base.split(separator: ":").last!)!

        let client = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(client, "GET /index.html HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(300))
        try await send(client, "Host: localhost\r\n\r\n")
        var responses = await read(client, responses: 1)
        #expect(responses.map(\.status) == [200], "#0006")
        #expect(responses.first?.body == "<h1>home</h1>")

        try await send(client, "GET /style.css HTTP/1.1\r\nHost: x\r\n\r\nHEAD / HTTP/1.1\r\nHost: x\r\n\r\n")
        responses = await read(client, responses: 2, headOnlyLast: true)
        #expect(responses.map(\.status) == [200, 200], "#0007")
        await client.close(.normal)

        let conflict = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(conflict, "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab")
        responses = await read(conflict, responses: 1)
        #expect(responses.map(\.status) == [400], "#0021")
        await conflict.close(.normal)
    }

    /// #0011: request bodies and heads are bounded (`maxBodySize`, parser limits).
    @Test(.timeLimit(.minutes(1)))
    func oversizedRequestsAreRefused() async throws {
        let fixture = try Fixture(config: #"{"maxBodySize": 1000, "drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }
        let port = UInt16(base.split(separator: ":").last!)!

        let body = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(body, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n\r\n")
        #expect(await read(body, responses: 1).map(\.status) == [413])
        await body.close(.normal)

        let head = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(head, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: \(String(repeating: "a", count: 128 * 1024))\r\n\r\n")
        #expect(await read(head, responses: 1).map(\.status) == [431])
        await head.close(.normal)
    }

    /// #0012: an idle connection is closed after `timeouts.idle` (legacy `keepAliveTimeout`).
    @Test(.timeLimit(.minutes(1)))
    func idleConnectionsTimeOut() async throws {
        let fixture = try Fixture(config: #"{"keepAliveTimeout": 0.3, "drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }
        let port = UInt16(base.split(separator: ":").last!)!

        let client = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        let start = ContinuousClock.now
        #expect(await peerClosed(client))
        #expect(ContinuousClock.now - start < .seconds(3))
        await client.close(.normal)
    }

    /// #0024: `maxConnections` is enforced; the next connection is served once one closes.
    @Test(.timeLimit(.minutes(1)))
    func maxConnectionsIsEnforced() async throws {
        let fixture = try Fixture(config: #"{"maxConnections": 1, "drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }
        let port = UInt16(base.split(separator: ":").last!)!

        let first = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(first, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(await read(first, responses: 1).map(\.status) == [200])

        let second = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(second, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        async let answer = { () async -> ([Int], ContinuousClock.Instant) in
            let statuses = await read(second, responses: 1, timeout: .seconds(10)).map(\.status)
            return (statuses, ContinuousClock.now)
        }()
        try await Task.sleep(for: .milliseconds(400))
        let released = ContinuousClock.now
        await first.close(.normal)
        let (statuses, answeredAt) = await answer
        #expect(statuses == [200])
        #expect(answeredAt >= released, "the second connection is held while the first is open")
        await second.close(.normal)
    }

    /// #0008, #0010: clients that connect and vanish, or reset mid-request, do not disturb the
    /// server.
    @Test(.timeLimit(.minutes(1)))
    func abortedClientsDoNotDisturbTheServer() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }
        let port = UInt16(base.split(separator: ":").last!)!

        for index in 0..<20 {
            let client = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
            if index % 2 == 0 { try await send(client, "GET /index.html HTTP/1.1\r\nHo") }
            await client.close(.abort)
        }
        let output = try await curl(["-i", "\(base)/"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "\(output)")
        #expect(child.exitStatus == nil)
    }

    /// #0025: a large file is streamed from disk, not read into memory (and not hashed).
    @Test(.timeLimit(.minutes(1)))
    func largeFileIsStreamedWithFlatMemory() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let size: UInt64 = 256 * 1024 * 1024
        let large = fixture.publicDirectory.appending(path: "large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: size)   // sparse: no disk use
        try handle.close()

        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }

        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sS", "--max-time", "40", "-o", "/dev/null", "-w", "%{http_code} %{size_download}",
                                                 "\(base)/large.bin"], timeout: .seconds(45))
        #expect(output.stdout == "200 \(size)", "\(output.stdout) \(output.stderr)")
        let rss = try await ChildProcess.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "rss=", "-p", "\(child.pid)"])
        let kilobytes = Int(rss.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .max
        #expect(kilobytes < 96 * 1024, "server RSS \(kilobytes) KiB after a 256 MiB download")
    }

    // MARK: Lifecycle and configuration

    /// #0003: SIGTERM drains (an idle keep-alive connection is closed) and exits 0; #0005: a
    /// second signal during the drain is harmless.
    @Test(.timeLimit(.minutes(1)))
    func sigtermDrainsAndExitsZero() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (child, base) = try await Self.serve(fixture)
        defer { child.kill() }
        let port = UInt16(base.split(separator: ":").last!)!

        let client = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        try await send(client, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(await read(client, responses: 1).map(\.status) == [200])

        let start = ContinuousClock.now
        child.signal(SIGTERM)
        child.signal(SIGTERM)
        child.signal(SIGINT)
        let status = try await child.waitForExit(timeout: .seconds(5))
        #expect(status == 0, "stderr: \(child.stderr)")
        #expect(child.terminationReason == .exit)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await peerClosed(client))
        await client.close(.normal)
    }

    /// #0003 with the legacy launch: `ROOT_PATH` names the directory holding
    /// `http-config.json`; `{"port": 0}` alone is a complete config (#0023); SIGINT exits 0.
    @Test(.timeLimit(.minutes(1)))
    func rootPathEnvironmentAndMinimalConfig() async throws {
        let fixture = try Fixture(config: #"{"port": 0, "colour": "blue"}"#)
        let child = try Self.launch([], environment: ["ROOT_PATH": fixture.root.path])
        defer { child.kill() }
        let base = "http://127.0.0.1:\(try await child.listeningPort())"
        let output = try await curl(["-i", "\(base)/"])
        #expect(body(output) == "<h1>home</h1>", "\(output)")
        #expect(child.stderr.contains("unknown key \"colour\""), "#0023 unknown keys warn: \(child.stderr)")

        child.signal(SIGINT)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "stderr: \(child.stderr)")
    }

    /// Command-line flags override the config file.
    @Test(.timeLimit(.minutes(1)))
    func flagsOverrideTheConfig() async throws {
        let fixture = try Fixture(config: #"{"host": "::1", "port": 1, "root": "nowhere"}"#)
        let child = try Self.launch(["--config", fixture.configPath, "--host", "127.0.0.1", "--port", "0",
                                     "--root", fixture.publicDirectory.appending(path: "sub folder").path])
        defer { child.kill() }
        let base = "http://127.0.0.1:\(try await child.listeningPort())"
        #expect(body(try await curl(["-i", "\(base)/"])) == "<h1>sub</h1>")
        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0)
    }

    /// #0004: startup failures exit 1 promptly with a message on stderr.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (#"{"port": "eighty"}"#, "\"port\""),
        (#"{"timeouts": {"idle": -1}}"#, "\"timeouts.idle\""),
        ("{ not json", "not valid JSON"),
        (#"{"port": 0, "root": "missing"}"#, "cannot serve root"),
        (#"{"port": 0, "errorPages": {"404": "nope.html"}}"#, "errorPages.404"),
    ])
    func badConfigExitsOne(config: String, message: String) async throws {
        let fixture = try Fixture(config: config)
        let start = ContinuousClock.now
        let child = try Self.launch(["--config", fixture.configPath])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(5)) == 1)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(child.stderr.contains(message), "stderr: \(child.stderr)")
        #expect(child.stdout.isEmpty)
    }

    /// #0004 repro: `ROOT_PATH=/nonexistent` exits 1 instead of hanging; so do a missing
    /// `--config` file and a usage error (2).
    @Test(.timeLimit(.minutes(1)))
    func missingRootPathOrConfigExitsOne() async throws {
        let missing = "/nonexistent/sws-\(UInt64.random(in: 0...UInt64.max))"
        var child = try Self.launch(["--port", "0"], environment: ["ROOT_PATH": missing])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(5)) == 1)
        #expect(child.stderr.contains("cannot serve root"), "\(child.stderr)")

        child = try Self.launch(["--config", "\(missing)/http-config.json"])
        #expect(try await child.waitForExit(timeout: .seconds(5)) == 1)
        #expect(child.stderr.contains("cannot read config file"), "\(child.stderr)")

        child = try Self.launch(["--bogus"])
        #expect(try await child.waitForExit(timeout: .seconds(5)) == 2)
        #expect(child.stderr.contains("unknown argument"), "\(child.stderr)")
    }

    /// #0004: a port in use exits 1 with the reason.
    @Test(.timeLimit(.minutes(1)))
    func portInUseExitsOne() async throws {
        let fixture = try Fixture(config: #"{"drainTimeout": 0.5}"#)
        let (holder, base) = try await Self.serve(fixture)
        defer { holder.kill() }
        let port = base.split(separator: ":").last!

        let clash = try Self.launch(["--config", fixture.configPath, "--port", String(port)])
        defer { clash.kill() }
        #expect(try await clash.waitForExit(timeout: .seconds(5)) == 1)
        #expect(clash.stderr.contains("cannot serve on"), "\(clash.stderr)")

        holder.signal(SIGTERM)
        #expect(try await holder.waitForExit(timeout: .seconds(5)) == 0)
    }

    // MARK: Raw HTTP/1.1 over a socket

    struct Response {
        var status: Int
        var head: String
        var body: String
    }

    func send(_ transport: BSDSocketTransport, _ text: String) async throws {
        var buffer = ByteBuffer()
        buffer.append(contentsOf: Array(text.utf8))
        try await transport.send(buffer, endOfStream: false)
    }

    /// Reads up to `count` complete responses (framed by `Content-Length`; the last one has no
    /// body when `headOnlyLast`), stopping early at end of stream, an error, or `timeout`.
    func read(_ transport: BSDSocketTransport, responses count: Int, headOnlyLast: Bool = false,
              timeout: Duration = .seconds(5)) async -> [Response] {
        let collected = ResponseCollector()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var received = ByteBuffer()
                var bytes: [UInt8] = []
                while collected.count < count {
                    do {
                        received.clear()
                        if try await transport.receive(into: &received, maxLength: 64 * 1024) == 0 { return }
                    } catch {
                        return
                    }
                    received.withReadableSpan { span in
                        for index in 0..<span.count { bytes.append(span[index]) }
                    }
                    while collected.count < count,
                          let response = Self.parse(&bytes, headOnly: headOnlyLast && collected.count == count - 1) {
                        collected.append(response)
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        return collected.responses
    }

    /// Removes one complete response from the front of `bytes`.
    static func parse(_ bytes: inout [UInt8], headOnly: Bool) -> Response? {
        let separator: [UInt8] = Array("\r\n\r\n".utf8)
        guard bytes.count >= 4,
              let end = (0...(bytes.count - 4)).first(where: { Array(bytes[$0..<$0 + 4]) == separator }) else { return nil }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        let lines = head.split(separator: "\r\n")
        guard let statusLine = lines.first, statusLine.count >= 12,
              let status = Int(statusLine.dropFirst(9).prefix(3)) else { return nil }
        var length = 0
        if !headOnly {
            for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard bytes.count >= end + 4 + length else { return nil }
        let body = String(decoding: bytes[(end + 4)..<(end + 4 + length)], as: UTF8.self)
        bytes.removeFirst(end + 4 + length)
        return Response(status: status, head: head, body: body)
    }
}

/// Responses read so far, shared between the reading task and the caller.
final class ResponseCollector: Sendable {
    private let stored = Mutex<[ParityTests.Response]>([])

    var count: Int { stored.withLock { $0.count } }
    var responses: [ParityTests.Response] { stored.withLock { $0 } }
    func append(_ response: ParityTests.Response) { stored.withLock { $0.append(response) } }
}

extension ParityTests.Response: Sendable {}
