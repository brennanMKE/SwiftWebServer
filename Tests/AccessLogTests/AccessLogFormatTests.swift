import AccessLog
import Foundation
import HTTPCore
import Testing

// #0090: line formats and escaping.

@Suite struct AccessLogFormatTests {
    static let clfDate = #"\[\d{2}/(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/\d{4}:\d{2}:\d{2}:\d{2} \+0000\]"#

    @Test func commonLogFormat() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination)
        let connection = openConnection(log)
        try await perform(TestRequest("/index.html?x=1&y=2"), through: log, on: connection)
        try await perform(TestRequest(.post, "/missing"), through: log, on: connection)
        try await perform(TestRequest(.head, "/index.html"), through: log, on: connection)
        log.connectionDidEnd(connection)
        try await drain(log)

        let lines = capture.lines
        #expect(lines.count == 3)
        #expect(lines[0].wholeMatch(of: try Regex(
            #"192\.0\.2\.7 - - "# + Self.clfDate + #" "GET /index\.html\?x=1&y=2 HTTP/1\.1" 200 14"#)) != nil, "\(lines[0])")
        #expect(lines[1].hasSuffix(#""POST /missing HTTP/1.1" 404 14"#), "\(lines[1])")
        // HEAD sends no body: Apache's `-`.
        #expect(lines[2].hasSuffix(#""HEAD /index.html HTTP/1.1" 200 -"#), "\(lines[2])")
        #expect(log.statistics.linesLogged == 3)
        #expect(log.statistics.linesWritten == 3)
        #expect(log.statistics.linesDropped == 0)
    }

    @Test func combinedLogFormat() async throws {
        let capture = Capture()
        let log = AccessLog(format: .combined, destination: capture.destination)
        let connection = openConnection(log, info: ConnectionInfo(
            remoteAddress: TransportAddress(host: "::1", port: 1), isSecure: true, negotiatedALPN: "h2"))
        try await perform(TestRequest("/a", headers: [("Referer", "https://example.com/"), ("User-Agent", "curl/8.7.1")]),
                       through: log, on: connection)
        try await perform(TestRequest("/b"), through: log, on: connection)
        log.connectionDidEnd(connection)
        try await drain(log)

        let lines = capture.lines
        #expect(lines.count == 2)
        #expect(lines[0].wholeMatch(of: try Regex(
            #"::1 - - "# + Self.clfDate + #" "GET /a HTTP/2\.0" 200 14 "https://example\.com/" "curl/8\.7\.1""#)) != nil,
                "\(lines[0])")
        #expect(lines[1].hasSuffix(#""GET /b HTTP/2.0" 200 14 "-" "-""#), "\(lines[1])")
    }

    @Test func jsonLines() async throws {
        let capture = Capture()
        let log = AccessLog(format: .json, destination: capture.destination)
        let connection = openConnection(log, info: ConnectionInfo(
            remoteAddress: TransportAddress(host: "10.0.0.1", port: 1), negotiatedALPN: "h3"))
        try await perform(TestRequest("/search?q=swift", headers: [("User-Agent", "test")]), through: log, on: connection)
        log.connectionDidEnd(connection)
        try await drain(log)

        let lines = capture.lines
        try #require(lines.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(object["remote"] as? String == "10.0.0.1")
        #expect(object["protocol"] as? String == "HTTP/3.0")
        #expect(object["method"] as? String == "GET")
        #expect(object["path"] as? String == "/search")
        #expect(object["query"] as? String == "q=swift")
        #expect(object["status"] as? Int == 200)
        #expect(object["bytes"] as? Int == 14)
        #expect((object["duration_us"] as? Int).map { $0 >= 0 } == true)
        #expect(object["referer"] is NSNull)
        #expect(object["user_agent"] as? String == "test")
        let time = try #require(object["time"] as? String)
        #expect(time.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/) != nil, "\(time)")
        // Fixed key order: a stable schema for line-oriented tools.
        #expect(lines[0].hasPrefix(#"{"time":""#))
    }

    /// Without a start time (no runner stamped it) the duration is unknown.
    @Test func jsonWithoutStartTimeHasNullDuration() async throws {
        let capture = Capture()
        let log = AccessLog(format: .json, destination: capture.destination)
        let connection = openConnection(log, startTime: false)
        try await perform(TestRequest("/"), through: log, on: connection)
        try await drain(log)
        #expect(capture.lines.first?.contains(#""duration_us":null"#) == true)
    }

    /// Control bytes, quotes, backslashes, DEL and invalid UTF-8 in the path and headers.
    static let hostilePath: [UInt8] = Array(#"/a"b\c"#.utf8) + [0x0A, 0x0D, 0x09, 0x01, 0x7F, 0xFF, 0xC3, 0xA9, 0xE2, 0x82]
        + Array(#"/" 200 0\n1.2.3.4 - - [forged]"#.utf8)

    @Test func jsonEscapesHostileBytes() async throws {
        let capture = Capture()
        let log = AccessLog(format: .json, destination: capture.destination)
        let connection = openConnection(log)
        try await perform(TestRequest(path: Self.hostilePath, headers: [("User-Agent", [0x22, 0x0A, 0x5C, 0x00])]),
                       through: log, on: connection)
        try await drain(log)

        let bytes = capture.bytes
        // One line: the only newline is the terminator, and no raw control byte survives.
        #expect(bytes.filter { $0 == 0x0A }.count == 1)
        #expect(bytes.last == 0x0A)
        #expect(!bytes.dropLast().contains { $0 < 0x20 || $0 == 0x7F })
        let line = try #require(capture.lines.first)
        #expect(line.contains(#""path":"/a\"b\\c\n\r\t\u0001\u007f\ufffdé\ufffd\ufffd/\" 200 0\\n1.2.3.4 - - [forged]""#), "\(line)")
        #expect(line.contains(#""user_agent":"\"\n\\\u0000""#), "\(line)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["path"] as? String == "/a\"b\\c\n\r\t\u{01}\u{7F}\u{FFFD}é\u{FFFD}\u{FFFD}/\" 200 0\\n1.2.3.4 - - [forged]")
        #expect(object["user_agent"] as? String == "\"\n\\\u{00}")
    }

    @Test func commonEscapesHostileBytes() async throws {
        let capture = Capture()
        let log = AccessLog(format: .combined, destination: capture.destination)
        let connection = openConnection(log)
        try await perform(TestRequest(path: Self.hostilePath, headers: [("User-Agent", [0x22, 0x0A, 0x5C])]),
                       through: log, on: connection)
        try await drain(log)

        let bytes = capture.bytes
        #expect(bytes.filter { $0 == 0x0A }.count == 1)
        #expect(!bytes.dropLast().contains { $0 < 0x20 || $0 >= 0x7F })
        let line = try #require(capture.lines.first)
        #expect(line.contains(#""GET /a\"b\\c\x0a\x0d\x09\x01\x7f\xff\xc3\xa9\xe2\x82/\" 200 0\\n1.2.3.4 - - [forged] HTTP/1.1" 200 14 "-" "\"\x0a\\""#),
                "\(line)")
    }

    @Test func dates() {
        func render(_ seconds: Int64, _ format: AccessLogFormat) -> String {
            var buffer = ByteBuffer()
            buffer.withWriter(reservingCapacity: 32) { AccessLogLineFormatter.writeDate(seconds, format: format, to: &$0) }
            return buffer.withReadableSpan { ASCII.string(from: $0) }
        }
        #expect(render(0, .common) == "01/Jan/1970:00:00:00 +0000")
        #expect(render(0, .json) == "1970-01-01T00:00:00Z")
        #expect(render(1_700_000_000, .common) == "14/Nov/2023:22:13:20 +0000")
        #expect(render(1_700_000_000, .json) == "2023-11-14T22:13:20Z")
        #expect(render(951_782_400, .json) == "2000-02-29T00:00:00Z")
        #expect(render(-5, .json) == "1970-01-01T00:00:00Z")
        #expect(AccessLogLineFormatter.dateLength(.common) == render(0, .common).utf8.count)
        #expect(AccessLogLineFormatter.dateLength(.json) == render(0, .json).utf8.count)
    }

    @Test func throwingHandlerIsLoggedAs500() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination)
        let connection = openConnection(log)
        await #expect(throws: Responder.Failure.self) {
            try await perform(TestRequest("/throw"), through: log, on: connection)
        }
        try await drain(log)
        #expect(capture.lines.first?.hasSuffix(#""GET /throw HTTP/1.1" 500 -"#) == true)
    }

    /// A request without per-connection state (a runner driven without observers) is logged
    /// through the shared buffer.
    @Test func requestWithoutConnectionStateIsLogged() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination)
        _ = try await log.handle(TestRequest("/x").request, context: RequestContext(), next: Responder())
        try await drain(log)
        #expect(capture.lines.count == 1)
        #expect(capture.lines.first?.hasPrefix("- - - [") == true)
    }

    @Test func otherMethodTokens() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination)
        let connection = openConnection(log)
        let method = try #require(HTTPMethod("PROPFIND"))
        try await perform(TestRequest(method, "/dav"), through: log, on: connection)
        try await drain(log)
        #expect(capture.lines.first?.contains(#""PROPFIND /dav HTTP/1.1""#) == true)
    }
}
