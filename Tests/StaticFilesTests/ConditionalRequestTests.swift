import Foundation
import HTTP1
import HTTPCore
import Testing
@testable import StaticFiles

/// Sets the modification time of `url` to `seconds` + `nanoseconds`.
private func setMTime(_ url: URL, seconds: Int, nanoseconds: Int) throws {
    var times = [timespec(tv_sec: seconds, tv_nsec: nanoseconds), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
    let result = url.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }
    try #require(result == 0)
}

/// 1_700_000_000 = Tue, 14 Nov 2023 22:13:20 GMT.
private let mtime = 1_700_000_000
private let mtimeIMF = "Tue, 14 Nov 2023 22:13:20 GMT"
private let earlier = "Tue, 14 Nov 2023 22:13:19 GMT"
private let later = "Tue, 14 Nov 2023 22:13:21 GMT"

@Suite struct HTTPDateTests {
    @Test func threeFormatsParseToTheSameInstant() {
        // RFC 9110 §5.6.7 examples: 784111777 = Sun, 06 Nov 1994 08:49:37 GMT.
        #expect(HTTPDate.parse("Sun, 06 Nov 1994 08:49:37 GMT") == 784_111_777)
        #expect(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT") == 784_111_777)
        #expect(HTTPDate.parse("Sun Nov  6 08:49:37 1994") == 784_111_777)
        #expect(HTTPDate.parse("Sun Nov 06 08:49:37 1994") == 784_111_777)
        #expect(HTTPDate.parse("  Sun, 06 Nov 1994 08:49:37 GMT\t") == 784_111_777)
        #expect(HTTPDate.parse("Thu, 01 Jan 1970 00:00:00 GMT") == 0)
        #expect(HTTPDate.parse(mtimeIMF) == Int64(mtime))
        #expect(HTTPDate.parse("Wednesday, 01-Jan-25 00:00:00 GMT") == 1_735_689_600)
        #expect(HTTPDate.parse("Fri, 31 Dec 9999 23:59:59 GMT") == IMFFixdate.maximumSeconds)
        #expect(HTTPDate.parse("Thu, 29 Feb 2024 12:00:00 GMT") == 1_709_208_000)
        #expect(HTTPDate.parse("Sat, 31 Dec 2016 23:59:60 GMT") == HTTPDate.parse("Sat, 31 Dec 2016 23:59:59 GMT"))
    }

    @Test func roundTripsWithIMFFixdate() {
        for seconds: Int64 in [0, 1, 86_399, 86_400, 951_782_400, 1_700_000_000, 4_102_444_800, IMFFixdate.maximumSeconds] {
            var buffer = ByteBuffer()
            IMFFixdate.append(secondsSinceEpoch: seconds, to: &buffer)
            let text = buffer.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
            #expect(HTTPDate.parse(text) == seconds, "\(text)")
        }
    }

    @Test func invalidDatesAreRejected() {
        for value in ["", "garbage", "Sun, 06 Nov 1994 08:49:37 UTC", "Sun, 06 Nov 1994 08:49:37 gmt",
                      "Sun, 06 nov 1994 08:49:37 GMT", "Sun, 31 Feb 1994 08:49:37 GMT", "Sun, 29 Feb 2023 00:00:00 GMT",
                      "Sun, 00 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 24:00:00 GMT", "Sun, 06 Nov 1994 08:60:00 GMT",
                      "Sun, 06 Nov 1994 08:49:37 GMTX", "Sun, 6 Nov 1994 08:49:37 GMT", "Xyz, 06 Nov 1994 08:49:37 GMT",
                      "Sun, 06 Nov 94 08:49:37 GMT", "Sun, 06-Nov-94 08:49:37 GMT", "Sundae, 06-Nov-94 08:49:37 GMT",
                      "Sun Nov  6 08:49:37 94", "Sun Nov  6 8:49:37 1994", "1994-11-06T08:49:37Z",
                      "Sun, 06 Nov 1994 08:49:37 GMT, Sun, 06 Nov 1994 08:49:37 GMT"] {
            #expect(HTTPDate.parse(value) == nil, "\(value)")
        }
    }
}

@Suite struct ConditionalRequestTests {
    static let etag = "\"abc-1\""
    static let tag = Array(etag.utf8)
    static let lastModified = Int64(mtime)

