import HTTPCore
import HTTP1

/// HTTP/1.1 response serializer and date cache microbenchmarks (issue #0076). Select with
/// `sws-bench micro --filter serialize` or `--filter date`.
///
/// Responses are built once (as a handler holding pre-built responses would); each op clears
/// the connection's reused output buffer and serializes one response, including the clock read
/// and second compare of the date cache. Targets: < 100 ns and 0 allocations per response.
func registerSerializerBenchmarks() {
    let fixture = SerializerFixture()
    var i: Int64 = 0
    func register(_ name: String, _ body: @escaping (SerializerFixture) -> (Int64) -> Int) {
        let op = body(fixture)
        Benchmark.register(name: name) {
            blackHole(op(i))
            i &+= 1
        }
    }
    register("serialize.200 5-header 9-byte body", SerializerFixture.fiveHeaders)
    register("serialize.200 10-header 9-byte body", SerializerFixture.tenHeaders)
    register("serialize.200 5-header chunked head", SerializerFixture.chunkedHead)
    register("serialize.304 2-header", SerializerFixture.notModified)
    register("serialize.chunk 9-byte", SerializerFixture.chunk)
    register("date.clock_gettime", SerializerFixture.clockRead)
    register("date.refresh same second", SerializerFixture.refreshSameSecond)
    register("date.render", SerializerFixture.render)
}

private final class SerializerFixture {
    @exclusivity(unchecked) var serializer = HTTP1Serializer()
    @exclusivity(unchecked) var output = ByteBuffer(capacity: 1024)
    @exclusivity(unchecked) var dateCache = DateCache()
    let five: HTTPResponse
    let ten: HTTPResponse
    let chunked: HTTPResponse
    let notModifiedResponse: HTTPResponse
    let chunkBytes = ByteBuffer("<p>hi</p>")
    let context = HTTP1ResponseContext()

    init() {
        var headers = HTTPFields(minimumCapacity: 16, arenaCapacity: 512)
        headers.append(.contentType, "text/html; charset=utf-8")
        headers.append(.cacheControl, "no-cache")
        headers.append(.server, "sws")
        headers.append(.vary, "accept-encoding")
        headers.append(.etag, "\"5f3e-1a2b\"")
        five = HTTPResponse(headers: headers, body: .bytes(ByteBuffer("<p>hi</p>")))
        chunked = HTTPResponse(headers: headers, body: .stream(length: nil, writer: { _ in }))
        headers.append(.lastModified, "Sun, 06 Nov 1994 08:49:37 GMT")
        headers.append(.acceptRanges, "bytes")
        headers.append(.xContentTypeOptions, "nosniff")
        headers.append(.strictTransportSecurity, "max-age=63072000")
        headers.append(name: "X-Request-Id", value: "7f3a9c2e")
        ten = HTTPResponse(headers: headers, body: .bytes(ByteBuffer("<p>hi</p>")))
        var notModifiedHeaders = HTTPFields()
        notModifiedHeaders.append(.etag, "\"5f3e-1a2b\"")
        notModifiedHeaders.append(.cacheControl, "no-cache")
        notModifiedResponse = HTTPResponse(status: .notModified, headers: notModifiedHeaders)
    }

    func fiveHeaders(_ i: Int64) -> Int {
        output.clear()
        serializer.write(five, into: &output, context: context)
        return output.readableBytes
    }

    func tenHeaders(_ i: Int64) -> Int {
        output.clear()
        serializer.write(ten, into: &output, context: context)
        return output.readableBytes
    }

    func chunkedHead(_ i: Int64) -> Int {
        output.clear()
        serializer.write(chunked, into: &output, context: context)
        return output.readableBytes
    }

    func notModified(_ i: Int64) -> Int {
        output.clear()
        serializer.write(notModifiedResponse, into: &output, context: context)
        return output.readableBytes
    }

    func chunk(_ i: Int64) -> Int {
        output.clear()
        HTTP1ChunkedEncoder.appendChunk(chunkBytes, into: &output)
        return output.readableBytes
    }

    func clockRead(_ i: Int64) -> Int {
        Int(SystemWallClock().secondsSinceEpoch())
    }

    func refreshSameSecond(_ i: Int64) -> Int {
        dateCache.refresh() ? 1 : 0
    }

    func render(_ i: Int64) -> Int {
        output.clear()
        IMFFixdate.append(secondsSinceEpoch: 784_111_777 &+ i, to: &output)
        return output.readableBytes
    }
}
