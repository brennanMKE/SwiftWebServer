import Foundation
import HTTPCore
import StaticFiles

/// StaticFiles cache-hit microbenchmarks (#0084, conditional requests #0085). Select with `sws-bench micro --filter
/// StaticFiles`. The fixture tree lives in `$TMPDIR/sws-bench-staticfiles` and is reused.
///
/// A hit hashes the path, takes one shard lock and returns the stored response. Target:
/// 0 allocations per request, for small files (bytes in memory) and large ones (a file region).
func registerStaticFilesBenchmarks() {
    var fixture: StaticFilesFixture?
    func register(_ name: String, _ target: String, headers: [(String, String)] = []) {
        register(name, target) { _ in headers }
    }
    /// `headers` is computed once, from the fixture (to echo its validators back).
    func register(_ name: String, _ target: String, headers: @escaping (StaticFiles) -> [(String, String)]) {
        var request: (HTTPRequestStorage, HTTPRequest)?
        Benchmark.register(name: name) {
            if fixture == nil { fixture = StaticFilesFixture() }
            if request == nil { request = StaticFilesFixture.request(target, headers: headers(fixture!.files)) }
            blackHole(fixture!.files.respond(to: request!.1))
        }
    }
    func validator(_ name: HTTPFieldName, of target: String) -> (StaticFiles) -> String {
        { files in
            let probe = StaticFilesFixture.request(target, headers: [])
            return files.respond(to: probe.1)?.headers.firstValueString(for: name) ?? ""
        }
    }
    register("StaticFiles.hit 626-byte index.html", "/index.html")
    register("StaticFiles.hit directory index", "/")
    register("StaticFiles.hit 1 MiB file region", "/large.bin")
    register("StaticFiles.hit percent-encoded path", "/sub%20folder/page.html")
    register("StaticFiles.range 0-99 of 626 bytes", "/index.html", headers: [("Range", "bytes=0-99")])
    // #0085: conditional requests on a cache hit. Target: 0 allocations for the 304s.
    let etag = validator(.etag, of: "/index.html")
    let lastModified = validator(.lastModified, of: "/index.html")
    register("StaticFiles.304 If-None-Match", "/index.html") { [("If-None-Match", etag($0))] }
    register("StaticFiles.304 If-None-Match list", "/index.html") { [("If-None-Match", "W/\"a\", \"b\", \(etag($0))")] }
    register("StaticFiles.304 If-Modified-Since", "/index.html") { [("If-Modified-Since", lastModified($0))] }
    register("StaticFiles.304 If-None-Match 1 MiB file", "/large.bin") { [("If-None-Match", validator(.etag, of: "/large.bin")($0))] }
    register("StaticFiles.200 If-None-Match stale", "/index.html", headers: [("If-None-Match", "\"stale\"")])
}

private final class StaticFilesFixture {
    let files: StaticFiles

    init() {
        let root = FileManager.default.temporaryDirectory.appending(path: "sws-bench-staticfiles")
        try? FileManager.default.createDirectory(at: root.appending(path: "sub folder"), withIntermediateDirectories: true)
        let page = Data(repeating: UInt8(ascii: "x"), count: 626)
        try? page.write(to: root.appending(path: "index.html"))
        try? page.write(to: root.appending(path: "sub folder/page.html"))
        try? Data(count: 1 << 20).write(to: root.appending(path: "large.bin"))
        files = try! StaticFiles(root: root.path)
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