    func evaluate(_ headers: [(String, String)], etag: [UInt8]? = tag,
                  exists: Bool = true) -> ConditionalRequest.Outcome {
        evaluate(.get, headers, etag: etag, exists: exists)
    }

    func evaluate(_ method: HTTPMethod, _ headers: [(String, String)], etag: [UInt8]? = tag,
                  exists: Bool = true) -> ConditionalRequest.Outcome {
        let built = TestRequest(method, "/x", headers: headers)
        return ConditionalRequest.evaluate(method: method, fields: built.request.headers, etag: etag,
                                           lastModified: Self.lastModified, representationExists: exists)
    }

    // MARK: Step 1: If-Match (strong comparison)

    @Test func ifMatch() {
        #expect(evaluate([("If-Match", Self.etag)]) == .proceed)
        #expect(evaluate(.put, [("If-Match", Self.etag)]) == .proceed)
        #expect(evaluate([("If-Match", "\"other\"")]) == .preconditionFailed)
        #expect(evaluate([("If-Match", "\"x\", \(Self.etag)")]) == .proceed, "list")
        #expect(evaluate([("If-Match", "\"x\""), ("If-Match", Self.etag)]) == .proceed, "list over two fields")
        #expect(evaluate([("If-Match", "*")]) == .proceed)
        #expect(evaluate([("If-Match", "*")], exists: false) == .preconditionFailed)
        #expect(evaluate([("If-Match", "W/\(Self.etag)")]) == .preconditionFailed, "weak never matches strongly")
        #expect(evaluate([("If-Match", Self.etag)], etag: Array("W/\(Self.etag)".utf8)) == .preconditionFailed)
        #expect(evaluate([("If-Match", "abc-1")]) == .preconditionFailed, "unquoted is malformed")
        #expect(evaluate([("If-Match", Self.etag)], etag: nil) == .preconditionFailed)
    }

    // MARK: Step 2: If-Unmodified-Since, only without If-Match

