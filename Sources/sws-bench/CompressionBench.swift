import Compression
import Foundation
import HTTPCore
import StaticFiles

/// Compression microbenchmarks (#0091). Select with `sws-bench micro --filter Compression`.
///
/// - `Compression.hit …`: a StaticFiles cache hit on a 50 KiB HTML file, without
///   precompression, and with it for each negotiated variant: the cached-variant cost should
///   be the uncompressed hit plus the `Accept-Encoding` parse.
/// - `Compression.dynamic …`: the middleware compressing that page per response (one-shot
///   `.bytes`), the CPU a response costs without the cache.
/// - `Compression.skip …`: the middleware's checks on responses it leaves alone.
///
/// The fixture lives in `$TMPDIR/sws-bench-compression` and is reused. The page is
/// `CompressionFixture.page` (`index.html` there, which the load test in
/// docs/benchmarks/M6-compression.md serves).
func registerCompressionBenchmarks() {
    var fixture: CompressionFixture?
    func current() -> CompressionFixture {
        if fixture == nil { fixture = CompressionFixture() }
        return fixture!
    }
    func hit(_ name: String, precompressed: Bool, headers: @escaping (StaticFiles) -> [(String, String)] = { _ in [] }) {
        var request: (HTTPRequestStorage, HTTPRequest)?
        Benchmark.register(name: name) {
            let fixture = current()
            let files = precompressed ? fixture.precompressed : fixture.plain
            if request == nil { request = CompressionFixture.request("/index.html", headers: headers(files)) }
            blackHole(files.respond(to: request!.1))
        }
    }
    hit("Compression.hit 50 KiB html, no precompression", precompressed: false, headers: { _ in [("Accept-Encoding", "br, gzip")] })
    hit("Compression.hit 50 KiB html, precompressed, identity", precompressed: true)
    hit("Compression.hit 50 KiB html, precompressed, br variant", precompressed: true,
        headers: { _ in [("Accept-Encoding", "gzip, deflate, br, zstd")] })
    hit("Compression.hit 50 KiB html, precompressed, gzip variant", precompressed: true,
        headers: { _ in [("Accept-Encoding", "deflate, gzip")] })
    hit("Compression.304 50 KiB html, br variant", precompressed: true) { files in
        let probe = CompressionFixture.request("/index.html", headers: [("Accept-Encoding", "br")])
        return [("Accept-Encoding", "br"), ("If-None-Match", files.respond(to: probe.1)?.headers.firstValueString(for: .etag) ?? "")]
    }

    func dynamic(_ name: String, accept: String, type: String = "text/html", level: Int = 4) {
        var state: (Compression, HTTPResponse, (HTTPRequestStorage, HTTPRequest))?
        Benchmark.register(name: name) {
            if state == nil {
                var configuration = CompressionConfiguration()
                configuration.level = level
                var headers = HTTPFields()
                headers.append(name: "Content-Type", value: type)
                headers.append(name: "ETag", value: "\"bench\"")
                let response = HTTPResponse(headers: headers, body: .bytes(ByteBuffer(bytes: CompressionFixture.page)))
                state = (Compression(configuration: configuration), response,
                         CompressionFixture.request("/", headers: [("Accept-Encoding", accept)]))
            }
            blackHole(state!.0.encode(state!.1, for: state!.2.1))
        }
    }
    dynamic("Compression.dynamic br 50 KiB html", accept: "br")
    dynamic("Compression.dynamic gzip level 4 50 KiB html", accept: "gzip")
    dynamic("Compression.dynamic gzip level 1 50 KiB html", accept: "gzip", level: 1)
    dynamic("Compression.dynamic gzip level 6 50 KiB html", accept: "gzip", level: 6)
    dynamic("Compression.dynamic deflate level 4 50 KiB html", accept: "deflate")
    dynamic("Compression.skip image/png", accept: "br, gzip", type: "image/png")
    dynamic("Compression.skip identity (no coding accepted)", accept: "identity")
}

final class CompressionFixture {
    let plain: StaticFiles
    let precompressed: StaticFiles

    /// 50 KiB of HTML-like markup, deterministic: words from a small vocabulary in a fixed
    /// pseudo-random order with some hex noise. Compresses to about 20-25% with gzip/br.
    static let page: [UInt8] = {
        let words = ["<div class=\"item\">", "</div>\n", "<p>", "</p>\n", "<a href=\"/docs/", "\">", "</a>",
                     "server", "request", "response", "stream", "compression", "the", "of", "and", "header",
                     "body", "chunk", " ", " ", "<span class=\"tag\">", "</span>", "<li>", "</li>\n"]
        var state: UInt64 = 0x5EED
        var out = Array("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>Bench</title></head><body>\n".utf8)
        let size = 50 * 1024
        while out.count < size - 16 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out += Array(words[Int((state >> 33) % UInt64(words.count))].utf8)
            if state >> 59 == 0 { out += Array(String(state >> 32, radix: 16).utf8) }
        }
        out = Array(out.prefix(size - 15))
        out += Array("</body></html>\n".utf8)
        return out
    }()

    init() {
        let base = FileManager.default.temporaryDirectory.appending(path: "sws-bench-compression")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? Data(Self.page).write(to: base.appending(path: "index.html"))
        plain = try! StaticFiles(root: base.path)
        var configuration = StaticFilesConfiguration()
        configuration.compression = CompressionConfiguration()
        precompressed = try! StaticFiles(root: base.path, configuration: configuration)
    }

    static func request(_ path: String, headers: [(String, String)]) -> (HTTPRequestStorage, HTTPRequest) {
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
        storage.buffer.append(contentsOf: Array(path.utf8))
        let pathView = ByteView(offset: 0, length: storage.buffer.writerIndex)
        for (name, value) in headers {
            let nameStart = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(name.utf8))
            let nameView = ByteView(offset: nameStart, length: storage.buffer.writerIndex - nameStart)
            let valueStart = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(value.utf8))
            let valueView = ByteView(offset: valueStart, length: storage.buffer.writerIndex - valueStart)
            let hash = storage.buffer.withSpan(of: nameView) { ASCII.fnv1aLowercased($0) }
            storage.appendField(nameView: nameView, hash: hash, valueView: valueView)
        }
        return (storage, HTTPRequest(method: .get, path: pathView, headers: storage.fieldsView))
    }
}
