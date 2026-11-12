import HPACK
@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Testing

/// #0047: request header fields and pseudo-headers (RFC 9113 §8.1.1, §8.2, §8.3.1), one test
/// per rule, then the same rules over a connection (a malformed request is a stream
/// `PROTOCOL_ERROR` and the connection carries on).
@Suite struct H2RequestHeadTests {
    typealias Malformed = HTTP2MalformedRequest

    static let base: [(String, String)] = [
        (":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/a?b=c"),
    ]

    /// Feeds `fields` to a request sink, as HPACK would.
    static func head(_ fields: [(String, String)], endStream: Bool = true)
        -> (Result<HTTP2RequestHead, Malformed>, HTTPRequestStorage)
    {
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
        var sink = HTTP2RequestFieldSink(storage: storage)
        for (name, value) in fields {
            let n = Array(name.utf8)
            let v = Array(value.utf8)
            n.withUnsafeBufferPointer { n in
                v.withUnsafeBufferPointer { v in
                    sink.field(name: n.span, value: v.span, representation: .withoutIndexing)
                }
            }
        }
        return (sink.head(endStream: endStream), storage)
    }

    static func failure(_ fields: [(String, String)], endStream: Bool = true) -> Malformed? {
        if case .failure(let error) = head(fields, endStream: endStream).0 { return error }
        return nil
    }

    static func violation(_ fields: [(String, String)]) -> PseudoHeaderValidator.Violation? {
        if case .field(let violation)? = failure(fields) { return violation }
        return nil
    }

    // MARK: Accepted

    @Test func validRequestMapsToHTTPRequest() throws {
        let (result, _) = Self.head(Self.base + [("accept", "*/*"), ("te", "trailers")])
        let head = try result.get()
        let request = head.request
        #expect(request.method == .get)
        #expect(request.string(of: request.scheme) == "https")
        #expect(request.string(of: request.authority) == "example.com")
        #expect(request.string(of: request.path) == "/a")
        #expect(request.string(of: request.query) == "b=c")
        #expect(request.headers.count == 2)
        #expect(head.contentLength == nil)
    }

    @Test func hostAloneStandsInForAuthority() throws {
        let fields = [(":method", "GET"), (":scheme", "http"), (":path", "/"), ("host", "h")]
        #expect(throws: Never.self) { try Self.head(fields).0.get() }
    }

    @Test func asteriskPathIsAllowedForOptions() throws {
        let fields = [(":method", "OPTIONS"), (":scheme", "http"), (":authority", "h"), (":path", "*")]
        #expect(throws: Never.self) { try Self.head(fields).0.get() }
    }

    // MARK: Pseudo-headers

    @Test(arguments: [":method", ":scheme", ":path"])
    func missingPseudoHeader(name: String) {
        let fields = Self.base.filter { $0.0 != name }
        #expect(Self.failure(fields) != nil, "\(name)")
    }

    @Test func missingAuthorityAndHost() {
        #expect(Self.violation(Self.base.filter { $0.0 != ":authority" }) == .missingPseudoHeader(.pseudoAuthority))
    }

    @Test func duplicatePseudoHeader() {
        #expect(Self.violation(Self.base + [(":path", "/b")]) == .duplicatePseudoHeader(.pseudoPath))
    }

    @Test func emptyPath() {
        #expect(Self.violation(Self.base.map { $0.0 == ":path" ? (":path", "") : $0 }) == .emptyPath)
    }

    @Test func asteriskPathNeedsOptions() {
        #expect(Self.violation(Self.base.map { $0.0 == ":path" ? (":path", "*") : $0 }) == .asteriskPathRequiresOptions)
    }

    @Test func pseudoHeaderAfterRegularField() {
        let fields = [Self.base[0], ("accept", "*/*")] + Self.base.dropFirst()
        #expect(Self.violation(fields) == .pseudoHeaderAfterRegularField)
    }

    @Test func unknownPseudoHeader() {
        #expect(Self.violation(Self.base + [(":foo", "bar")]) == .unknownPseudoHeader)
    }

    @Test func responsePseudoHeaderInARequest() {
        #expect(Self.violation(Self.base + [(":status", "200")]) == .pseudoHeaderNotAllowed(.pseudoStatus))
    }

    // MARK: Field names and values

    @Test func uppercaseFieldName() {
        #expect(Self.violation(Self.base + [("Accept", "*/*")]) == .invalidFieldName)
    }

    @Test func invalidFieldNameCharacter() {
        #expect(Self.violation(Self.base + [("a b", "c")]) == .invalidFieldName)
    }

    @Test(arguments: ["a\rb", "a\nb", "a\u{0}b", " a", "a ", "\ta"])
    func invalidFieldValue(value: String) {
        #expect(Self.violation(Self.base + [("x-test", value)]) == .invalidFieldValue)
    }