    @Test func ifUnmodifiedSince() {
        #expect(evaluate(.put, [("If-Unmodified-Since", earlier)]) == .preconditionFailed)
        #expect(evaluate(.put, [("If-Unmodified-Since", mtimeIMF)]) == .proceed)
        #expect(evaluate(.put, [("If-Unmodified-Since", later)]) == .proceed)
        #expect(evaluate([("If-Unmodified-Since", earlier)]) == .preconditionFailed, "GET too")
        #expect(evaluate(.put, [("If-Unmodified-Since", "not a date")]) == .proceed, "invalid date ignored")
        #expect(evaluate(.put, [("If-Unmodified-Since", earlier), ("If-Unmodified-Since", earlier)]) == .proceed,
                "more than one member is ignored")
        // If-Match present: If-Unmodified-Since is not evaluated.
        #expect(evaluate(.put, [("If-Match", Self.etag), ("If-Unmodified-Since", earlier)]) == .proceed)
        #expect(evaluate(.put, [("If-Match", "\"other\""), ("If-Unmodified-Since", later)]) == .preconditionFailed)
    }

    // MARK: Step 3: If-None-Match (weak comparison)

    @Test func ifNoneMatch() {
        #expect(evaluate([("If-None-Match", Self.etag)]) == .notModified)
        #expect(evaluate(.head, [("If-None-Match", Self.etag)]) == .notModified)
        #expect(evaluate(.post, [("If-None-Match", Self.etag)]) == .preconditionFailed)
        #expect(evaluate(.put, [("If-None-Match", "*")]) == .preconditionFailed)
        #expect(evaluate(.put, [("If-None-Match", "*")], exists: false) == .proceed, "create-only PUT")
        #expect(evaluate([("If-None-Match", "*")]) == .notModified)
        #expect(evaluate([("If-None-Match", "W/\(Self.etag)")]) == .notModified, "weak comparison")
        #expect(evaluate([("If-None-Match", Self.etag)], etag: Array("W/\(Self.etag)".utf8)) == .notModified)
        #expect(evaluate([("If-None-Match", "W/\"stale\", \(Self.etag)")]) == .notModified, "list")
        #expect(evaluate([("If-None-Match", "\"a\",\"b\" ,  W/\"abc-1\"")]) == .notModified, "list whitespace")
        #expect(evaluate([("If-None-Match", "\"a\""), ("If-None-Match", Self.etag)]) == .notModified, "two fields")
        #expect(evaluate([("If-None-Match", "\"a,b\", \(Self.etag)")]) == .notModified, "comma inside quotes")
        #expect(evaluate([("If-None-Match", "\"stale\"")]) == .proceed)
        #expect(evaluate([("If-None-Match", "\"ABC-1\"")]) == .proceed, "opaque tags are case-sensitive")
        #expect(evaluate([("If-None-Match", "w/\(Self.etag)")]) == .proceed, "W/ is case-sensitive")
        #expect(evaluate([("If-None-Match", "\"abc-1")]) == .proceed, "malformed")
    }

    // MARK: Step 4: If-Modified-Since, only without If-None-Match, only GET/HEAD

    @Test func ifModifiedSince() {
        #expect(evaluate([("If-Modified-Since", mtimeIMF)]) == .notModified)
        #expect(evaluate(.head, [("If-Modified-Since", mtimeIMF)]) == .notModified)
        #expect(evaluate([("If-Modified-Since", later)]) == .notModified)
        #expect(evaluate([("If-Modified-Since", earlier)]) == .proceed)
        #expect(evaluate([("If-Modified-Since", "Tuesday, 14-Nov-23 22:13:20 GMT")]) == .notModified, "RFC 850")
        #expect(evaluate([("If-Modified-Since", "Tue Nov 14 22:13:20 2023")]) == .notModified, "asctime")
        #expect(evaluate([("If-Modified-Since", "yesterday")]) == .proceed, "invalid date ignored")
        #expect(evaluate([("If-Modified-Since", mtimeIMF), ("If-Modified-Since", mtimeIMF)]) == .proceed,
                "more than one member is ignored")
        #expect(evaluate(.post, [("If-Modified-Since", mtimeIMF)]) == .proceed, "ignored for POST")
        #expect(evaluate(.put, [("If-Modified-Since", mtimeIMF)]) == .proceed, "ignored for PUT")
    }

    // MARK: Precedence (RFC 9110 §13.2.2)

    @Test func precedence() {
        // #0019: If-None-Match present means If-Modified-Since is ignored, both ways.
        #expect(evaluate([("If-None-Match", "\"stale\""), ("If-Modified-Since", later)]) == .proceed)
        #expect(evaluate([("If-None-Match", Self.etag), ("If-Modified-Since", earlier)]) == .notModified)
        // Step 1 before step 3: a failed If-Match wins over a matching If-None-Match.
        #expect(evaluate([("If-Match", "\"other\""), ("If-None-Match", Self.etag)]) == .preconditionFailed)
        // Step 2 before step 3.
        #expect(evaluate([("If-Unmodified-Since", earlier), ("If-None-Match", Self.etag)]) == .preconditionFailed)
        // Step 2 before step 4.
        #expect(evaluate([("If-Unmodified-Since", earlier), ("If-Modified-Since", later)]) == .preconditionFailed)
        // Passing steps 1/2 still evaluates step 3/4.
        #expect(evaluate([("If-Match", Self.etag), ("If-None-Match", Self.etag)]) == .notModified)
        #expect(evaluate([("If-Match", "*"), ("If-Modified-Since", mtimeIMF)]) == .notModified)
        #expect(evaluate([("If-Unmodified-Since", later), ("If-Modified-Since", mtimeIMF)]) == .notModified)
        #expect(evaluate([("If-Match", Self.etag), ("If-None-Match", "\"x\"")]) == .proceed)
        #expect(evaluate([]) == .proceed)
    }

    @Test func ifRange() {
        func allows(_ value: String?, etag: [UInt8]? = Self.tag) -> Bool {
            let built = TestRequest(.get, "/x", headers: value.map { [("If-Range", $0)] } ?? [])
            return ConditionalRequest.ifRangeAllowsRange(fields: built.request.headers, etag: etag,
                                                         lastModified: Self.lastModified)
        }
        #expect(allows(nil))
        #expect(allows(Self.etag))
        #expect(!allows("\"other\""))
        #expect(!allows("W/\(Self.etag)"), "If-Range needs a strong match")
        #expect(!allows(Self.etag, etag: Array("W/\(Self.etag)".utf8)))
        #expect(allows(mtimeIMF))
        #expect(allows("Tuesday, 14-Nov-23 22:13:20 GMT"))
        #expect(!allows(later), "only an exact date matches")
        #expect(!allows(earlier))
        #expect(!allows("garbage"))
        #expect(!allows(""))
    }
}

