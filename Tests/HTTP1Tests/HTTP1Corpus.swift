import HTTPCore
import HTTP1
import HTTPTestSupport

/// Request heads for the parser tests: valid ones, invalid ones, and the legacy bug repros.
enum HTTP1Corpus {
    /// A typical browser request with 10 fields (the benchmark request).
    static let browser = """
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

    static let valid: [String] = [
        browser,
        "GET / HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.0\r\n\r\n",
        "HEAD /x HTTP/1.0\r\nHost: a\r\n\r\n",
        "\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\n",
        "POST /submit HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello",
        "POST /submit HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n",
        "POST /up HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        "POST /up HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: CHUNKED\r\n\r\n",
        "POST /up HTTP/1.1\r\nHost: a\r\nContent-Length: 7\r\nContent-Length: 7\r\n\r\n",
        "POST /up HTTP/1.1\r\nHost: a\r\nContent-Length: 7, 7\r\n\r\n",
        "GET /a%20b?q=%41 HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET /a?b?c HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET /? HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET http://example.com/path?q=1 HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET http://example.com HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET https://example.com:8443?x HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET coap+tcp://h/p HTTP/1.1\r\nHost: h\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
        "CONNECT [::1]:8080 HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n",
        "OPTIONS * HTTP/1.1\r\nHost: a\r\n\r\n",
        "OPTIONS /x HTTP/1.1\r\nHost: a\r\n\r\n",
        "PROPFIND /dav HTTP/1.1\r\nHost: a\r\nDepth: 1\r\n\r\n",
        "get / HTTP/1.1\r\nHost: a\r\n\r\n",
        "ABCDEFGHIJKLMNOPQRSTUVWX / HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Empty:\r\nX-Spaces: \t  \r\n\r\n",
        "GET / HTTP/1.1\r\nHost:a\r\nX-Trim: \t value with  inner  spaces \t\r\n\r\n",
        "GET / HTTP/1.1\r\nHOST: a\r\ncontent-TYPE: text/plain\r\nx-custom-header: 1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Obs-Text: caf\u{E9}\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Quote: \"a, b\"\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n!#$%&'*+-.^_`|~: tchars\r\n\r\n",
        "DELETE /item/1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer x.y.z\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n\r\nGET /second HTTP/1.1\r\nHost: b\r\n\r\n",
    ]

    static let invalid: [String] = [
        // Request line
        " GET / HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET  / HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1 \r\nHost: a\r\n\r\n",
        "GET /\r\nHost: a\r\n\r\n",
        "GET / \r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\rHost: a\r\n\r\n",
        "\n\nGET / HTTP/1.1\r\nHost: a\r\n\r\n",
        "\rGET / HTTP/1.1\r\nHost: a\r\n\r\n",
        "G(T / HTTP/1.1\r\nHost: a\r\n\r\n",
        "ABCDEFGHIJKLMNOPQRSTUVWXY / HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET /a\u{7F} HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET /caf\u{E9} HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET /a\tb HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/2.0\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.2\r\nHost: a\r\n\r\n",
        "GET / HTTP/0.9\r\nHost: a\r\n\r\n",
        "GET / http/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.10\r\nHost: a\r\n\r\n",
        "GET / HTTP/1\r\nHost: a\r\n\r\n",
        "GET / HTTP/x.1\r\nHost: a\r\n\r\n",
        // Request target forms
        "GET * HTTP/1.1\r\nHost: a\r\n\r\n",
        "OPTIONS ** HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT / HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT example.com HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT example.com:443/x HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT :443 HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT a:123456 HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT a:44x HTTP/1.1\r\nHost: a\r\n\r\n",
        "CONNECT user@a:443 HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET example.com:443 HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET http:/x HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET http:// HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET http:///path HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET http://user@host/ HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET 1http://h/ HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET ht_tp://h/ HTTP/1.1\r\nHost: a\r\n\r\n",
        // Field lines
        "GET / HTTP/1.1\r\nHost : a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost\t: a\r\n\r\n",
        "GET / HTTP/1.1\r\n: a\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost a\r\n\r\n",
        "GET / HTTP/1.1\r\nHo(st: a\r\n\r\n",
        "GET / HTTP/1.1\r\n Host: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Fold: one\r\n two\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX-Fold: one\r\n\ttwo\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\nX: b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\rX: b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\u{0}b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX: a\u{7F}\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nX: \u{1}\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n\n",
        "GET / HTTP/1.1\r\nHost: a\r\n\rX",
        // Host
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "GET / HTTP/1.0\r\nHost: a\r\nhost: a\r\n\r\n",
        // Framing
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5, 6\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +5\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5x\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length:\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999999999999999\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked, gzip\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked, chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding:\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: \"x,chunked\r\n\r\n",
        "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n",
    ]

    /// Legacy #0006: the request line alone is not a complete request.
    static let issue0006Fragments: [String] = [
        "GET /index.html HTTP/1.1\r\n",
        "GET /index.html HTTP/1.1\r\nHost: localhost\r\n",
        "GET /index.html HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: \"etag\"\r\n",
        "GE",
        "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r",
    ]

    static var all: [String] { valid + invalid }

    static func bytes(_ text: String) -> [UInt8] {
        // Characters up to U+00FF stand for single bytes (Latin-1), so tests can write obs-text.
        text.unicodeScalars.map { scalar in
            precondition(scalar.value <= 0xFF, "corpus text must be Latin-1")
            return UInt8(scalar.value)
        }
    }
}

/// Drives `HTTP1Parser` over byte arrays.
enum ParserDriver {
    /// Parses `bytes` fed in chunks of the given sizes (the remainder goes in a last chunk),
    /// and returns the outcome after each call.
    static func feed(_ bytes: [UInt8], chunks: [Int], limits: HTTP1ParserLimits = HTTP1ParserLimits()) -> [HTTP1HeadOutcome] {
        var parser = HTTP1Parser(limits: limits)
        var buffer = ByteBuffer()
        var outcomes: [HTTP1HeadOutcome] = []
        var offset = 0
        var sizes = chunks
        if sizes.reduce(0, +) < bytes.count { sizes.append(bytes.count - sizes.reduce(0, +)) }
        for size in sizes where offset < bytes.count || outcomes.isEmpty {
            let next = min(bytes.count, offset + size)
            buffer.append(contentsOf: bytes[offset..<next])
            offset = next
            let result = parser.parseHead(&buffer)
            outcomes.append(HTTP1HeadOutcome(result, parser: parser, buffer: buffer))
            if case .needMoreBytes = result { continue }
            break
        }
        return outcomes
    }

    /// The outcome of parsing all of `bytes` in one call.
    static func oneShot(_ bytes: [UInt8], limits: HTTP1ParserLimits = HTTP1ParserLimits()) -> HTTP1HeadOutcome {
        var parser = HTTP1Parser(limits: limits)
        var buffer = ByteBuffer(bytes: bytes)
        let result = parser.parseHead(&buffer)
        return HTTP1HeadOutcome(result, parser: parser, buffer: buffer)
    }
}
