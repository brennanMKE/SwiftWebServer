import Compression
import Foundation
import HTTPCore
import StaticFiles
import Testing

/// A served directory under `$TMPDIR`, removed on deinit.
final class Site: Sendable {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "sws-compression-\(UInt64.random(in: 0...UInt64.max))")
        root = base.appending(path: "Public")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ name: String, _ bytes: [UInt8], modified: Date? = nil) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    func files(sidecars: Bool = true, _ configure: (inout StaticFilesConfiguration) -> Void = { _ in }) throws -> StaticFiles {
        var configuration = StaticFilesConfiguration()
        configuration.compression = CompressionConfiguration()
        configuration.precompressedSidecars = sidecars
        configure(&configuration)
        return try StaticFiles(root: root.path, configuration: configuration)
    }
}

func get(_ files: StaticFiles, _ path: String, _ method: HTTPMethod = .get, headers: [(String, String)] = []) throws -> HTTPResponse {
    let request = TestRequest(method, path, headers: headers)
    return try #require(files.respond(to: request.request))
}

/// #0091 static precompression: variants rendered once in the StaticFiles cache, sidecars,
/// and conditional requests evaluated against the variant's tag.
@Suite struct StaticVariantTests {
    let page = sampleText(40_000, seed: 11)

    @Test(arguments: [("br", ContentCoding.brotli), ("gzip", .gzip), ("deflate", .deflate), ("gzip, br", .brotli)])
    func cachedVariantIsServed(_ accept: String, _ coding: ContentCoding) async throws {
        let site = try Site()
        try site.write("index.html", page)
        let files = try site.files()
        let identity = try get(files, "/index.html")
        let etag = try #require(identity.header(.etag))
        #expect(identity.headerValues(.vary) == ["Accept-Encoding"])
        #expect(identity.header(.contentEncoding) == nil)
        #expect(identity.header(.acceptRanges) == "bytes")

        let encoded = try get(files, "/index.html", headers: [("Accept-Encoding", accept)])
        #expect(encoded.header(.contentEncoding) == String(describing: coding.token))
        #expect(encoded.header(.etag) == String(etag.dropLast()) + String(describing: coding.etagSuffix) + "\"")
        #expect(encoded.headerValues(.vary) == ["Accept-Encoding"])
        #expect(encoded.header(.acceptRanges) == nil)
        #expect(encoded.header(.contentType) == "text/html")
        #expect(encoded.header(.lastModified) == identity.header(.lastModified))
        let body = try await encoded.bodyBytes()
        #expect(ContentCodec.decode(body, coding) == page)
    }

    @Test func repeatedRequestsShareOneCompressedBuffer() throws {
        let site = try Site()
        try site.write("app.js", page)
        let files = try site.files()
        let first = try get(files, "/app.js", headers: [("Accept-Encoding", "br")])
        let second = try get(files, "/app.js", headers: [("Accept-Encoding", "br")])
        guard case .bytes(let a) = first.body, case .bytes(let b) = second.body else {
            Issue.record("expected in-memory bodies")
            return
        }
        // Same storage: compressed once when the file entered the cache.
        let same = a.withUnsafeReadableBytes { pa in b.withUnsafeReadableBytes { pb in pa.baseAddress == pb.baseAddress } }
        #expect(same)
    }

    @Test func ifNoneMatchIsEvaluatedAgainstTheVariant() throws {
        let site = try Site()
        try site.write("style.css", page)
        let files = try site.files()
        let gz = try #require(try get(files, "/style.css", headers: [("Accept-Encoding", "gzip")]).header(.etag))
        let plain = try #require(try get(files, "/style.css").header(.etag))
        #expect(gz != plain)

        let hit = try get(files, "/style.css", headers: [("Accept-Encoding", "gzip"), ("If-None-Match", gz)])
        #expect(hit.status.code == 304)
        #expect(hit.header(.etag) == gz)
        #expect(hit.headerValues(.vary) == ["Accept-Encoding"])
        #expect(hit.header(.contentEncoding) == nil)

        // The client holds the gzip variant but now gets brotli: a full response.
        let switched = try get(files, "/style.css", headers: [("Accept-Encoding", "br"), ("If-None-Match", gz)])
        #expect(switched.status.code == 200)
        #expect(switched.header(.contentEncoding) == "br")

        // The unencoded tag does not validate the gzip variant, and the reverse.
        let stale = try get(files, "/style.css", headers: [("Accept-Encoding", "gzip"), ("If-None-Match", plain)])
        #expect(stale.status.code == 200)
        let identity = try get(files, "/style.css", headers: [("If-None-Match", plain)])
        #expect(identity.status.code == 304)
        #expect(identity.headerValues(.vary) == ["Accept-Encoding"])
        let wrong = try get(files, "/style.css", headers: [("If-None-Match", gz)])
        #expect(wrong.status.code == 200)

        // If-Match uses strong comparison against the selected variant too.
        let match = try get(files, "/style.css", .get, headers: [("Accept-Encoding", "gzip"), ("If-Match", plain)])
        #expect(match.status.code == 412)
    }

