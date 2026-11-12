import Foundation
import HTTPCore
import Testing
@testable import StaticFiles

@Suite struct StaticFilesTests {
    // MARK: Legacy repros

    /// #0013: blocked names match as path components, anywhere, before and after decoding,
    /// in any case.
    @Test func blockListMatchesComponentsAnywhere() async throws {
        let fixture = try Fixture()
        try fixture.write(".DS_Store", "ds")
        try fixture.write("sub folder/.DS_Store", "ds")
        try fixture.write(".git/config", "[core]")
        try fixture.write("http-config.json", "{}")
        try fixture.write("deep/http-config.json", "{}")
        try fixture.write(".well-known/security.txt", "contact")
        try fixture.write(".hidden", "h")
        let files = try fixture.files()
        for path in ["/.DS_Store", "/sub%20folder/.DS_Store", "/.git/config", "/.git/", "/http-config.json",
                     "/deep/http-config.json", "/%2EDS_Store", "/.ds_store", "/HTTP-CONFIG.JSON", "/.hidden"] {
            #expect(try await files.get(path).status == .forbidden, "\(path)")
        }
        #expect(try await files.get("/.well-known/security.txt").status == .ok)

        let dotfilesAllowed = try fixture.files { $0.blockDotfiles = false }
        #expect(try await dotfilesAllowed.get("/.hidden").bodyText == "h")
        #expect(try await dotfilesAllowed.get("/.DS_Store").status == .forbidden)
    }

    /// #0014: a sibling directory whose name shares the root's prefix is not inside the root.
    @Test func siblingDirectoryWithSharedPrefixIsRefused() async throws {
        let fixture = try Fixture()
        try fixture.write("PublicBackup/secret.txt", "secret", in: fixture.base)
        try fixture.write("http-config.json", "{}", in: fixture.base)
        let files = try fixture.files()
        for path in ["/../PublicBackup/secret.txt", "/%2e%2e/PublicBackup/secret.txt", "/%2E%2E/http-config.json",
                     "/a/../../PublicBackup/secret.txt", "/..", "/.%2e/x"] {
            let response = try await files.get(path)
            #expect(response.status == .forbidden, "\(path)")
            #expect(!response.bodyText.contains("secret"))
        }
    }

    /// #0014: symbolic links are followed only while they stay inside the root.
    @Test func symlinkPolicy() async throws {
        let fixture = try Fixture()
        try fixture.write("PublicBackup/secret.txt", "secret", in: fixture.base)
        try fixture.write("inside.txt", "inside")
        try fixture.symlink("escape.txt", to: fixture.base.appending(path: "PublicBackup/secret.txt").path)
        try fixture.symlink("escape-dir", to: "../PublicBackup")
        try fixture.symlink("link.txt", to: "inside.txt")
        try fixture.symlink("blocked.txt", to: ".git/config")
        try fixture.write(".git/config", "[core]")

        let files = try fixture.files()
        #expect(try await files.get("/escape.txt").status == .forbidden)
        #expect(try await files.get("/escape-dir/secret.txt").status == .forbidden)
        #expect(try await files.get("/link.txt").bodyText == "inside")
        #expect(try await files.get("/blocked.txt").status == .forbidden, "the target path is block-checked too")

        let deny = try fixture.files { $0.symlinkPolicy = .deny }
        #expect(try await deny.get("/link.txt").status == .forbidden)
        #expect(try await deny.get("/escape.txt").status == .forbidden)
        #expect(try await deny.get("/inside.txt").bodyText == "inside")

        let anywhere = try fixture.files { $0.symlinkPolicy = .followAnywhere }
        #expect(try await anywhere.get("/escape.txt").bodyText == "secret")
    }

    /// #0015: the path is decoded exactly once.
    @Test func pathIsDecodedOnce() async throws {
        let fixture = try Fixture()
        try fixture.write("100%25.txt", "hi")
        try fixture.write("100%.txt", "wrong")
        try fixture.write("sub folder/a b.txt", "spaced")
        let files = try fixture.files()
        let response = try await files.get("/100%2525.txt")
        #expect(response.status == .ok)
        #expect(response.bodyText == "hi")
        #expect(try await files.get("/100%25.txt").bodyText == "wrong")
        #expect(try await files.get("/sub%20folder/a%20b.txt").bodyText == "spaced")
        // %252e%252e is the literal name "%2e%2e", never "..".
        #expect(try await files.get("/%252e%252e/x").status == .notFound)
    }