@Suite struct StaticFilesConditionalTests {
    /// A fixture with `index.html` whose mtime has a fractional second.
    func fixture(_ configure: (inout StaticFilesConfiguration) -> Void = { _ in }) throws -> (Fixture, StaticFiles) {
        let fixture = try Fixture()
        let url = try fixture.write("index.html", "<h1>hello</h1>")
        try setMTime(url, seconds: mtime, nanoseconds: 750_000_000)
        return (fixture, try fixture.files(configure))
    }

    /// #0017: echoing `Last-Modified` back in `If-Modified-Since` gives 304 even though the mtime
    /// has a sub-second part.
    @Test func legacy0017IfModifiedSinceWithSubSecondMTime() async throws {
        let (fixture, files) = try fixture()
        defer { fixture.remove() }
        let lastModified = try #require(try await files.get("/index.html").header(.lastModified))
        #expect(lastModified == mtimeIMF)
        let response = try await files.get("/index.html", headers: [("If-Modified-Since", lastModified)])
        #expect(response.status == .notModified)
        #expect(try await files.get("/index.html", headers: [("If-Modified-Since", earlier)]).status == .ok)
        // The cache is bypassed too.
        let uncached = try fixture.files { $0.maxCachedEntries = 0 }
        #expect(try await uncached.get("/index.html", headers: [("If-Modified-Since", lastModified)]).status == .notModified)
    }

    /// #0018: a 304 for If-None-Match carries no body and no Content-Length, also through
    /// ErrorPages and the HTTP/1.1 serializer (`curl -I -H 'If-None-Match: "<etag>"'`).
    @Test func legacy0018NotModifiedHasNoBody() async throws {
        let (fixture, files) = try fixture { $0.maxAge = 3600 }
        defer { fixture.remove() }
        let etag = try #require(try await files.get("/index.html").header(.etag))
        for method in [HTTPMethod.get, .head] {
            let built = TestRequest(method, "/index.html", headers: [("If-None-Match", etag)])
            let response = try await ErrorPages().handle(built.request, context: RequestContext(), next: files)
            #expect(response.status == .notModified)
            guard case .empty = response.body else { Issue.record("304 has a body"); continue }
            #expect(response.header(.etag) == etag)
            #expect(response.header(.lastModified) == mtimeIMF)
            #expect(response.header(.cacheControl) == "public, max-age=3600")
            #expect(response.header(.contentLength) == nil)
            #expect(response.header(.contentType) == nil)

            var serializer = HTTP1Serializer(clock: SystemWallClock())
            var buffer = ByteBuffer()
            serializer.write(response, into: &buffer, context: HTTP1ResponseContext(requestMethod: method))
            let head = buffer.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
            #expect(head.hasPrefix("HTTP/1.1 304 Not Modified\r\n"))
            #expect(head.hasSuffix("\r\n\r\n"), "nothing after the head")
            let lower = head.lowercased()
            #expect(!lower.contains("content-length"))
            #expect(lower.contains("\r\ndate: "))
            #expect(lower.contains("\r\netag: \(etag.lowercased())\r\n"))
            #expect(lower.contains("\r\nlast-modified: "))
            #expect(lower.contains("\r\ncache-control: public, max-age=3600\r\n"))
        }
    }

    /// #0019: a list with the current tag matches, and a stale tag beats a recent date.
    @Test func legacy0019IfNoneMatchListAndPrecedence() async throws {
        let (fixture, files) = try fixture()
        defer { fixture.remove() }
        let etag = try #require(try await files.get("/index.html").header(.etag))
        #expect(try await files.get("/index.html", headers: [("If-None-Match", "W/\"stale\", \(etag)")]).status == .notModified)
        #expect(try await files.get("/index.html", headers: [("If-None-Match", "*")]).status == .notModified)
        let stale = try await files.get("/index.html", headers: [("If-None-Match", "\"stale\""), ("If-Modified-Since", later)])
        #expect(stale.status == .ok)
        #expect(stale.bodyText == "<h1>hello</h1>")
    }