    @Test func rangeIsServedFromTheUnencodedFile() async throws {
        let site = try Site()
        try site.write("data.json", page)
        let files = try site.files()
        let partial = try get(files, "/data.json", headers: [("Accept-Encoding", "gzip"), ("Range", "bytes=0-99")])
        #expect(partial.status.code == 206)
        #expect(partial.header(.contentEncoding) == nil)
        #expect(try await partial.bodyBytes() == Array(page[0..<100]))
    }

    @Test func headGetsTheVariantHeaders() throws {
        let site = try Site()
        try site.write("index.html", page)
        let files = try site.files()
        let head = try get(files, "/index.html", .head, headers: [("Accept-Encoding", "gzip")])
        #expect(head.header(.contentEncoding) == "gzip")
    }

    @Test func incompressibleAndSmallFilesHaveNoVariants() throws {
        let site = try Site()
        try site.write("photo.png", sampleText(10_000))
        try site.write("tiny.txt", sampleText(100))
        try site.write("noise.txt", randomBytes(20_000))
        let files = try site.files()
        let photo = try get(files, "/photo.png", headers: [("Accept-Encoding", "gzip")])
        #expect(photo.header(.contentEncoding) == nil)
        #expect(photo.header(.vary) == nil)
        let tiny = try get(files, "/tiny.txt", headers: [("Accept-Encoding", "gzip")])
        #expect(tiny.header(.contentEncoding) == nil)
        #expect(tiny.header(.vary) == nil)
        // Compressible type that does not shrink: negotiated here (Vary) so the middleware
        // does not retry it on every request.
        let noise = try get(files, "/noise.txt", headers: [("Accept-Encoding", "gzip")])
        #expect(noise.header(.contentEncoding) == nil)
        #expect(noise.headerValues(.vary) == ["Accept-Encoding"])
    }

    @Test func withoutCompressionNothingChanges() throws {
        let site = try Site()
        try site.write("index.html", page)
        let files = try StaticFiles(root: site.root.path)
        let response = try get(files, "/index.html", headers: [("Accept-Encoding", "gzip, br")])
        #expect(response.header(.contentEncoding) == nil)
        #expect(response.header(.vary) == nil)
    }

    // MARK: Sidecars

    @Test func sidecarsAreServed() async throws {
        let site = try Site()
        let past = Date(timeIntervalSinceNow: -3600)
        try site.write("app.js", page, modified: past)
        // Distinct content, so the test sees the sidecar rather than an on-the-fly variant.
        let marker = Array("from the sidecar ".utf8) + sampleText(5000)
        let br = try #require(ContentCodec.encode(ByteBuffer(bytes: marker), .brotli)).withUnsafeReadableBytes { Array($0) }
        let gz = try #require(ContentCodec.encode(ByteBuffer(bytes: marker), .gzip, level: 9)).withUnsafeReadableBytes { Array($0) }
        try site.write("app.js.br", br)
        try site.write("app.js.gz", gz)
        let files = try site.files()
        let brotli = try get(files, "/app.js", headers: [("Accept-Encoding", "br")])
        #expect(brotli.header(.contentEncoding) == "br")
        #expect(try await brotli.bodyBytes() == br)
        let gzip = try get(files, "/app.js", headers: [("Accept-Encoding", "gzip")])
        #expect(try await gzip.bodyBytes() == gz)
        // deflate has no sidecar: compressed from the file.
        let deflate = try get(files, "/app.js", headers: [("Accept-Encoding", "deflate")])
        #expect(ContentCodec.decode(try await deflate.bodyBytes(), .deflate) == page)
    }

