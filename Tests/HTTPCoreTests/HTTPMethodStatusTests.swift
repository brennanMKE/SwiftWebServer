import Testing
import HTTPCore

private func parse(_ text: String) -> HTTPMethod? {
    var bytes = Array(text.utf8)
    return bytes.withUnsafeMutableBufferPointer { HTTPMethod($0.span) }
}

@Suite struct HTTPMethodTests {
    @Test(arguments: [
        ("GET", HTTPMethod.get), ("HEAD", .head), ("POST", .post), ("PUT", .put),
        ("DELETE", .delete), ("CONNECT", .connect), ("OPTIONS", .options), ("TRACE", .trace),
        ("PATCH", .patch),
    ])
    func standardMethodsParse(text: String, method: HTTPMethod) {
        #expect(parse(text) == method)
        #expect(HTTPMethod.standardMethods.contains(method))
        #expect(method.standardName?.description == text)
        #expect(method.description == text)
        var out = ByteBuffer()
        method.append(to: &out)
        #expect(out.withReadableSpan { ASCII.string(from: $0) } == text)
    }

    @Test func standardMethodListIsComplete() {
        #expect(HTTPMethod.standardMethods.count == 9)
        #expect(Set(HTTPMethod.standardMethods).count == 9)
    }

    /// Methods are case-sensitive (RFC 9110 §9.1).
    @Test func lowercaseIsAnExtensionMethod() {
        guard case .other(let token) = parse("get") else {
            Issue.record("get should be .other")
            return
        }
        #expect(token.description == "get")
        #expect(parse("Get") != .get)
    }

    @Test(arguments: ["PROPFIND", "MKCOL", "COPY", "LOCK", "UNLOCK", "VERSION-CONTROL", "BASELINE-CONTROL",
                      "UPDATEREDIRECTREF", "X", "GETS", "GE", "M-SEARCH", "PRI", "QUERY", "ORDERPATCH",
                      "A!#$%&'*+-.^_`|~9", "EXACTLY24CHARACTERSLONG!"])
    func extensionTokensRoundTrip(text: String) {
        let method = parse(text)
        guard case .other(let token) = method else {
            Issue.record("\(text) should be .other, got \(String(describing: method))")
            return
        }
        #expect(token.count == text.utf8.count)
        #expect(method?.description == text)
        #expect(method?.standardName == nil)
        #expect(HTTPMethod.Token(StaticString("PROPFIND")).map { HTTPMethod.other($0) } == parse("PROPFIND"))
        var out = ByteBuffer()
        method?.append(to: &out)
        #expect(out.withReadableSpan { ASCII.string(from: $0) } == text)
    }

    @Test(arguments: ["", "GET ", " GET", "G\u{0}T", "GÉT", "GET/", "A(B", "THIS-METHOD-IS-25-CHARSXX"])
    func invalidTokensAreRejected(text: String) {
        #expect(parse(text) == nil)
    }

    @Test func equalExtensionTokensAreEqualAndHashable() {
        #expect(parse("PROPFIND") == parse("PROPFIND"))
        #expect(parse("PROPFIND") != parse("PROPPATCH"))
        #expect(Set([parse("MKCOL"), parse("MKCOL"), parse("GET")]).count == 2)
    }

    @Test func staticStringInitializer() {
        #expect(HTTPMethod("DELETE") == .delete)
        #expect(HTTPMethod(StaticString("BAD METHOD")) == nil)
    }
}

