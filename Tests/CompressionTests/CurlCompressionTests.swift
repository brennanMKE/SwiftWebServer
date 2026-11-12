import Compression
import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import StaticFiles
import Testing

/// #0091 acceptance end to end: a real `Server` on loopback port 0 with `Compression` in
/// front of `StaticFiles`, driven by the system curl (`--compressed` sends
/// `Accept-Encoding: deflate, gzip` and decodes the body).
@Suite(.timeLimit(.minutes(1)))
struct CurlCompressionTests {
    static func withServer(_ site: Site, configure: (inout StaticFilesConfiguration) -> Void = { _ in },
                           _ body: @Sendable (UInt16) async throws -> Void) async throws {
        var configuration = StaticFilesConfiguration()
        configuration.compression = CompressionConfiguration()
        configuration.smallFileLimit = 64 * 1024
        configure(&configuration)
        let files = try StaticFiles(root: site.root.path, configuration: configuration)
        let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 0))
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(2)),
                            listeners: [listener], protocols: [HTTP1()]) {
            Compression()
            asHandler(files)
        }
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address")
                return
            }
            try await body(port)
            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    /// Runs curl; returns its exit status, the response head (`-D`) and the body file's bytes.
    static func curl(_ arguments: [String], site: Site) async throws -> (status: Int32, head: String, body: [UInt8]) {
        let headFile = site.base.appending(path: "head-\(UInt64.random(in: 0...UInt64.max))")
        let bodyFile = site.base.appending(path: "body-\(UInt64.random(in: 0...UInt64.max))")
        let output = try await ChildProcess.run(
            URL(fileURLWithPath: "/usr/bin/curl"),
            ["-sS", "--max-time", "20", "-D", headFile.path, "-o", bodyFile.path] + arguments,
            timeout: .seconds(30), mergeStandardError: true)
        let head = (try? String(contentsOf: headFile, encoding: .utf8)) ?? ""
        let body = (try? Data(contentsOf: bodyFile)).map { [UInt8]($0) } ?? []
        #expect(output.status == 0, "\(output.stdout)")
        return (output.status, head.lowercased(), body)
    }

    @Test func curlCompressedGetsGzipAndTheFile() async throws {
        let site = try Site()
        let page = sampleText(50 * 1024, seed: 1)
        try site.write("index.html", page)
        try await Self.withServer(site) { port in
            let url = "http://127.0.0.1:\(port)/index.html"
            let compressed = try await Self.curl(["--compressed", url], site: site)
            #expect(compressed.head.contains("content-encoding: gzip"), "\(compressed.head)")
            #expect(compressed.head.contains("vary: accept-encoding"))
            #expect(compressed.head.contains("etag: \"") && compressed.head.contains("-gz\""))
            #expect(compressed.body == page, "curl decoded the body to the file")

            // Without --compressed: the file as it is.
            let plain = try await Self.curl([url], site: site)
            #expect(!plain.head.contains("content-encoding"))
            #expect(plain.head.contains("vary: accept-encoding"))
            #expect(plain.body == page)

            // br, raw: decoded here with libcompression.
            let brotli = try await Self.curl(["-H", "Accept-Encoding: br", url], site: site)
            #expect(brotli.head.contains("content-encoding: br"))
            #expect(ContentCodec.decode(brotli.body, .brotli) == page)

            // A 206 is not compressed.
            let range = try await Self.curl(["--compressed", "-H", "Range: bytes=100-1099", url], site: site)
            #expect(range.head.hasPrefix("http/1.1 206"), "\(range.head)")
            #expect(!range.head.contains("content-encoding"))
            #expect(range.body == Array(page[100..<1100]))

            // Revalidating the gzip variant: 304.
            let tag = try #require(compressed.head.split(separator: "\r\n").first { $0.hasPrefix("etag:") })
                .dropFirst("etag:".count).trimmingCharacters(in: .whitespaces)
            let revalidated = try await Self.curl(["--compressed", "-H", "If-None-Match: \(tag)", url], site: site)
            #expect(revalidated.head.hasPrefix("http/1.1 304"), "\(revalidated.head)")

            // HEAD carries the variant's headers and no body.
            let head = try await Self.curl(["--compressed", "-I", url], site: site)
            #expect(head.head.contains("content-encoding: gzip"))
        }
    }

    @Test func largeFileIsStreamedChunked() async throws {
        let site = try Site()
        let big = sampleText(4 * 1024 * 1024, seed: 2)
        try site.write("big.txt", big)
        try await Self.withServer(site) { port in
            let url = "http://127.0.0.1:\(port)/big.txt"
            let result = try await Self.curl(["--compressed", url], site: site)
            #expect(result.head.contains("content-encoding: gzip"), "\(result.head)")
            #expect(result.head.contains("transfer-encoding: chunked"))
            #expect(!result.head.contains("content-length"))
            #expect(result.body == big)
            // HTTP/1.0 has no chunked framing: the body ends with the connection.
            let old = try await Self.curl(["--compressed", "--http1.0", url], site: site)
            #expect(old.body == big)
        }
    }

    @Test func sidecarIsServedOverTheWire() async throws {
        let site = try Site()
        let page = sampleText(20_000, seed: 4)
        try site.write("app.js", page, modified: Date(timeIntervalSinceNow: -60))
        let gz = try #require(ContentCodec.encode(ByteBuffer(bytes: page), .gzip, level: 9)).withUnsafeReadableBytes { Array($0) }
        try site.write("app.js.gz", gz)
        try await Self.withServer(site) { port in
            let raw = try await Self.curl(["-H", "Accept-Encoding: gzip", "http://127.0.0.1:\(port)/app.js"], site: site)
            #expect(raw.body == gz)
            let decoded = try await Self.curl(["--compressed", "http://127.0.0.1:\(port)/app.js"], site: site)
            #expect(decoded.body == page)
        }
    }
}