    @Test func staleOrLinkedSidecarsAreIgnored() async throws {
        let site = try Site()
        let marker = Array("stale".utf8) + sampleText(5000)
        let gz = try #require(ContentCodec.encode(ByteBuffer(bytes: marker), .gzip)).withUnsafeReadableBytes { Array($0) }
        // Older than the file it claims to encode.
        try site.write("a.css.gz", gz, modified: Date(timeIntervalSinceNow: -7200))
        try site.write("a.css", page, modified: Date(timeIntervalSinceNow: -3600))
        // A link.
        try site.write("b.css", page, modified: Date(timeIntervalSinceNow: -3600))
        let target = try site.write("elsewhere.gz", gz)
        try FileManager.default.createSymbolicLink(atPath: site.root.appending(path: "b.css.gz").path,
                                                   withDestinationPath: target.path)
        let files = try site.files()
        for path in ["/a.css", "/b.css"] {
            let response = try get(files, path, headers: [("Accept-Encoding", "gzip")])
            #expect(ContentCodec.decode(try await response.bodyBytes(), .gzip) == page, "\(path)")
        }
    }

    @Test func largeFileSidecarIsSentFromTheFile() async throws {
        let site = try Site()
        let big = sampleText(300_000, seed: 5)
        try site.write("big.txt", big, modified: Date(timeIntervalSinceNow: -60))
        let gz = try #require(ContentCodec.encode(ByteBuffer(bytes: big), .gzip)).withUnsafeReadableBytes { Array($0) }
        try site.write("big.txt.gz", gz)
        let files = try site.files { $0.smallFileLimit = 16 * 1024 }
        let response = try get(files, "/big.txt", headers: [("Accept-Encoding", "gzip")])
        #expect(response.header(.contentEncoding) == "gzip")
        if case .bytes = response.body { Issue.record("a large sidecar is not read into memory") }
        #expect(ContentCodec.decode(try await response.bodyBytes(), .gzip) == big)
        // Without a sidecar a large file is left to the middleware: no Vary from StaticFiles.
        try site.write("other.txt", big)
        let other = try get(files, "/other.txt", headers: [("Accept-Encoding", "gzip")])
        #expect(other.header(.contentEncoding) == nil)
        #expect(other.header(.vary) == nil)
    }

    @Test func sidecarsCanBeTurnedOff() async throws {
        let site = try Site()
        try site.write("x.html", page, modified: Date(timeIntervalSinceNow: -60))
        let bogus = try #require(ContentCodec.encode(ByteBuffer(bytes: sampleText(5000)), .gzip)).withUnsafeReadableBytes { Array($0) }
        try site.write("x.html.gz", bogus)
        let files = try site.files(sidecars: false)
        let response = try get(files, "/x.html", headers: [("Accept-Encoding", "gzip")])
        #expect(ContentCodec.decode(try await response.bodyBytes(), .gzip) == page)
    }

    // MARK: With the middleware in front

    @Test func middlewareDoesNotEncodeTwice() async throws {
        let site = try Site()
        try site.write("index.html", page)
        let big = sampleText(300_000)
        try site.write("big.html", big)
        let files = try site.files { $0.smallFileLimit = 64 * 1024 }
        let chain = MiddlewareBuilder.build {
            Compression()
            asHandler(files)
        }
        for accept in ["gzip", "br", "identity"] {
            let request = TestRequest(.get, "/index.html", headers: [("Accept-Encoding", accept)])
            let response = try await chain.handle(request.request, context: RequestContext())
            #expect(response.headerValues(.vary) == ["Accept-Encoding"])
            #expect(response.headerValues(.contentEncoding).count == (accept == "identity" ? 0 : 1))
            if let coding = ContentCoding(name: accept) {
                #expect(ContentCodec.decode(try await response.bodyBytes(), coding) == page)
            }
        }
        // The large file (no sidecar) is compressed by the middleware, streamed.
        let request = TestRequest(.get, "/big.html", headers: [("Accept-Encoding", "gzip")])
        let response = try await chain.handle(request.request, context: RequestContext())
        #expect(response.header(.contentEncoding) == "gzip")
        guard case .stream = response.body else { Issue.record("expected a stream"); return }
        #expect(ContentCodec.decode(try await response.bodyBytes(), .gzip) == big)
        // And If-None-Match on its variant tag gets 304 from the middleware.
        let tag = try #require(response.header(.etag))
        let again = TestRequest(.get, "/big.html", headers: [("Accept-Encoding", "gzip"), ("If-None-Match", tag)])
        let revalidated = try await chain.handle(again.request, context: RequestContext())
        #expect(revalidated.status.code == 304)
        #expect(revalidated.header(.etag) == tag)
    }
}

/// `StaticFiles` as the chain's handler (it is a middleware too).
func asHandler(_ handler: some HTTPHandler) -> some HTTPHandler { handler }