    @Test func malformedPathsAreRejected() async throws {
        let fixture = try Fixture()
        try fixture.write("a/b", "b")
        let files = try fixture.files()
        for path in ["/a%2Fb", "/a%2fb", "/a%00", "/a\\b", "/a%5Cb", "/%zz", "/a%2", "/a%", "relative"] {
            #expect(try await files.get(path).status == .badRequest, "\(path)")
        }
        #expect(try await files.get("/a/b").bodyText == "b")
        #expect(try await files.get("/a//./b").bodyText == "b")
    }

    /// #0022: other methods get 405 with Allow.
    @Test func otherMethodsGet405WithAllow() async throws {
        let fixture = try Fixture()
        try fixture.write("index.html", "<p>")
        let files = try fixture.files()
        for method in [HTTPMethod.post, .put, .delete, .options, .patch, .trace, HTTPMethod("PROPFIND")!] {
            let response = try await files.get("/", method: method)
            #expect(response.status == .methodNotAllowed)
            #expect(response.header(.allow) == "GET, HEAD")
        }
    }

    /// #0025: validators come from metadata; content is never hashed.
    @Test func etagAndLastModifiedComeFromMetadata() async throws {
        let fixture = try Fixture()
        let url = try fixture.write("page.html", "<html>hello</html>")
        // 1994-11-06T08:49:37.123456789Z
        var times = [timespec(tv_sec: 784_111_777, tv_nsec: 123_456_789),
                     timespec(tv_sec: 784_111_777, tv_nsec: 123_456_789)]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        var info = stat()
        #expect(stat(url.path, &info) == 0)

        let response = try await fixture.files().get("/page.html")
        #expect(response.status == .ok)
        let expectedTag = "\"\(String(info.st_size, radix: 16))-\(String(784_111_777_123_456_789 as UInt64, radix: 16))-\(String(info.st_ino, radix: 16))\""
        #expect(response.header(.etag) == expectedTag)
        #expect(response.header(.lastModified) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(response.header(.contentType) == "text/html")
        #expect(response.header(.acceptRanges) == "bytes")
        #expect(response.header(.contentLength) == nil, "the serializer writes the length")
    }

    // MARK: Index files and redirects

    @Test func indexFilesAndTrailingSlashRedirect() async throws {
        let fixture = try Fixture()
        try fixture.write("index.html", "root index")
        try fixture.write("sub folder/index.html", "sub index")
        try fixture.mkdir("empty")
        try fixture.mkdir("evil.example")
        let files = try fixture.files()

        #expect(try await files.get("/").bodyText == "root index")
        #expect(try await files.get("").bodyText == "root index")
        #expect(try await files.get("/sub%20folder/").bodyText == "sub index")
        #expect(try await files.get("/sub%20folder/index.html").bodyText == "sub index")

        let redirect = try await files.get("/sub%20folder")
        #expect(redirect.status == .movedPermanently)
        #expect(redirect.header(.location) == "/sub%20folder/")
        #expect(try await files.get("/sub%20folder?a=1&b").header(.location) == "/sub%20folder/?a=1&b")
        // Never a scheme-relative Location.
        #expect(try await files.get("//evil.example").header(.location) == "/evil.example/")

        #expect(try await files.get("/empty/").status == .notFound, "no directory listings")
        #expect(try await files.get("/missing.html").status == .notFound)
        #expect(try await files.get("/index.html/").status == .notFound)

        let custom = try fixture.files { $0.indexFiles = ["default.htm", "index.html"] }
        try fixture.write("default.htm", "default")
        #expect(try await custom.get("/").bodyText == "default")
    }

    // MARK: MIME types