    @Test func preconditionFailed() async throws {
        let (fixture, files) = try fixture()
        defer { fixture.remove() }
        let etag = try #require(try await files.get("/index.html").header(.etag))
        #expect(try await files.get("/index.html", headers: [("If-Match", "\"other\"")]).status == .preconditionFailed)
        #expect(try await files.get("/index.html", headers: [("If-Match", etag)]).status == .ok)
        #expect(try await files.get("/index.html", headers: [("If-Unmodified-Since", earlier)]).status == .preconditionFailed)
        #expect(try await files.get("/index.html", headers: [("If-Unmodified-Since", mtimeIMF)]).status == .ok)
        // Preconditions come after the checks that refuse the request (RFC 9110 §13.2.1).
        #expect(try await files.get("/missing.html", headers: [("If-Match", "*")]).status == .notFound)
        #expect(try await files.get("/index.html", method: .post, headers: [("If-None-Match", "*")]).status == .methodNotAllowed)
    }

    @Test func rangeWithIfRange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write("data.bin", Data((0..<1000).map { UInt8($0 % 251) }))
        try setMTime(url, seconds: mtime, nanoseconds: 250_000_000)
        let files = try fixture.files()
        let etag = try #require(try await files.get("/data.bin").header(.etag))
        func get(_ headers: [(String, String)]) async throws -> HTTPResponse {
            try await files.get("/data.bin", headers: [("Range", "bytes=0-9")] + headers)
        }
        #expect(try await get([("If-Range", etag)]).status == .partialContent)
        #expect(try await get([("If-Range", mtimeIMF)]).status == .partialContent, "date equal at whole seconds")
        let mismatch = try await get([("If-Range", "\"other\"")])
        #expect(mismatch.status == .ok)
        #expect(mismatch.bodyBytes.count == 1000)
        #expect(try await get([("If-Range", later)]).status == .ok)
        // Preconditions are evaluated before Range: 304 wins over 206.
        #expect(try await get([("If-None-Match", etag)]).status == .notModified)
        #expect(try await get([("If-Match", "\"other\"")]).status == .preconditionFailed)
        #expect(try await get([("If-Match", etag), ("If-Range", etag)]).status == .partialContent)
    }

    @Test func cacheControlConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a")
        #expect(try await fixture.files().get("/a.txt").header(.cacheControl) == nil)
        #expect(try await fixture.files { $0.maxAge = 60 }.get("/a.txt").header(.cacheControl) == "public, max-age=60")
        let both = try fixture.files { $0.maxAge = 60; $0.cacheControl = "no-cache" }
        let etag = try #require(try await both.get("/a.txt").header(.etag))
        #expect(try await both.get("/a.txt").header(.cacheControl) == "no-cache")
        #expect(try await both.get("/a.txt", headers: [("If-None-Match", etag)]).header(.cacheControl) == "no-cache")
        let none = try fixture.files()
        let notModified = try await none.get("/a.txt", headers: [("If-None-Match", etag)])
        #expect(notModified.status == .notModified)
        #expect(notModified.header(.cacheControl) == nil)
    }

    @Test func largeFileNotModified() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("big.bin", Data(count: 200_000))
        let files = try fixture.files()
        let etag = try #require(try await files.get("/big.bin").header(.etag))
        let response = try await files.get("/big.bin", headers: [("If-None-Match", etag)])
        #expect(response.status == .notModified)
        #expect(response.body.knownLength == 0)
    }
}

@Suite struct ErrorPagesTests {
    struct Fixed: HTTPHandler {
        let response: HTTPResponse
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse { response }
    }

    func run(_ pages: ErrorPages, _ response: HTTPResponse, method: HTTPMethod = .get) async throws -> HTTPResponse {
        let built = TestRequest(method, "/x")
        return try await pages.handle(built.request, context: RequestContext(), next: Fixed(response: response))
    }

    @Test func defaultPageForEmptyErrors() async throws {
        let response = try await run(ErrorPages(), HTTPResponse(status: .notFound))
        #expect(response.status == .notFound)
        #expect(response.header(.contentType) == "text/html; charset=utf-8")
        #expect(response.bodyText.contains("<title>404 Not Found</title>"))
        #expect(response.bodyText.contains("<h1>404 Not Found</h1>"))
        let server = try await run(ErrorPages(), HTTPResponse(status: .internalServerError))
        #expect(server.bodyText.contains("500 Internal Server Error"))
        let unregistered = try await run(ErrorPages(), HTTPResponse(status: HTTPStatus(code: 499)))
        #expect(unregistered.bodyText.contains("<h1>499</h1>"))
    }

