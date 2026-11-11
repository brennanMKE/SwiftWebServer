import HTTPCore
import HTTP1

/// HTTP1Parser microbenchmarks (issue #0075). Select with `sws-bench micro --filter parse`.
///
/// Each op parses one head from a buffer that already holds it, then rewinds the reader
/// index, so the steady state is the hot path: one pass over the bytes, fields refilled in
/// a warmed-up index. Target (docs/ROADMAP.md §7): < 150 ns and 0 allocations for the
/// 10-header browser request.
func registerParserBenchmarks() {
    let fixture = ParserFixture()
    Benchmark.register(name: "parse.head 10-header browser request") {
        blackHole(fixture.parseBrowser())
    }
    Benchmark.register(name: "parse.head minimal request") {
        blackHole(fixture.parseMinimal())
    }
    Benchmark.register(name: "parse.head into HTTPRequestStorage") {
        blackHole(fixture.parseIntoStorage())
    }
}

private final class ParserFixture {
    static let browser: StaticString = """
        GET /index.html?lang=en HTTP/1.1\r
        Host: example.com\r
        User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r
        Accept: text/html,application/xhtml+xml\r
        Accept-Language: en-US,en;q=0.9\r
        Accept-Encoding: gzip, deflate, br\r
        Connection: keep-alive\r
        Cookie: session=abc123\r
        Cache-Control: max-age=0\r
        Upgrade-Insecure-Requests: 1\r
        X-Request-ID: 42\r
        \r

        """

    @exclusivity(unchecked) var parser = HTTP1Parser()
    @exclusivity(unchecked) var browser = ByteBuffer(ParserFixture.browser)
    @exclusivity(unchecked) var minimal = ByteBuffer("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
    let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 32)

    init() {
        storage.buffer.append(Self.browser)
        precondition(parseBrowser() == 10 && parseMinimal() == 1 && parseIntoStorage() == 10,
                     "benchmark heads must parse")
    }

    func parseBrowser() -> Int {
        browser.moveReaderIndex(to: 0)
        guard case .complete = parser.parseHead(&browser) else { return -1 }
        return parser.fields.count
    }

    func parseMinimal() -> Int {
        minimal.moveReaderIndex(to: 0)
        guard case .complete = parser.parseHead(&minimal) else { return -1 }
        return parser.fields.count
    }

    func parseIntoStorage() -> Int {
        storage.endRequest()
        storage.buffer.moveReaderIndex(to: 0)
        guard case .complete = parser.parseHead(into: storage) else { return -1 }
        return storage.fields.count
    }
}