@Suite struct HTTPStatusTests {
    static let expected: [(Int, String)] = [
        (100, "Continue"), (101, "Switching Protocols"), (103, "Early Hints"),
        (200, "OK"), (201, "Created"), (202, "Accepted"), (203, "Non-Authoritative Information"),
        (204, "No Content"), (205, "Reset Content"), (206, "Partial Content"),
        (300, "Multiple Choices"), (301, "Moved Permanently"), (302, "Found"), (303, "See Other"),
        (304, "Not Modified"), (307, "Temporary Redirect"), (308, "Permanent Redirect"),
        (400, "Bad Request"), (401, "Unauthorized"), (403, "Forbidden"), (404, "Not Found"),
        (405, "Method Not Allowed"), (406, "Not Acceptable"), (407, "Proxy Authentication Required"),
        (408, "Request Timeout"), (409, "Conflict"), (410, "Gone"), (411, "Length Required"),
        (412, "Precondition Failed"), (413, "Content Too Large"), (414, "URI Too Long"),
        (415, "Unsupported Media Type"), (416, "Range Not Satisfiable"), (417, "Expectation Failed"),
        (421, "Misdirected Request"), (422, "Unprocessable Content"), (425, "Too Early"),
        (426, "Upgrade Required"), (428, "Precondition Required"), (429, "Too Many Requests"),
        (431, "Request Header Fields Too Large"),
        (500, "Internal Server Error"), (501, "Not Implemented"), (502, "Bad Gateway"),
        (503, "Service Unavailable"), (504, "Gateway Timeout"), (505, "HTTP Version Not Supported"),
    ]

    @Test func registeredStatusLinesArePreRendered() {
        #expect(HTTPStatus.registeredCodes == Self.expected.map(\.0))
        for (code, reason) in Self.expected {
            let status = HTTPStatus(code: code)
            #expect(status.http1StatusLine?.description == "HTTP/1.1 \(code) \(reason)\r\n")
            #expect(status.reasonPhrase == reason)
            var out = ByteBuffer()
            status.appendHTTP1StatusLine(to: &out)
            #expect(out.withReadableSpan { ASCII.string(from: $0) } == "HTTP/1.1 \(code) \(reason)\r\n")
        }
    }

    @Test func namedConstants() {
        #expect(HTTPStatus.ok.code == 200)
        #expect(HTTPStatus.`continue`.code == 100)
        #expect(HTTPStatus.notFound.reasonPhrase == "Not Found")
        #expect(HTTPStatus.requestHeaderFieldsTooLarge.code == 431)
        #expect(HTTPStatus.contentTooLarge.http1StatusLine?.description == "HTTP/1.1 413 Content Too Large\r\n")
    }

    @Test func customReasonAndUnregisteredCodeRender() {
        let custom = HTTPStatus(code: 200, reasonPhrase: "Fine")
        #expect(custom.http1StatusLine == nil)
        #expect(custom == .ok)
        var out = ByteBuffer()
        custom.appendHTTP1StatusLine(to: &out)
        #expect(out.withReadableSpan { ASCII.string(from: $0) } == "HTTP/1.1 200 Fine\r\n")

        let unregistered = HTTPStatus(code: 599)
        #expect(unregistered.http1StatusLine == nil)
        #expect(unregistered.reasonPhrase == "")
        out.clear()
        unregistered.appendHTTP1StatusLine(to: &out)
        #expect(out.withReadableSpan { ASCII.string(from: $0) } == "HTTP/1.1 599 \r\n")
        out.clear()
        unregistered.appendCode(to: &out)
        #expect(out.withReadableSpan { ASCII.string(from: $0) } == "599")
    }

    @Test func kindsAndContentRules() {
        #expect(HTTPStatus.switchingProtocols.kind == .informational)
        #expect(HTTPStatus.ok.kind == .successful)
        #expect(HTTPStatus.notModified.kind == .redirection)
        #expect(HTTPStatus.badRequest.kind == .clientError)
        #expect(HTTPStatus.badGateway.kind == .serverError)
        #expect(HTTPStatus(code: 999).kind == .nonStandard)
        #expect(HTTPStatus.noContent.forbidsContent)
        #expect(HTTPStatus.notModified.forbidsContent)
        #expect(HTTPStatus.earlyHints.forbidsContent)
        #expect(!HTTPStatus.ok.forbidsContent)
    }
}
