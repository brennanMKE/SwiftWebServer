import HTTPCore

/// HTTPFields / HTTPFieldName microbenchmarks (issue #0074). Select with
/// `sws-bench micro --filter fields`.
///
/// Each benchmark reuses one `HTTPRequestStorage` the way a connection does, so the steady
/// state is the hot path; the harness reports ns/op and allocations/op (target: 0).
func registerFieldsBenchmarks() {
    let fixture = FieldsFixture()
    var i = 0
    func register(_ name: String, _ body: @escaping (FieldsFixture) -> (Int) -> UInt64) {
        let op = body(fixture)
        Benchmark.register(name: name) {
            blackHole(op(i))
            i &+= 1
        }
    }
    register("fields.fill+clear 10-header request", FieldsFixture.fillAndClear)
    register("fields.scan+hash+fill 10-header request", FieldsFixture.scanAndFill)
    register("fields.lookupWellKnown", FieldsFixture.lookupWellKnown)
    register("fields.lookupUnknown", FieldsFixture.lookupUnknown)
    register("fields.firstValue(host)", FieldsFixture.firstValueHost)
    register("fields.containsMiss", FieldsFixture.containsMiss)
    register("fields.contentLength", FieldsFixture.contentLength)
    register("fields.methodParseGET", FieldsFixture.parseMethod)
    register("fields.statusLine200", FieldsFixture.statusLine)
    register("fields.response 5 static + removeAll", FieldsFixture.responseFields)
}

/// A typical browser request head plus reusable storage.
private final class FieldsFixture {
    static let head: StaticString = """
        Host: example.com\r
        User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r
        Accept: text/html,application/xhtml+xml\r
        Accept-Language: en-US,en;q=0.9\r
        Accept-Encoding: gzip, deflate, br\r
        Connection: keep-alive\r
        Cookie: session=abc123\r
        Cache-Control: max-age=0\r
        Upgrade-Insecure-Requests: 1\r
        Content-Length: 0\r
        \r

        """

    let storage = HTTPRequestStorage(bufferCapacity: 4096, fieldCapacity: 32)
    var scanned: [(name: ByteView, hash: UInt32, value: ByteView)] = []
    @exclusivity(unchecked) var response = HTTPFields(minimumCapacity: 16, arenaCapacity: 512)
    @exclusivity(unchecked) var output = ByteBuffer(capacity: 256)
    let hostName: [UInt8] = Array("Host".utf8)
    let hostHash = ASCII.fnv1aLowercased("Host")
    let unknownName: [UInt8] = Array("X-Custom-Header".utf8)
    let unknownHash = ASCII.fnv1aLowercased("X-Custom-Header")
    let method: [UInt8] = Array("GET".utf8)

    init() {
        storage.buffer.append(Self.head)
        scan()
        scanned = (0..<storage.fields.count).map { i in
            let name = storage.fields.nameViews[i]
            return (name, storage.buffer.withSpan(of: name) { ASCII.fnv1aLowercased($0) }, storage.fields.valueViews[i])
        }
    }

    /// Scans field lines, hashing each name in the same pass that finds `:` (what #0075 does).
    func scan() {
        storage.endRequest()
        let end = storage.buffer.writerIndex
        storage.buffer.withReadableSpan { bytes in
            var i = 0
            while i + 1 < end, bytes[i] != 0x0D {
                let nameStart = i
                var hasher = ASCII.FNV1a()
                while bytes[i] != UInt8(ascii: ":") {
                    hasher.combineLowercased(bytes[i])
                    i &+= 1
                }
                let nameEnd = i
                i &+= 1
                while bytes[i] == 0x20 { i &+= 1 }
                let valueStart = i
                while bytes[i] != 0x0D { i &+= 1 }
                storage.fields.append(
                    nameView: ByteView(offset: nameStart, length: nameEnd &- nameStart),
                    hash: hasher.value,
                    valueView: ByteView(offset: valueStart, length: i &- valueStart),
                    in: storage.buffer)
                i &+= 2
            }
        }
    }

    func fillAndClear(_ i: Int) -> UInt64 {
        storage.endRequest()
        for field in scanned {
            storage.appendField(nameView: field.name, hash: field.hash, valueView: field.value)
        }
        return UInt64(storage.fields.count)
    }

    func scanAndFill(_ i: Int) -> UInt64 {
        scan()
        return UInt64(storage.fields.count)
    }

    func lookupWellKnown(_ i: Int) -> UInt64 {
        UInt64(hostName.withUnsafeBufferPointer { HTTPFieldName.lookup(hash: hostHash &+ UInt32(i & 0), name: $0.span) }.rawValue)
    }

    func lookupUnknown(_ i: Int) -> UInt64 {
        UInt64(unknownName.withUnsafeBufferPointer { HTTPFieldName.lookup(hash: unknownHash &+ UInt32(i & 0), name: $0.span) }.rawValue)
    }

    func firstValueHost(_ i: Int) -> UInt64 {
        UInt64(storage.fieldsView.firstValue(for: .host)?.length ?? 0)
    }

    func containsMiss(_ i: Int) -> UInt64 {
        storage.fieldsView.contains(.transferEncoding) ? 1 : 0
    }

    func contentLength(_ i: Int) -> UInt64 {
        if case .value(let n) = storage.fieldsView.contentLength() { return n &+ 1 }
        return 0
    }

    func parseMethod(_ i: Int) -> UInt64 {
        method.withUnsafeBufferPointer { HTTPMethod($0.span) } == .get ? 1 : 0
    }

    func statusLine(_ i: Int) -> UInt64 {
        output.clear()
        HTTPStatus.ok.appendHTTP1StatusLine(to: &output)
        return UInt64(output.readableBytes)
    }

    func responseFields(_ i: Int) -> UInt64 {
        response.removeAll()
        response.append(.contentType, "text/html; charset=utf-8")
        response.append(.contentLength, decimal: i & 0xFFFF)
        response.append(.cacheControl, "no-cache")
        response.append(.server, "sws")
        response.append(.vary, "accept-encoding")
        return UInt64(response.count)
    }
}
