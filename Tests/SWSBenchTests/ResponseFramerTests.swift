@testable import SWSBench
import Testing

/// Feeds `bytes` to a framer in pieces of `chunkSize` and returns the final event
/// plus the bytes consumed in total.
private func frame(
    _ text: String, chunkSize: Int = .max, eof: Bool = false, head: Bool = false
) -> (event: ResponseFramer.Event, consumed: Int) {
    let bytes = Array(text.utf8)
    var framer = ResponseFramer(requestWasHead: head)
    var offset = 0
    var consumed = 0
    while offset < bytes.count {
        let end = min(bytes.count, offset + chunkSize)
        let (event, used) = bytes[offset..<end].withUnsafeBytes { framer.consume($0) }
        consumed += used
        if event != .needMore { return (event, consumed) }
        offset = end
    }
    if eof { return (framer.finish(), consumed) }
    return (.needMore, consumed)
}

private func response(_ status: Int, head: Int, body: Int, keepAlive: Bool) -> ResponseFramer.Event {
    .complete(ResponseFramer.Response(status: status, headBytes: head, bodyBytes: body, keepAlive: keepAlive))
}

@Suite struct ResponseFramerTests {
    static let legacyResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello"

    @Test func contentLengthFramesBodyAndKeepsAlive() {
        let result = frame(Self.legacyResponse)
        #expect(result.event == response(200, head: 63, body: 5, keepAlive: true))
        #expect(result.consumed == Self.legacyResponse.utf8.count)
    }

    @Test(arguments: [1, 2, 3, 5, 7, 64])
    func identicalResultAtEveryChunking(chunkSize: Int) {
        #expect(frame(Self.legacyResponse, chunkSize: chunkSize).event == response(200, head: 63, body: 5, keepAlive: true))
    }

    @Test func splitAtEveryByteOffset() {
        let bytes = Array(Self.legacyResponse.utf8)
        for split in 0...bytes.count {
            var framer = ResponseFramer()
            let first = bytes[0..<split].withUnsafeBytes { framer.consume($0) }
            var event = first.event
            if event == .needMore {
                event = bytes[split...].withUnsafeBytes { framer.consume($0) }.event
            }
            #expect(event == response(200, head: 63, body: 5, keepAlive: true), "split at \(split)")
        }
    }

    @Test func leavesPipelinedBytesUnconsumed() {
        let two = Self.legacyResponse + "HTTP/1.1 204 No Content\r\n\r\n"
        let result = frame(two)
        #expect(result.consumed == Self.legacyResponse.utf8.count)
    }

    @Test func resetFramesTheNextResponse() {
        var framer = ResponseFramer()
        let bytes = Array((Self.legacyResponse + "HTTP/1.1 204 No Content\r\n\r\n").utf8)
        let first = bytes.withUnsafeBytes { framer.consume($0) }
        framer.reset()
        let second = bytes[first.consumed...].withUnsafeBytes { framer.consume($0) }
        #expect(second.event == response(204, head: 27, body: 0, keepAlive: true))
    }

    @Test func connectionCloseAndHTTP10() {
        let close = "HTTP/1.1 200 OK\r\nConnection: Close\r\nContent-Length: 0\r\n\r\n"
        #expect(frame(close).event == response(200, head: close.utf8.count, body: 0, keepAlive: false))
        let old = "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n"
        #expect(frame(old).event == response(200, head: old.utf8.count, body: 0, keepAlive: false))
        let oldKeep = "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n"
        #expect(frame(oldKeep).event == response(200, head: oldKeep.utf8.count, body: 0, keepAlive: true))
    }

    @Test func headerNamesAreCaseInsensitiveAndValuesTrimmed() {
        let text = "HTTP/1.1 200 OK\r\ncontent-LENGTH:   3  \r\n\r\nabc"
        #expect(frame(text).event == response(200, head: text.utf8.count - 3, body: 3, keepAlive: true))
    }

    @Test func noBodyStatusesAndHead() {
        let notModified = "HTTP/1.1 304 Not Modified\r\nContent-Length: 100\r\n\r\n"
        #expect(frame(notModified).event == response(304, head: notModified.utf8.count, body: 0, keepAlive: true))
        let head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
        #expect(frame(head, head: true).event == response(200, head: head.utf8.count, body: 0, keepAlive: true))
    }