    @Test func mimeTypes() async throws {
        let fixture = try Fixture()
        let names = ["a.html": "text/html", "a.css": "text/css", "a.js": "text/javascript", "a.PNG": "image/png",
                     "a.svg": "image/svg+xml", "a.json": "application/json", "a.woff2": "font/woff2",
                     "a.wasm": "application/wasm", "a.mp4": "video/mp4", "a.unknownext": "application/octet-stream",
                     "noext": "application/octet-stream", "a.tar.gz": "application/gzip", "a.md": "text/markdown"]
        for name in names.keys { try fixture.write(name, "x") }
        let files = try fixture.files()
        for (name, type) in names {
            #expect(try await files.get("/\(name)").header(.contentType) == type, "\(name)")
        }
        let custom = try fixture.files {
            $0.defaultMIMEType = "text/plain"
            $0.mimeTypes = ["MD": "text/markdown; charset=utf-8", "html": "text/html; charset=utf-8"]
        }
        #expect(try await custom.get("/a.md").header(.contentType) == "text/markdown; charset=utf-8")
        #expect(try await custom.get("/a.html").header(.contentType) == "text/html; charset=utf-8")
        #expect(try await custom.get("/noext").header(.contentType) == "text/plain")
    }

    @Test func mimeLookupTable() {
        func lookup(_ ext: String) -> String? {
            Array(ext.utf8).withUnsafeBufferPointer { MIMETypes.lookup(extension: $0.span) }.map { "\($0)" }
        }
        #expect(lookup("HTM") == "text/html")
        #expect(lookup("webmanifest") == "application/manifest+json")
        #expect(lookup("") == nil)
        #expect(lookup("nope") == nil)
        // Every legacy entry from Root/http-config.json is present.
        let legacy = ["html", "htm", "css", "js", "jpg", "jpeg", "png", "gif", "svg", "webp", "avif", "heic", "heif",
                      "ico", "json", "txt", "xml", "pdf", "woff2", "woff", "ttf", "otf", "mp4", "webm", "mp3", "wav", "ogg"]
        for ext in legacy { #expect(lookup(ext) != nil, "\(ext)") }
    }

    // MARK: Range

    @Test func rangeRequests() async throws {
        let fixture = try Fixture()
        let content = (0..<1000).map { UInt8($0 % 251) }
        try fixture.write("data.bin", Data(content))
        let files = try fixture.files()

        func range(_ value: String, method: HTTPMethod = .get, extra: [(String, String)] = []) async throws -> HTTPResponse {
            try await files.get("/data.bin", method: method, headers: [("Range", value)] + extra)
        }
        var response = try await range("bytes=0-99")
        #expect(response.status == .partialContent)
        #expect(response.header(.contentRange) == "bytes 0-99/1000")
        #expect(response.bodyBytes == Array(content[0..<100]))
        #expect(response.header(.etag) != nil)

        response = try await range("bytes=990-")
        #expect(response.header(.contentRange) == "bytes 990-999/1000")
        #expect(response.bodyBytes == Array(content[990...]))

        response = try await range("bytes=-5")
        #expect(response.header(.contentRange) == "bytes 995-999/1000")
        #expect(response.bodyBytes == Array(content[995...]))

        response = try await range("bytes=-5000")
        #expect(response.header(.contentRange) == "bytes 0-999/1000")

        response = try await range("bytes=500-99999")
        #expect(response.header(.contentRange) == "bytes 500-999/1000")
        #expect(response.bodyBytes.count == 500)

        for unsatisfiable in ["bytes=1000-", "bytes=1000-2000", "bytes=-0"] {
            response = try await range(unsatisfiable)
            #expect(response.status == .rangeNotSatisfiable, "\(unsatisfiable)")
            #expect(response.header(.contentRange) == "bytes */1000")
        }
        for ignored in ["bytes=0-1,5-6", "items=0-1", "bytes=5-1", "bytes=a-b", "bytes", "bytes=-"] {
            response = try await range(ignored)
            #expect(response.status == .ok, "\(ignored)")
            #expect(response.bodyBytes.count == 1000)
        }
        // HEAD ignores Range.
        #expect(try await range("bytes=0-9", method: .head).status == .ok)

        // If-Range: the current validator keeps the range; any other disables it.
        let etag = try await files.get("/data.bin").header(.etag)!
        let lastModified = try await files.get("/data.bin").header(.lastModified)!
        #expect(try await range("bytes=0-9", extra: [("If-Range", etag)]).status == .partialContent)
        #expect(try await range("bytes=0-9", extra: [("If-Range", lastModified)]).status == .partialContent)
        #expect(try await range("bytes=0-9", extra: [("If-Range", "\"other\"")]).status == .ok)
        #expect(try await range("bytes=0-9", extra: [("If-Range", "W/\(etag)")]).status == .ok)
    }

    @Test func rangeOnLargeFileUsesFileRegion() async throws {
        let fixture = try Fixture()
        let content = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try fixture.write("big.bin", Data(content))
        let files = try fixture.files()
        let full = try await files.get("/big.bin")
        #expect(full.isFileBody)
        #expect(full.body.knownLength == 200_000)
        #expect(full.bodyBytes == content)
        let partial = try await files.get("/big.bin", headers: [("Range", "bytes=100000-100099")])
        #expect(partial.status == .partialContent)
        #expect(partial.isFileBody)
        guard case .file(let region) = partial.body else { return }
        #expect(region.offset == 100_000 && region.length == 100)
        #expect(partial.bodyBytes == Array(content[100_000..<100_100]))
    }

    @Test func rangeParser() {
        func parse(_ value: String, size: Int64 = 100) -> RangeRequest {
            Array(value.utf8).withUnsafeBufferPointer { RangeRequest.parse($0.span, size: size) }
        }
        #expect(parse("bytes=0-0") == .partial(offset: 0, length: 1))
        #expect(parse(" BYTES=10-19 ") == .partial(offset: 10, length: 10))
        #expect(parse("bytes=99-") == .partial(offset: 99, length: 1))
        #expect(parse("bytes=-1") == .partial(offset: 99, length: 1))
        #expect(parse("bytes=0-", size: 0) == .unsatisfiable)
        #expect(parse("bytes=-1", size: 0) == .unsatisfiable)
        #expect(parse("bytes=100-") == .unsatisfiable)
        #expect(parse("bytes=0-99999999999999999999999") == .full)
        #expect(parse("bytes=1-2-3") == .full)
        #expect(parse("") == .full)
    }

    // MARK: HEAD, sizes, cache

    @Test func headGetsTheGetResponse() async throws {
        let fixture = try Fixture()
        try fixture.write("a.txt", "hello")
        let files = try fixture.files()
        let get = try await files.get("/a.txt")
        let head = try await files.get("/a.txt", method: .head)
        #expect(head.status == .ok)
        #expect(head.header(.etag) == get.header(.etag))
        #expect(head.body.knownLength == 5, "protocols send the length and drop the body for HEAD")
    }

    @Test func smallFilesAreInMemoryAndLargeFilesAreRegions() async throws {
        let fixture = try Fixture()
        try fixture.write("small.bin", Data(count: 64 * 1024))
        try fixture.write("large.bin", Data(count: 64 * 1024 + 1))
        try fixture.write("empty.txt", Data())
        let files = try fixture.files()
        #expect(try await !files.get("/small.bin").isFileBody)
        #expect(try await files.get("/large.bin").isFileBody)
        let empty = try await files.get("/empty.txt")
        #expect(empty.status == .ok && empty.bodyBytes.isEmpty)
        let tiny = try fixture.files { $0.smallFileLimit = 0 }
        #expect(try await tiny.get("/small.bin").isFileBody)
    }

    /// Changes on disk are picked up at the next revalidation.
    @Test func cacheRevalidatesChangedFiles() async throws {
        let fixture = try Fixture()
        try fixture.write("a.txt", "version one")
        let always = try fixture.files { $0.revalidationInterval = .zero }
        let first = try await always.get("/a.txt")
        #expect(first.bodyText == "version one")
        #expect(try await always.get("/a.txt").header(.etag) == first.header(.etag))
        try fixture.write("a.txt", "version two, longer")
        let second = try await always.get("/a.txt")
        #expect(second.bodyText == "version two, longer")
        #expect(second.header(.etag) != first.header(.etag))
        try FileManager.default.removeItem(at: fixture.root.appending(path: "a.txt"))
        #expect(try await always.get("/a.txt").status == .notFound)
        #expect(always.cachedEntryCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheServesWithinTheIntervalThenRevalidates() async throws {
        let fixture = try Fixture()
        try fixture.write("a.txt", "old")
        let files = try fixture.files { $0.revalidationInterval = .milliseconds(300) }
        #expect(try await files.get("/a.txt").bodyText == "old")
        try fixture.write("a.txt", "new!")
        #expect(try await files.get("/a.txt").bodyText == "old", "served from the cache inside the interval")
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await files.get("/a.txt").bodyText == "new!")
    }

