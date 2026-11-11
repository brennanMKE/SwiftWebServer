/// Incremental HTTP/1.1 response framer for the load client.
///
/// It parses just enough of the response head to know where the response ends
/// (RFC 9112 §6.3): no body for 1xx/204/304 (and HEAD), `Transfer-Encoding: chunked`,
/// then `Content-Length`, otherwise the body runs until the server closes.
/// Body bytes are counted, not stored, so large responses cost no memory.
///
/// Usage: feed received bytes to `consume(_:)` until it returns `.complete` or
/// `.invalid`; on end of stream call `finish()`. Call `reset()` before the next
/// response on a kept-alive connection. Interim 1xx responses (other than 101)
/// are skipped.
struct ResponseFramer {
    struct Head: Equatable, Sendable {
        var minorVersion: Int
        var status: Int
        var contentLength: Int?
        var chunked: Bool
        var connectionClose: Bool
        var connectionKeepAlive: Bool
    }

    struct Response: Equatable, Sendable {
        var status: Int
        var headBytes: Int
        var bodyBytes: Int
        /// True when the connection may carry another request.
        var keepAlive: Bool
    }

    enum Failure: Error, Equatable, Sendable {
        case headTooLarge
        case malformedStatusLine
        case malformedHeader
        case badContentLength
        case badChunk
        /// The stream ended before any byte of a response arrived.
        case closedBeforeResponse
        /// The stream ended in the middle of a response.
        case unexpectedEOF
        /// Bytes arrived after a complete response that nothing asked for.
        case unsolicitedBytes
    }

    enum Event: Equatable, Sendable {
        case needMore
        case complete(Response)
        case invalid(Failure)
    }

    private enum State: Equatable {
        case head
        case body(remaining: Int)
        case chunkSize(value: Int, digits: Int, inExtension: Bool, sawCR: Bool)
        case chunkData(remaining: Int)
        case chunkDataCR
        case chunkDataLF
        case trailer(lineLength: Int, sawCR: Bool)
        case untilClose
        case done
        case failed(Failure)
    }

    let maxHeadBytes: Int
    /// Set when the request was HEAD: the response never has a body.
    var requestWasHead: Bool

    private var state: State = .head
    private var headBuffer: [UInt8] = []
    /// Progress through the `\r\n\r\n` terminator (0...4).
    private var terminatorMatch = 0
    private var head: Head?
    private var headBytes = 0
    private var bodyBytes = 0
    private var receivedAny = false

    init(maxHeadBytes: Int = 64 * 1024, requestWasHead: Bool = false) {
        self.maxHeadBytes = maxHeadBytes
        self.requestWasHead = requestWasHead
        headBuffer.reserveCapacity(1024)
    }

    /// Prepares for the next response, keeping buffer capacity.
    mutating func reset() {
        state = .head
        headBuffer.removeAll(keepingCapacity: true)
        terminatorMatch = 0
        head = nil
        headBytes = 0
        bodyBytes = 0
        receivedAny = false
    }

    /// Consumes bytes. `consumed` is how many bytes belong to this response;
    /// anything after it (a pipelined response) is left to the caller.
    mutating func consume(_ bytes: UnsafeRawBufferPointer) -> (event: Event, consumed: Int) {
        if !bytes.isEmpty { receivedAny = true }
        var index = 0
        let count = bytes.count
        while true {
            switch state {
            case .failed(let failure):
                return (.invalid(failure), index)
            case .done:
                return (.complete(makeResponse()), index)
            default:
                break
            }
            guard index < count else { return (.needMore, index) }

            switch state {
            case .head:
                while index < count {
                    let byte = bytes[index]
                    index += 1
                    headBuffer.append(byte)
                    switch (terminatorMatch, byte) {
                    case (0, .cr), (2, .cr): terminatorMatch += 1
                    case (1, .lf), (3, .lf): terminatorMatch += 1
                    case (_, .cr): terminatorMatch = 1
                    default: terminatorMatch = 0
                    }
                    if terminatorMatch == 4 { break }
                    if headBuffer.count >= maxHeadBytes {
                        state = .failed(.headTooLarge)
                        break
                    }
                }
                if terminatorMatch == 4 {
                    headComplete()
                }

            case .body(let remaining):
                let take = Swift.min(remaining, count - index)
                index += take
                bodyBytes += take
                state = remaining == take ? .done : .body(remaining: remaining - take)

            case .chunkData(let remaining):
                let take = Swift.min(remaining, count - index)
                index += take
                bodyBytes += take
                state = remaining == take ? .chunkDataCR : .chunkData(remaining: remaining - take)

            case .untilClose:
                bodyBytes += count - index
                index = count

            case .chunkSize, .chunkDataCR, .chunkDataLF, .trailer:
                let byte = bytes[index]
                index += 1
                chunkByte(byte)

            case .done, .failed:
                break
            }
        }
    }