    @Test func skipsInterimContinue() {
        let interim = "HTTP/1.1 100 Continue\r\n\r\n"
        let final = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        let result = frame(interim + final, chunkSize: 4)
        #expect(result.event == response(200, head: interim.utf8.count + final.utf8.count - 2, body: 2, keepAlive: true))
    }

    @Test func chunkedBodyWithExtensionsAndTrailers() {
        let body = "5;name=value\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\n\r\n"
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n" + body
        for chunkSize in [1, 3, 1000] {
            let result = frame(text, chunkSize: chunkSize)
            #expect(result.event == response(200, head: text.utf8.count - body.utf8.count, body: body.utf8.count, keepAlive: true))
            #expect(result.consumed == text.utf8.count)
        }
    }

    @Test func chunkedWinsOverContentLength() {
        let body = "1\r\nx\r\n0\r\n\r\n"
        let text = "HTTP/1.1 200 OK\r\nContent-Length: 999\r\nTransfer-Encoding: chunked\r\n\r\n" + body
        #expect(frame(text).event == response(200, head: text.utf8.count - body.utf8.count, body: body.utf8.count, keepAlive: true))
    }

    @Test func closeDelimitedBodyCompletesAtEOF() {
        let text = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nuntil close"
        #expect(frame(text).event == .needMore)
        #expect(frame(text, eof: true).event == response(200, head: text.utf8.count - 11, body: 11, keepAlive: false))
    }

    @Test func eofBeforeAnyByteVersusMidResponse() {
        var framer = ResponseFramer()
        #expect(framer.finish() == .invalid(.closedBeforeResponse))
        #expect(frame("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc", eof: true).event == .invalid(.unexpectedEOF))
        #expect(frame("HTTP/1.1 200 O", eof: true).event == .invalid(.unexpectedEOF))
    }

    @Test(arguments: [
        "HTTP/2 200 OK\r\n\r\n",
        "HTTP/1.1 2x0 OK\r\n\r\n",
        "HTTP/1.1 099 Low\r\n\r\n",
        "HTTP/1.1 200OK\r\n\r\n",
        "ICY 200 OK\r\n\r\n",
    ])
    func malformedStatusLines(text: String) {
        #expect(frame(text).event == .invalid(.malformedStatusLine))
    }

    @Test func malformedHeadersAndLengths() {
        #expect(frame("HTTP/1.1 200 OK\r\nNoColon\r\n\r\n").event == .invalid(.malformedHeader))
        #expect(frame("HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n").event == .invalid(.malformedHeader))
        #expect(frame("HTTP/1.1 200 OK\r\nContent-Length: 1x\r\n\r\n").event == .invalid(.badContentLength))
        #expect(frame("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n").event == .invalid(.badContentLength))
        #expect(frame("HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999999\r\n\r\n").event == .invalid(.badContentLength))
    }

    @Test func malformedChunks() {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(frame(head + "zz\r\n").event == .invalid(.badChunk))
        #expect(frame(head + "\r\n").event == .invalid(.badChunk))
        #expect(frame(head + "1\r\nxy\r\n").event == .invalid(.badChunk)) // data longer than size
        #expect(frame(head + "fffffffffffffffffff\r\n").event == .invalid(.badChunk))
    }

    @Test func headLargerThanLimitFails() {
        var framer = ResponseFramer(maxHeadBytes: 32)
        let bytes = Array("HTTP/1.1 200 OK\r\nX-Long: \(String(repeating: "a", count: 64))\r\n\r\n".utf8)
        let result = bytes.withUnsafeBytes { framer.consume($0) }
        #expect(result.event == .invalid(.headTooLarge))
    }

    @Test func parseHeadReadsFields() throws {
        let bytes = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 12\r\nConnection: keep-alive, Upgrade\r\n\r\n".utf8)
        let head = try ResponseFramer.parseHead(bytes).get()
        #expect(head == ResponseFramer.Head(minorVersion: 1, status: 404, contentLength: 12, chunked: false,
                                            connectionClose: false, connectionKeepAlive: true))
    }
}