    @Test func keepsTheHandlersFields() async throws {
        var headers = HTTPFields()
        headers.append(.allow, "GET, HEAD")
        let response = try await run(ErrorPages(), HTTPResponse(status: .methodNotAllowed, headers: headers))
        #expect(response.header(.allow) == "GET, HEAD")
        #expect(response.bodyText.contains("405 Method Not Allowed"))
    }

    /// #0018: no page for 1xx, 2xx, 204, 3xx, 304, HEAD, or a body the handler chose.
    @Test func neverReplacesOtherBodies() async throws {
        let pages = ErrorPages()
        for status in [HTTPStatus.continue, .ok, .noContent, .movedPermanently, .notModified] {
            guard case .empty = try await run(pages, HTTPResponse(status: status)).body else {
                Issue.record("\(status.code) got a body"); continue
            }
        }
        guard case .empty = try await run(pages, HTTPResponse(status: .notFound), method: .head).body else {
            Issue.record("HEAD got a body"); return
        }
        let own = try await run(pages, HTTPResponse(status: .notFound, body: .bytes(ByteBuffer("custom"))))
        #expect(own.bodyText == "custom")
        #expect(own.header(.contentType) == nil)
        var length = HTTPFields()
        length.append(.contentLength, "0")
        guard case .empty = try await run(pages, HTTPResponse(status: .notFound, headers: length)).body else {
            Issue.record("explicit Content-Length got a body"); return
        }
    }

    @Test func customPagesFromFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("errors/404.html", "<p>gone</p>")
        try fixture.write("errors/503.txt", "busy")
        try fixture.write("outside.html", "x", in: fixture.base)
        let pages = try ErrorPages(root: fixture.root.path, pages: [404: "errors/404.html", 503: "errors/503.txt"])
        let missing = try await run(pages, HTTPResponse(status: .notFound))
        #expect(missing.bodyText == "<p>gone</p>")
        #expect(missing.header(.contentType) == "text/html; charset=utf-8")
        #expect(try await run(pages, HTTPResponse(status: .serviceUnavailable)).header(.contentType)?.hasPrefix("text/plain") == true)
        #expect(try await run(pages, HTTPResponse(status: .forbidden)).bodyText.contains("403 Forbidden"))

        let only = try ErrorPages(root: fixture.root.path, pages: [404: "errors/404.html"], defaultPages: false)
        guard case .empty = try await run(only, HTTPResponse(status: .forbidden)).body else {
            Issue.record("defaultPages: false still generated a page"); return
        }

        #expect(throws: ErrorPages.InitError.pageOutsideRoot(status: 404)) {
            try ErrorPages(root: fixture.root.path, pages: [404: "../outside.html"])
        }
        #expect(throws: ErrorPages.InitError.pageUnavailable(status: 404, errno: ENOENT)) {
            try ErrorPages(root: fixture.root.path, pages: [404: "errors/none.html"])
        }
        #expect(throws: ErrorPages.InitError.invalidStatus(304)) {
            try ErrorPages(root: fixture.root.path, pages: [304: "errors/404.html"])
        }
    }

    /// StaticFiles behind ErrorPages: refusals get pages, files and 304s do not.
    @Test func withStaticFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a")
        let files = try fixture.files()
        let pages = ErrorPages()
        func get(_ path: String, _ method: HTTPMethod = .get, _ headers: [(String, String)] = []) async throws -> HTTPResponse {
            let built = TestRequest(method, path, headers: headers)
            return try await pages.handle(built.request, context: RequestContext(), next: files)
        }
        #expect(try await get("/a.txt").bodyText == "a")
        #expect(try await get("/missing").bodyText.contains("404 Not Found"))
        #expect(try await get("/.git/config").bodyText.contains("403 Forbidden"))
        let etag = try #require(try await get("/a.txt").header(.etag))
        #expect(try await get("/a.txt", .get, [("If-Match", "\"x\"")]).bodyText.contains("412 Precondition Failed"))
        guard case .empty = try await get("/a.txt", .get, [("If-None-Match", etag)]).body else {
            Issue.record("304 got a body"); return
        }
        let range = try await get("/a.txt", .get, [("Range", "bytes=5-")])
        #expect(range.status == .rangeNotSatisfiable)
        #expect(range.header(.contentRange) == "bytes */1")
        #expect(range.bodyText.contains("416"))
    }
}
