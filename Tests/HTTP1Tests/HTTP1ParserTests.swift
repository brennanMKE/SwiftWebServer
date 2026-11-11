import Testing
import HTTPCore
import HTTP1
import HTTPTestSupport

@Suite struct HTTP1ParserTests {
    typealias Outcome = HTTP1HeadOutcome

    func parse(_ text: String, limits: HTTP1ParserLimits = HTTP1ParserLimits()) -> Outcome {
        ParserDriver.oneShot(HTTP1Corpus.bytes(text), limits: limits)
    }

    func error(_ text: String, limits: HTTP1ParserLimits = HTTP1ParserLimits()) -> HTTP1ParseError? {
        var parser = HTTP1Parser(limits: limits)
        var buffer = ByteBuffer(bytes: HTTP1Corpus.bytes(text))
        if case .error(let error) = parser.parseHead(&buffer) { return error }
        return nil
    }

    func head(_ text: String) -> Outcome.Head? {
        if case .complete(let head) = parse(text) { return head }
        return nil
    }

    // MARK: Complete heads

    @Test func browserRequest() throws {
        let head = try #require(head(HTTP1Corpus.browser))
        #expect(head.method == "GET")
        #expect(head.version == .http1_1)
        #expect(head.form == .origin)
        #expect(head.path == "/index.html")
        #expect(head.query == "lang=en")
        #expect(head.framing == .none)
        #expect(head.length == HTTP1Corpus.bytes(HTTP1Corpus.browser).count)
        #expect(head.fields.count == 10)
        #expect(head.fields[0] == .init(name: "Host", id: .host, value: "example.com"))
        #expect(head.fields[1].id == .userAgent)
        #expect(head.fields[9] == .init(name: "X-Request-ID", id: .xRequestID, value: "42"))
    }

    @Test func valuesAreTrimmedAndEmptyValuesKept() throws {
        let head = try #require(head("GET / HTTP/1.1\r\nHost:a\r\nX-Empty:\r\nX-Trim: \t a  b \t\r\n\r\n"))
        #expect(head.fields.map(\.value) == ["a", "", "a  b"])
        #expect(head.fields[1].id == .unknown)
    }

    @Test func targetForms() throws {
        let absolute = try #require(head("GET http://example.com:80/p?q=1 HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(absolute.form == .absolute)
        #expect(absolute.scheme == "http")
        #expect(absolute.authority == "example.com:80")
        #expect(absolute.path == "/p")
        #expect(absolute.query == "q=1")

        let noPath = try #require(head("GET http://example.com HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(noPath.path == "")
        #expect(noPath.authority == "example.com")

        let connect = try #require(head("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"))
        #expect(connect.form == .authority)
        #expect(connect.authority == "example.com:443")
        #expect(connect.path == "")

        let asterisk = try #require(head("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(asterisk.form == .asterisk)
        #expect(asterisk.path == "*")

        #expect(error("GET * HTTP/1.1\r\nHost: x\r\n\r\n") == .invalidRequestTarget)
        #expect(error("CONNECT /x HTTP/1.1\r\nHost: x\r\n\r\n") == .invalidRequestTarget)
        #expect(error("GET example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n") == .invalidRequestTarget)
    }

    @Test func percentFlags() throws {
        let plain = try #require(head("GET /a/b?c=d HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(!plain.pathHasPercent && !plain.queryHasPercent)
        let path = try #require(head("GET /a%20b?c=d HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(path.pathHasPercent && !path.queryHasPercent)
        let query = try #require(head("GET /a?c=%41 HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(!query.pathHasPercent && query.queryHasPercent)
    }

