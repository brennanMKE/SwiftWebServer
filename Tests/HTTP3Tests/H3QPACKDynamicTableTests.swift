import HTTP3
import HTTPCore
import HTTPTestSupport
import Testing

/// #0106: requests whose field sections reference the QPACK dynamic table, over the in-memory
/// multiplexed transport.
@Suite(.timeLimit(.minutes(1)))
struct H3QPACKDynamicTableTests {
    static let configuration = H3Configuration(qpackMaxTableCapacity: 220, qpackBlockedStreams: 2)

    /// RFC 9204 Appendix B.2's encoder stream: capacity 220, then `:authority www.example.com`
    /// (absolute 0) and `:path /sample/path` (absolute 1).
    static let encoderStream: [UInt8] = [0x02] + hexBytes(
        "3fbd01 c00f7777772e6578616d706c652e636f6d c10c2f73616d706c652f70617468")

    /// HEADERS for a GET whose `:authority` and `:path` are post-Base references to absolute
    /// 0 and 1 (Required Insert Count 2, Base 0): `:method GET` (static 17), `:scheme https`
    /// (static 23), then B.2's two post-Base lines.
    static let dynamicRequest: [UInt8] = H3Wire.frame(.headers, hexBytes("0381 d1 d7 10 11"))

    /// The server's decoder stream (its third unidirectional stream), after its type byte.
    static func serverDecoderStream(_ client: InMemoryMultiplexedTransport) async throws -> MuxStream {
        var iterator = client.inboundStreams.makeAsyncIterator()
        _ = try #require(try await iterator.next())   // control
        _ = try #require(try await iterator.next())   // encoder
        let decoder = try #require(try await iterator.next())
        #expect(try await receive(1, from: decoder) == [0x03])
        return decoder
    }

    /// Reads the decoder stream until `expected` has arrived in full (as a suffix).
    static func receiveDecoderStream(until expected: [UInt8], from stream: MuxStream) async throws -> [UInt8] {
        var buffer = ByteBuffer()
        var bytes: [UInt8] = []
        while !bytes.ends(with: expected) {
            guard try await stream.receive(into: &buffer, maxLength: 1024) > 0 else { break }
            buffer.withReadableSpan { span in for i in span.indices { bytes.append(span[i]) } }
            buffer.clear()
        }
        return bytes
    }

    @Test func settingsAdvertiseTheDynamicTable() async throws {
        try await withH3Server(handler: PathHandler(), configuration: Self.configuration) { client, _ in
            var iterator = client.inboundStreams.makeAsyncIterator()
            let control = try #require(try await iterator.next())
            let expected = H3Settings(qpackMaxTableCapacity: 220, maxFieldSectionSize: 16 * 1024, qpackBlockedStreams: 2)
            let preface = [0x00] + H3Wire.settings(expected)
            #expect(try await receive(preface.count, from: control) == preface)
        }
    }

    @Test func requestReferencingInsertedEntriesIsServedAndAcknowledged() async throws {
        try await withH3Server(handler: PathHandler(), configuration: Self.configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            let decoder = try await Self.serverDecoderStream(client)
            try await h3.openUniStream(Self.encoderStream)
            // Insert Count Increment 2 acknowledges both inserts.
            #expect(try await Self.receiveDecoderStream(until: [0x02], from: decoder) == [0x02])

            let response = await H3TestResponse.read(try await h3.openRequest(Self.dynamicRequest))
            #expect(response.status == "200")
            #expect(response.bodyString == "hello /sample/path")
            // Section Acknowledgment for stream 0.
            #expect(try await Self.receiveDecoderStream(until: [0x80], from: decoder) == [0x80])

            // A static-only request on the same connection is unaffected.
            let plain = try await h3.send(H3Wire.request(path: "/plain"))
            #expect(plain.bodyString == "hello /plain")
        }
    }

    @Test func blockedRequestWaitsForTheInserts() async throws {
        let started = Flag()
        let handler = ClosureHandler { request in
            started.set()
            return HTTPResponse(status: .ok, body: .bytes(ByteBuffer(bytes: Array(request.string(of: request.authority).utf8))))
        }
        try await withH3Server(handler: handler, configuration: Self.configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            let decoder = try await Self.serverDecoderStream(client)
            let stream = try await h3.openRequest(Self.dynamicRequest)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!started.isSet)   // blocked: the inserts have not arrived

            try await h3.openUniStream(Self.encoderStream)
            let response = await H3TestResponse.read(stream)
            #expect(response.status == "200")
            #expect(response.bodyString == "www.example.com")
            // The acknowledgment arrives (possibly after an Insert Count Increment).
            let bytes = try await Self.receiveDecoderStream(until: [0x80], from: decoder)
            #expect(bytes == [0x80] || bytes == [0x02, 0x80])
        }
    }

    @Test func tooManyBlockedStreamsIsDecompressionFailed() async throws {
        let code = try await withH3Server(handler: PathHandler(), configuration: Self.configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            for _ in 0..<3 {
                _ = try? await h3.openRequest(Self.dynamicRequest)
            }
            return await serverCloseCode(client)
        }
        #expect(code == 0x0200)
    }

    @Test func blockedRequestThatTimesOutIsCancelledOnTheDecoderStream() async throws {
        var configuration = Self.configuration
        configuration.timeouts = H3Timeouts(header: .milliseconds(200))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            let decoder = try await Self.serverDecoderStream(client)
            let response = await H3TestResponse.read(try await h3.openRequest(Self.dynamicRequest, fin: false))
            #expect(response.resetCode != nil)
            // Stream Cancellation for stream 0.
            #expect(try await Self.receiveDecoderStream(until: [0x40], from: decoder) == [0x40])
        }
    }

    @Test func encoderCapacityAboveTheAdvertisedMaximumIsEncoderStreamError() async throws {
        let code = try await withH3Server(handler: PathHandler(), configuration: Self.configuration) { client, _ in
            // Set Dynamic Table Capacity 221.
            try await H3TestClient(transport: client).openUniStream([0x02] + hexBytes("3fbe01"))
            return await serverCloseCode(client)
        }
        #expect(code == QPACKErrorCode.encoderStream)
    }

    @Test func referenceToAMissingEntryIsDecompressionFailed() async throws {
        let code = try await withH3Server(handler: PathHandler(), configuration: Self.configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            // Capacity and one insert, then a section with Required Insert Count 1 whose
            // post-Base index 1 is absolute 1, beyond the insert count it declares.
            try await h3.openUniStream([0x02] + hexBytes("3fbd01 c00f7777772e6578616d706c652e636f6d"))
            try await Task.sleep(for: .milliseconds(50))
            _ = try? await h3.openRequest(H3Wire.frame(.headers, hexBytes("0200 d1 d7 11 c1")))
            return await serverCloseCode(client)
        }
        #expect(code == 0x0200)
    }
}

func hexBytes(_ string: String) -> [UInt8] {
    let digits = Array(string.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