    @Test(arguments: ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"])
    func connectionSpecificField(name: String) {
        guard case .connectionSpecificField? = Self.violation(Self.base + [(name, "x")]) else {
            Issue.record("\(name) accepted")
            return
        }
    }

    @Test func teOtherThanTrailers() {
        #expect(Self.violation(Self.base + [("te", "gzip")]) == .invalidTE)
    }

    // MARK: Cookies, content-length, host

    @Test func cookieCrumbsAreJoined() throws {
        let (result, _) = Self.head(Self.base + [("cookie", "a=1"), ("accept", "*/*"), ("cookie", "b=2"), ("cookie", "c=3")])
        let request = try result.get().request
        let cookies = request.headers.firstValue(for: .cookie)
        #expect(cookies.map { request.string(of: $0) } == "a=1; b=2; c=3")
        #expect(request.headers.count == 2)
    }

    @Test func singleCookieIsKept() throws {
        let (result, _) = Self.head(Self.base + [("cookie", "a=1")])
        let request = try result.get().request
        #expect(request.headers.firstValue(for: .cookie).map { request.string(of: $0) } == "a=1")
    }

    @Test func contentLengthIsRecorded() throws {
        let (result, _) = Self.head(Self.base + [("content-length", "12"), ("content-length", "12")], endStream: false)
        #expect(try result.get().contentLength == 12)
    }

    @Test(arguments: ["", "-1", "1 2", "0x10", "99999999999999999999999"])
    func invalidContentLength(value: String) {
        #expect(Self.failure(Self.base + [("content-length", value)], endStream: false) == .invalidContentLength)
    }

    @Test func conflictingContentLengths() {
        #expect(Self.failure(Self.base + [("content-length", "1"), ("content-length", "2")], endStream: false)
                == .invalidContentLength)
    }

    @Test func contentLengthWithEndStream() {
        #expect(Self.failure(Self.base + [("content-length", "3")], endStream: true) == .contentLengthWithoutBody)
        #expect(Self.failure(Self.base + [("content-length", "0")], endStream: true) == nil)
    }

    @Test func hostMustMatchAuthority() {
        #expect(Self.failure(Self.base + [("host", "other.com")]) == .hostMismatch)
        #expect(Self.failure(Self.base + [("host", "EXAMPLE.com")]) == nil)
    }

    @Test func trailersRejectPseudoHeadersAndInvalidFields() {
        func trailers(_ fields: [(String, String)]) -> HTTP2TrailerFieldSink {
            var sink = HTTP2TrailerFieldSink()
            for (name, value) in fields {
                let n = Array(name.utf8)
                let v = Array(value.utf8)
                n.withUnsafeBufferPointer { n in
                    v.withUnsafeBufferPointer { v in sink.field(name: n.span, value: v.span, representation: .indexed) }
                }
            }
            return sink
        }
        let good = trailers([("x-checksum", "abc"), ("x-more", "1")])
        #expect(good.failure == nil)
        #expect(good.fields.count == 2)
        #expect(trailers([(":path", "/")]).failure == .field(.pseudoHeaderAfterRegularField))
        #expect(trailers([("X-Upper", "1")]).failure == .field(.invalidFieldName))
    }

    // MARK: Over a connection

    /// Every rule above, sent as a request: each is RST_STREAM(PROTOCOL_ERROR) on its stream,
    /// never a GOAWAY, and the next request is served.
    @Test(.timeLimit(.minutes(1)))
    func malformedRequestsAreStreamErrors() async throws {
        let cases: [[(String, String)]] = [
            Self.base.filter { $0.0 != ":method" },
            Self.base + [(":path", "/b")],
            Self.base + [(":status", "200")],
            Self.base + [("Accept", "x")],
            Self.base + [("x", "a\u{0}b")],
            Self.base + [("connection", "close")],
            Self.base + [("te", "gzip")],
            Self.base + [("content-length", "abc")],
            Self.base + [("content-length", "5")],  // END_STREAM: no DATA can follow
            Self.base + [("host", "elsewhere")],
        ]
        try await withH2Connection { client in
            try await client.handshake()
            var stream: UInt32 = 1
            for fields in cases {
                try await client.send(F.headers(stream, block: client.requests.block(fields)))
                let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
                #expect(frames.last == .rstStream(stream: stream, .protocolError), "\(fields): \(frames)")
                stream += 2
            }
            try await client.send(F.headers(stream, block: client.requests.get("/ok")))
            #expect(String(decoding: try await client.response(on: stream).body, as: UTF8.self) == "hello /ok")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerSeesJoinedCookie() async throws {
        let handler = ClosureHandler { request in
            let cookie = request.headers.firstValue(for: .cookie).map { request.string(of: $0) } ?? "-"
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(cookie.utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            let block = client.requests.get("/", extra: [("cookie", "a=1"), ("cookie", "b=2")])
            try await client.send(F.headers(1, block: block))
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "a=1; b=2")
        }
    }
}
