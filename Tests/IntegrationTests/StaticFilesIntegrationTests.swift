import Foundation
import HTTPTestSupport
import Testing

/// StaticFiles (#0084) over real TCP on 127.0.0.1 port 0: `sws-bench serve --root DIR` with
/// curl as the client, on both cleartext transports.
@Suite struct StaticFilesIntegrationTests {
    enum Transport: String, CaseIterable, Sendable { case bsd, nw }

    final class Tree {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "sws-staticfiles-it-\(UInt64.random(in: 0...UInt64.max))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    func curl(_ arguments: [String]) async throws -> (Int32, String) {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), arguments,
                                                timeout: .seconds(60), mergeStandardError: true)
        return (output.status, output.stdout)
    }

    /// The acceptance checks: `curl -r 0-99` gets 206 with 100 bytes, `curl -X POST` gets 405
    /// with `Allow`, traversal gets 403, a directory gets its redirect and index.
    @Test(.timeLimit(.minutes(1)), arguments: Transport.allCases)
    func curlRangePostAndTraversal(_ transport: Transport) async throws {
        let tree = try Tree()
        let content = Data((0..<1000).map { UInt8($0 % 256) })
        try content.write(to: tree.root.appending(path: "data.bin"))
        try FileManager.default.createDirectory(at: tree.root.appending(path: "docs"), withIntermediateDirectories: true)
        try Data("<h1>docs</h1>".utf8).write(to: tree.root.appending(path: "docs/index.html"))

        let serve = try ChildProcess.launch(["serve", "--port", "0", "--transport", transport.rawValue,
                                             "--root", tree.root.path, "--drain-timeout", "0.5"])
        defer { serve.kill() }
        let base = "http://127.0.0.1:\(try await serve.listeningPort())"

        var (status, output) = try await curl(["-sS", "-i", "--max-time", "10", "-r", "0-99", "\(base)/data.bin"])
        #expect(status == 0, "\(output)")
        #expect(output.hasPrefix("HTTP/1.1 206 Partial Content"), "\(output)")
        #expect(output.contains("content-range: bytes 0-99/1000"))
        #expect(output.contains("content-length: 100\r\n"))

        (status, output) = try await curl(["-sS", "-i", "--max-time", "10", "-X", "POST", "\(base)/data.bin"])
        #expect(output.hasPrefix("HTTP/1.1 405 Method Not Allowed"), "\(output)")
        #expect(output.contains("allow: GET, HEAD"))

        (status, output) = try await curl(["-sS", "-i", "--max-time", "10", "--path-as-is", "\(base)/../etc/passwd"])
        #expect(output.hasPrefix("HTTP/1.1 403 Forbidden"), "\(output)")
        (status, output) = try await curl(["-sS", "-i", "--max-time", "10", "--path-as-is", "\(base)/%2e%2e/%2e%2e/etc/passwd"])
        #expect(output.hasPrefix("HTTP/1.1 403 Forbidden"), "\(output)")

        (status, output) = try await curl(["-sS", "-i", "--max-time", "10", "\(base)/docs"])
        #expect(output.hasPrefix("HTTP/1.1 301 Moved Permanently"), "\(output)")
        #expect(output.contains("location: /docs/"))
        (status, output) = try await curl(["-sS", "-L", "--max-time", "10", "\(base)/docs"])
        #expect(output == "<h1>docs</h1>")

        (status, output) = try await curl(["-sS", "-I", "--max-time", "10", "\(base)/data.bin"])
        #expect(output.hasPrefix("HTTP/1.1 200 OK"), "\(output)")
        #expect(output.contains("content-length: 1000\r\n"))
        #expect(output.contains("etag: \""))

        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    /// A 48 MiB random file streams intact (SHA-256 of what curl saved equals the file's).
    @Test(.timeLimit(.minutes(2)), arguments: Transport.allCases)
    func largeFileStreamsIntact(_ transport: Transport) async throws {
        let tree = try Tree()
        let file = tree.root.appending(path: "large.bin")
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 48 * 1024 * 1024 + 123)
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices { words[i] = generator.next() }
        }
        try Data(bytes).write(to: file)
        let output = tree.root.appending(path: "download.bin")

        let serve = try ChildProcess.launch(["serve", "--port", "0", "--transport", transport.rawValue,
                                             "--root", tree.root.path, "--drain-timeout", "0.5"])
        defer { serve.kill() }
        let port = try await serve.listeningPort()
        let (status, log) = try await curl(["-sS", "--max-time", "60", "-o", output.path,
                                            "http://127.0.0.1:\(port)/large.bin"])
        #expect(status == 0, "\(log)")
        let expected = try await sha256(file)
        #expect(try await sha256(output) == expected)

        // The tail through a range.
        let (rangeStatus, _) = try await curl(["-sS", "--max-time", "60", "-r", "50000000-", "-o", output.path,
                                               "http://127.0.0.1:\(port)/large.bin"])
        #expect(rangeStatus == 0)
        #expect(try Data(contentsOf: output) == Data(bytes[50_000_000...]))

        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    /// Acceptance: serving a 1 GiB file keeps the server's RSS within 32 MiB of idle. The file
    /// is sparse, so it costs no disk.
    @Test(.timeLimit(.minutes(2)))
    func oneGiBFileKeepsMemoryFlat() async throws {
        let tree = try Tree()
        let file = tree.root.appending(path: "huge.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        try Data("x".utf8).write(to: tree.root.appending(path: "small.txt"))

        let serve = try ChildProcess.launch(["serve", "--port", "0", "--root", tree.root.path, "--drain-timeout", "0.5"])
        defer { serve.kill() }
        let port = try await serve.listeningPort()
        _ = try await curl(["-sS", "--max-time", "10", "-o", "/dev/null", "http://127.0.0.1:\(port)/small.txt"])
        let idle = try await rss(serve.pid)

        let download = try ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                                        arguments: ["-sS", "--max-time", "90", "-o", "/dev/null", "-w", "%{size_download}",
                                                    "http://127.0.0.1:\(port)/huge.bin"])
        defer { download.kill() }
        var peak = idle
        while download.exitStatus == nil {
            peak = max(peak, try await rss(serve.pid))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await download.waitForExit(timeout: .seconds(90)) == 0)
        #expect(download.stdout == "\(1 << 30)")
        peak = max(peak, try await rss(serve.pid))
        print("StaticFiles 1 GiB: idle RSS \(idle / 1024) MiB, peak \(peak / 1024) MiB")
        #expect(peak - idle < 32 * 1024, "RSS grew from \(idle) KiB to \(peak) KiB")

        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    /// Resident set size of `pid` in KiB (`ps -o rss=`).
    func rss(_ pid: Int32) async throws -> Int {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "rss=", "-p", "\(pid)"],
                                                timeout: .seconds(10))
        return Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func sha256(_ url: URL) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", url.path],
                                                timeout: .seconds(30))
        return String(output.stdout.prefix(64))
    }
}