    @Test func cacheIsBounded() async throws {
        let fixture = try Fixture()
        for i in 0..<20 { try fixture.write("f\(i).txt", "\(i)") }
        let files = try fixture.files { $0.maxCachedEntries = 4 }
        for i in 0..<20 { #expect(try await files.get("/f\(i).txt").bodyText == "\(i)") }
        #expect(files.cachedEntryCount <= 4)
        let uncached = try fixture.files { $0.maxCachedEntries = 0 }
        #expect(try await uncached.get("/f3.txt").bodyText == "3")
        #expect(uncached.cachedEntryCount == 0)
    }

    @Test func cacheControlIsConfigurable() async throws {
        let fixture = try Fixture()
        try fixture.write("a.txt", "a")
        #expect(try await fixture.files().get("/a.txt").header(.cacheControl) == nil)
        let cached = try fixture.files { $0.cacheControl = "public, max-age=3600" }
        #expect(try await cached.get("/a.txt").header(.cacheControl) == "public, max-age=3600")
    }

    @Test func rootMustBeADirectory() throws {
        let fixture = try Fixture()
        let file = try fixture.write("a.txt", "a")
        #expect(throws: StaticFiles.InitError.rootNotADirectory) { try StaticFiles(root: file.path) }
        #expect(throws: StaticFiles.InitError.rootUnavailable(errno: ENOENT)) {
            try StaticFiles(root: fixture.base.appending(path: "missing").path)
        }
    }