    @Test func methods() throws {
        #expect(try #require(head("PROPFIND / HTTP/1.1\r\nHost: x\r\n\r\n")).method == "PROPFIND")
        #expect(try #require(head("get / HTTP/1.1\r\nHost: x\r\n\r\n")).method == "get")
        var parser = HTTP1Parser()
        var buffer = ByteBuffer("DELETE / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(parser.parseHead(&buffer) == .complete)
        #expect(parser.head.method == .delete)
        #expect(error("ABCDEFGHIJKLMNOPQRSTUVWXY / HTTP/1.1\r\n\r\n") == .methodTooLong)
        #expect(error("ABCDEFGHIJKLMNOPQRSTUVWXY / HTTP/1.1\r\n\r\n")?.status == .notImplemented)
        #expect(error("G@T / HTTP/1.1\r\n\r\n") == .invalidMethod)
    }

    @Test func versions() throws {
        #expect(try #require(head("GET / HTTP/1.0\r\n\r\n")).version == .http1_0)
        #expect(error("GET / HTTP/2.0\r\nHost: x\r\n\r\n") == .unsupportedVersion)
        #expect(error("GET / HTTP/1.2\r\nHost: x\r\n\r\n")?.status == .httpVersionNotSupported)
        #expect(error("GET / HTTP/1.1x\r\nHost: x\r\n\r\n") == .invalidVersion)
        #expect(error("GET / HTTP/1.1 \r\nHost: x\r\n\r\n") == .invalidVersion)
        #expect(error("GET /\r\n\r\n") == .invalidRequestTarget)
    }

    // MARK: RFC 9112 line and field rules

    @Test func lineAndFieldRules() {
        #expect(error("GET / HTTP/1.1\nHost: x\r\n\r\n") == .bareLineFeed)
        #expect(error("GET / HTTP/1.1\r\nHost: x\n\r\n") == .bareLineFeed)
        #expect(error("GET / HTTP/1.1\r\nHost: x\r\n\n") == .bareLineFeed)
        #expect(error("GET / HTTP/1.1\rHost: x\r\n\r\n") == .bareCarriageReturn)
        #expect(error("GET / HTTP/1.1\r\nHost: x\rY\r\n\r\n") == .bareCarriageReturn)
        #expect(error("GET / HTTP/1.1\r\nHost : x\r\n\r\n") == .whitespaceBeforeColon)
        #expect(error("GET / HTTP/1.1\r\nHost: x\r\nX: a\r\n b\r\n\r\n") == .obsoleteLineFolding)
        #expect(error("GET / HTTP/1.1\r\n Host: x\r\n\r\n") == .obsoleteLineFolding)
        #expect(error("GET / HTTP/1.1\r\nHost: x\u{0}\r\n\r\n") == .invalidFieldValue)
        #expect(error("GET / HTTP/1.1\r\nHost: x\u{7F}\r\n\r\n") == .invalidFieldValue)
        #expect(error("GET / HTTP/1.1\r\nHo\"st: x\r\n\r\n") == .invalidFieldName)
        #expect(error("GET / HTTP/1.1\r\n: x\r\n\r\n") == .invalidFieldName)
        #expect(error("GET / HTTP/1.1\r\nHost x\r\n\r\n") == .whitespaceBeforeColon)
    }

    @Test func host() {
        #expect(error("GET / HTTP/1.1\r\n\r\n") == .missingHost)
        #expect(error("GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n") == .multipleHost)
        #expect(error("GET / HTTP/1.0\r\nHost: a\r\nHost: a\r\n\r\n") == .multipleHost)
        #expect(head("GET / HTTP/1.0\r\n\r\n") != nil)
    }

    // MARK: Framing (RFC 9112 §6.3)

    @Test func framing() throws {
        func framing(_ fields: String) -> HTTP1BodyFraming? {
            head("POST / HTTP/1.1\r\nHost: a\r\n\(fields)\r\n")?.framing
        }
        func framingError(_ fields: String) -> HTTP1ParseError? {
            error("POST / HTTP/1.1\r\nHost: a\r\n\(fields)\r\n")
        }
        #expect(framing("") == HTTP1BodyFraming.none)
        #expect(framing("Content-Length: 42\r\n") == .contentLength(42))
        #expect(framing("Content-Length: 0\r\n") == .contentLength(0))
        #expect(framing("Content-Length: 7\r\nContent-Length: 7\r\n") == .contentLength(7))
        #expect(framing("Transfer-Encoding: chunked\r\n") == .chunked)
        #expect(framing("Transfer-Encoding: Chunked\r\n") == .chunked)

        #expect(framingError("Transfer-Encoding: chunked\r\nContent-Length: 1\r\n") == .transferEncodingWithContentLength)
        #expect(framingError("Content-Length: 1\r\nContent-Length: 2\r\n") == .conflictingContentLength)
        #expect(framingError("Content-Length: 1, 2\r\n") == .conflictingContentLength)
        #expect(framingError("Content-Length: x\r\n") == .invalidContentLength)
        #expect(framingError("Content-Length: x\r\n")?.status == .badRequest)
        #expect(framingError("Transfer-Encoding: chunked, gzip\r\n") == .invalidTransferEncoding)
        #expect(framingError("Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n") == .invalidTransferEncoding)
        #expect(framingError("Transfer-Encoding: gzip\r\n") == .invalidTransferEncoding)
        #expect(framingError("Transfer-Encoding: gzip, chunked\r\n") == .unsupportedTransferCoding)
        #expect(framingError("Transfer-Encoding: gzip, chunked\r\n")?.status == .notImplemented)
        #expect(error("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n") == .invalidTransferEncoding)
    }

    // MARK: Limits

    @Test func limits() {
        let small = HTTP1ParserLimits(maxRequestLineLength: 16, maxHeaderCount: 2, maxHeadBytes: 64)
        #expect(error("GET /0123456789 HTTP/1.1\r\n", limits: small) == .requestLineTooLong)
        #expect(error("GET /0123456789 HTTP/1.1\r\n", limits: small)?.status == .uriTooLong)
        // Exactly at the limit is fine.
        #expect(parse("GET /a HTTP/1.1\r\nHost: a\r\n\r\n",
                      limits: HTTP1ParserLimits(maxRequestLineLength: 15)) != .error(status: 414))
        #expect(error("GET / HTTP/1.1\r\nHost: a\r\nB: b\r\nC: c\r\n\r\n", limits: small) == .tooManyFields)
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nB: b\r\n\r\n", limits: small) != .error(status: 431))
        #expect(error("GET / HTTP/1.1\r\nHost: \(String(repeating: "a", count: 60))", limits: small) == .headTooLarge)
        #expect(error("GET / HTTP/1.1\r\nHost: \(String(repeating: "a", count: 60))", limits: small)?.status == .requestHeaderFieldsTooLarge)
    }

    /// An endless head is rejected with 431 once it crosses the default limit (#0011 part).
    @Test func oversizedHeadReturns431() {
        var parser = HTTP1Parser()
        var buffer = ByteBuffer("GET / HTTP/1.1\r\nHost: a\r\n")
        #expect(parser.parseHead(&buffer) == .needMoreBytes)
        var result = HTTP1ParseResult.needMoreBytes
        var line = 0
        while result == .needMoreBytes && line < 10_000 {
            buffer.append("X-Filler: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\r\n")
            result = parser.parseHead(&buffer)
            line += 1
        }
        #expect(result == .error(.headTooLarge))
        #expect(buffer.readableBytes > HTTP1ParserLimits.defaultMaxHeadBytes)
        #expect(buffer.readableBytes < HTTP1ParserLimits.defaultMaxHeadBytes + 220)
    }

    // MARK: Incremental parsing

    /// Legacy #0006: a head without its final CRLF is not complete.
    @Test func issue0006IncompleteHeadNeedsMoreBytes() {
        for fragment in HTTP1Corpus.issue0006Fragments {
            #expect(parse(fragment) == .needMoreBytes, "\(fragment.debugDescription)")
        }
        // The repro: request line first, then the fields; If-None-Match must be seen.
        var parser = HTTP1Parser()
        var buffer = ByteBuffer("GET /index.html HTTP/1.1\r\n")
        #expect(parser.parseHead(&buffer) == .needMoreBytes)
        buffer.append("Host: localhost\r\nIf-None-Match: \"abc\"\r\n\r\n")
        #expect(parser.parseHead(&buffer) == .complete)
        #expect(parser.fields.contains(.ifNoneMatch))
        #expect(buffer.isEmpty)
    }

    @Test func resumesWithoutRescanning() {
        // Feeding a byte at a time completes exactly when the last byte arrives, and the
        // reader index stays put until then.
        let bytes = HTTP1Corpus.bytes(HTTP1Corpus.browser)
        var parser = HTTP1Parser()
        var buffer = ByteBuffer()
        for (i, byte) in bytes.enumerated() {
            buffer.append(byte)
            let result = parser.parseHead(&buffer)
            if i < bytes.count - 1 {
                #expect(result == .needMoreBytes)
                #expect(buffer.readerIndex == 0)
                #expect(parser.isInProgress)
            } else {
                #expect(result == .complete)
            }
        }
        #expect(buffer.isEmpty)
        #expect(!parser.isInProgress)
    }

    @Test func pipelinedHeadsInOneBuffer() throws {
        let first = "GET /one HTTP/1.1\r\nHost: a\r\n\r\n"
        let second = "POST /two HTTP/1.1\r\nHost: b\r\nContent-Length: 3\r\n\r\n"
        let third = "GET /three HTTP/1.1\r\nHost: c\r\n\r\n"
        var buffer = ByteBuffer(bytes: HTTP1Corpus.bytes(first + second + "abc" + third + "GET /four HT"))
        var parser = HTTP1Parser()

        #expect(parser.parseHead(&buffer) == .complete)
        #expect(parser.head.path.string(in: buffer) == "/one")
        #expect(parser.head.framing == .none)

        #expect(parser.parseHead(&buffer) == .complete)
        #expect(parser.head.path.string(in: buffer) == "/two")
        #expect(parser.head.framing == .contentLength(3))
        #expect(parser.fields.count == 2)
        let hostView = try #require(parser.fields.firstIndex(of: .host).map { parser.fields.valueViews[$0] })
        #expect(hostView.string(in: buffer) == "b")
        buffer.moveReaderIndex(forwardBy: 3)   // the body, read by #0081

        #expect(parser.parseHead(&buffer) == .complete)
        #expect(parser.head.path.string(in: buffer) == "/three")
        #expect(parser.fields.count == 1)

        #expect(parser.parseHead(&buffer) == .needMoreBytes)
        buffer.append("TP/1.1\r\nHost: d\r\n\r\n")
        #expect(parser.parseHead(&buffer) == .complete)
        #expect(parser.head.path.string(in: buffer) == "/four")
        #expect(buffer.isEmpty)
    }

    @Test func parsesIntoRequestStorage() throws {
        let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 16)
        storage.buffer.append("GET /a?b=c HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n")
        var parser = HTTP1Parser()
        #expect(parser.parseHead(into: storage) == .complete)
        let request = parser.head.request(in: storage)
        #expect(request.method == .get)
        #expect(request.string(of: request.path) == "/a")
        #expect(request.string(of: request.query) == "b=c")
        #expect(request.headers.firstValueString(for: .host) == "example.com")
        #expect(request.headers.count == 2)
        storage.endRequest()
        #expect(!request.isValid)
    }

    /// Every corpus input gives the same outcome however it is split: at every single byte
    /// offset, and fed one byte per call.
    @Test func identicalWhenSplitAtEveryOffset() {
        for text in HTTP1Corpus.all + HTTP1Corpus.issue0006Fragments {
            let bytes = HTTP1Corpus.bytes(text)
            let expected = ParserDriver.oneShot(bytes)
            for split in 0...bytes.count {
                let outcome = ParserDriver.feed(bytes, chunks: [split]).last
                #expect(outcome == expected, "\(text.debugDescription) split at \(split)")
            }
            let byByte = ParserDriver.feed(bytes, chunks: Array(repeating: 1, count: bytes.count))
            #expect(byByte.last == expected, "\(text.debugDescription) one byte at a time")
        }
    }
}