    /// Signals end of stream.
    mutating func finish() -> Event {
        switch state {
        case .untilClose, .done:
            state = .done
            return .complete(makeResponse())
        case .failed(let failure):
            return .invalid(failure)
        case .head where !receivedAny:
            state = .failed(.closedBeforeResponse)
            return .invalid(.closedBeforeResponse)
        default:
            state = .failed(.unexpectedEOF)
            return .invalid(.unexpectedEOF)
        }
    }

    // MARK: - Private

    private func makeResponse() -> Response {
        let head = self.head
        var keepAlive = false
        if let head {
            keepAlive = head.minorVersion >= 1 ? !head.connectionClose : head.connectionKeepAlive
            if case .done = state, head.contentLength == nil, !head.chunked, hasBody(head) {
                keepAlive = false // close-delimited
            }
        }
        return Response(status: head?.status ?? 0, headBytes: headBytes, bodyBytes: bodyBytes, keepAlive: keepAlive)
    }

    private func hasBody(_ head: Head) -> Bool {
        !(requestWasHead || (100..<200).contains(head.status) || head.status == 204 || head.status == 304)
    }

    private mutating func headComplete() {
        let parsed = ResponseFramer.parseHead(headBuffer)
        switch parsed {
        case .failure(let failure):
            state = .failed(failure)
        case .success(let parsedHead):
            headBytes += headBuffer.count
            headBuffer.removeAll(keepingCapacity: true)
            terminatorMatch = 0
            if (100..<200).contains(parsedHead.status) && parsedHead.status != 101 {
                state = .head // interim response; wait for the final one
                return
            }
            head = parsedHead
            if !hasBody(parsedHead) {
                state = .done
            } else if parsedHead.chunked {
                state = .chunkSize(value: 0, digits: 0, inExtension: false, sawCR: false)
            } else if let length = parsedHead.contentLength {
                state = length == 0 ? .done : .body(remaining: length)
            } else {
                state = .untilClose
            }
        }
    }

    private mutating func chunkByte(_ byte: UInt8) {
        bodyBytes += 1
        switch state {
        case .chunkSize(let value, let digits, let inExtension, let sawCR):
            if sawCR {
                guard byte == .lf, digits > 0 else { state = .failed(.badChunk); return }
                state = value == 0 ? .trailer(lineLength: 0, sawCR: false) : .chunkData(remaining: value)
            } else if byte == .cr {
                state = .chunkSize(value: value, digits: digits, inExtension: inExtension, sawCR: true)
            } else if inExtension {
                break
            } else if let digit = hexValue(byte) {
                guard value <= (Int.max - 15) / 16 else { state = .failed(.badChunk); return }
                state = .chunkSize(value: value * 16 + digit, digits: digits + 1, inExtension: false, sawCR: false)
            } else if byte == UInt8(ascii: ";") || byte == .space || byte == .tab {
                guard digits > 0 else { state = .failed(.badChunk); return }
                state = .chunkSize(value: value, digits: digits, inExtension: true, sawCR: false)
            } else {
                state = .failed(.badChunk)
            }
        case .chunkDataCR:
            state = byte == .cr ? .chunkDataLF : .failed(.badChunk)
        case .chunkDataLF:
            state = byte == .lf ? .chunkSize(value: 0, digits: 0, inExtension: false, sawCR: false) : .failed(.badChunk)
        case .trailer(let lineLength, let sawCR):
            if sawCR {
                guard byte == .lf else { state = .failed(.badChunk); return }
                state = lineLength == 0 ? .done : .trailer(lineLength: 0, sawCR: false)
            } else if byte == .cr {
                state = .trailer(lineLength: lineLength, sawCR: true)
            } else {
                state = .trailer(lineLength: lineLength + 1, sawCR: false)
            }
        default:
            state = .failed(.badChunk)
        }
    }

    private func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    // MARK: - Head parsing