    // MARK: Middleware

    struct Fallback: HTTPHandler {
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            HTTPResponse(status: .accepted)
        }
    }

    @Test func middlewareFallsThroughOnAMiss() async throws {
        let fixture = try Fixture()
        try fixture.write("a.txt", "a")
        try fixture.write(".env", "secret")
        let files = try fixture.files()
        func run(_ method: HTTPMethod, _ target: String) async throws -> HTTPResponse {
            let built = TestRequest(method, target)
            return try await files.handle(built.request, context: RequestContext(), next: Fallback())
        }
        #expect(try await run(.get, "/a.txt").bodyText == "a")
        #expect(try await run(.get, "/api/users").status == .accepted)
        #expect(try await run(.post, "/a.txt").status == .accepted)
        #expect(try await run(.get, "/.env").status == .forbidden)
        #expect(try await run(.get, "/../x").status == .forbidden)
    }

    // MARK: Path decoding

    @Test func decodedPathNormalization() throws {
        let blockList = BlockList(names: [], blockDotfiles: false)
        func decode(_ raw: String) throws(PathRejection) -> DecodedPath {
            let bytes = Array(raw.utf8)
            return try bytes.withUnsafeBufferPointer { buffer throws(PathRejection) in
                try DecodedPath.decode(buffer.span, blockList: blockList)
            }
        }
        #expect(try decode("/a/./b//c/") == DecodedPath(relative: Array("a/b/c".utf8), trailingSlash: true))
        #expect(try decode("/") == DecodedPath(relative: [], trailingSlash: true))
        #expect(try decode("/%41%62") == DecodedPath(relative: Array("Ab".utf8), trailingSlash: false))
        #expect(try decode("/caf%C3%A9").relative == Array("café".utf8))
        #expect(throws: PathRejection.forbidden) { try decode("/a/../b") }
        #expect(throws: PathRejection.forbidden) { try decode("/a/%2e%2E") }
        #expect(throws: PathRejection.malformed) { try decode("/a%2F..") }
    }
}