    /// Parses a complete response head (status line, header lines, and the
    /// terminating empty line).
    static func parseHead(_ bytes: [UInt8]) -> Result<Head, Failure> {
        // Status line: HTTP/1.x SP 3DIGIT [SP reason] CRLF
        let prefix: [UInt8] = Array("HTTP/1.".utf8)
        guard bytes.count >= 12, Array(bytes[0..<7]) == prefix else { return .failure(.malformedStatusLine) }
        guard let minor = digitValue(bytes[7]), bytes[8] == .space else { return .failure(.malformedStatusLine) }
        guard let d0 = digitValue(bytes[9]), let d1 = digitValue(bytes[10]), let d2 = digitValue(bytes[11]) else {
            return .failure(.malformedStatusLine)
        }
        let status = d0 * 100 + d1 * 10 + d2
        guard status >= 100 else { return .failure(.malformedStatusLine) }

        var head = Head(minorVersion: minor, status: status, contentLength: nil, chunked: false,
                        connectionClose: false, connectionKeepAlive: false)

        guard var lineStart = nextLine(in: bytes, from: 12) else { return .failure(.malformedStatusLine) }
        if bytes[12] != .space && bytes[12] != .cr { return .failure(.malformedStatusLine) }

        while lineStart < bytes.count {
            guard let lineEnd = lineEnd(in: bytes, from: lineStart) else { return .failure(.malformedHeader) }
            if lineEnd == lineStart { break } // empty line: end of head
            guard let colon = bytes[lineStart..<lineEnd].firstIndex(of: UInt8(ascii: ":")), colon > lineStart else {
                return .failure(.malformedHeader)
            }
            let name = bytes[lineStart..<colon]
            if name.contains(where: { $0 == .space || $0 == .tab }) { return .failure(.malformedHeader) }
            var valueStart = colon + 1
            var valueEnd = lineEnd
            while valueStart < valueEnd, bytes[valueStart] == .space || bytes[valueStart] == .tab { valueStart += 1 }
            while valueEnd > valueStart, bytes[valueEnd - 1] == .space || bytes[valueEnd - 1] == .tab { valueEnd -= 1 }
            let value = bytes[valueStart..<valueEnd]

            if equalsIgnoringCase(name, "content-length") {
                guard let length = parseContentLength(value) else { return .failure(.badContentLength) }
                if let existing = head.contentLength, existing != length { return .failure(.badContentLength) }
                head.contentLength = length
            } else if equalsIgnoringCase(name, "transfer-encoding") {
                // Chunked only counts as the final coding.
                let codings = tokens(value)
                head.chunked = codings.last.map { equalsIgnoringCase($0, "chunked") } ?? false
            } else if equalsIgnoringCase(name, "connection") {
                for token in tokens(value) {
                    if equalsIgnoringCase(token, "close") { head.connectionClose = true }
                    if equalsIgnoringCase(token, "keep-alive") { head.connectionKeepAlive = true }
                }
            }
            lineStart = lineEnd + 2
        }
        return .success(head)
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? Int(byte - UInt8(ascii: "0")) : nil
    }

    /// Index of the CR of the CRLF that ends the line starting at `start`.
    private static func lineEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == .cr && bytes[index + 1] == .lf { return index }
            index += 1
        }
        return nil
    }

    private static func nextLine(in bytes: [UInt8], from start: Int) -> Int? {
        lineEnd(in: bytes, from: start).map { $0 + 2 }
    }

    private static func parseContentLength(_ value: ArraySlice<UInt8>) -> Int? {
        guard !value.isEmpty else { return nil }
        var result = 0
        for byte in value {
            guard let digit = digitValue(byte) else { return nil }
            let (times, overflow1) = result.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times.addingReportingOverflow(digit)
            guard !overflow1, !overflow2 else { return nil }
            result = sum
        }
        return result
    }

    /// Comma-separated tokens with surrounding whitespace trimmed; empty ones dropped.
    private static func tokens(_ value: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        value.split(separator: UInt8(ascii: ",")).compactMap { token in
            var start = token.startIndex
            var end = token.endIndex
            while start < end, token[start] == .space || token[start] == .tab { start += 1 }
            while end > start, token[end - 1] == .space || token[end - 1] == .tab { end -= 1 }
            return start < end ? token[start..<end] : nil
        }
    }

    private static func equalsIgnoringCase(_ bytes: ArraySlice<UInt8>, _ lowercase: StaticString) -> Bool {
        guard bytes.count == lowercase.utf8CodeUnitCount else { return false }
        return lowercase.withUTF8Buffer { expected in
            var index = 0
            for byte in bytes {
                let lowered = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
                if lowered != expected[index] { return false }
                index += 1
            }
            return true
        }
    }
}

extension UInt8 {
    static let cr = UInt8(ascii: "\r")
    static let lf = UInt8(ascii: "\n")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
}
