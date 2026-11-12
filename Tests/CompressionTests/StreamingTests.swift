import Compression
import Foundation
import HTTPCore
import Synchronization
import Testing

/// `.stream` and `.file` bodies are compressed incrementally: bounded pieces, sent as the
/// producer writes, and paced by the transport.
@Suite(.timeLimit(.minutes(1)))
struct StreamingTests {
    /// Produces `total` bytes in `piece`-sized writes, recording how far it got whenever the
    /// sink receives something.
    final class Producer: Sendable {
        let text: [UInt8]
        let piece: Int
        let produced = Atomic<Int>(0)

        init(total: Int, piece: Int) {
            text = sampleText(total, seed: 7)
            self.piece = piece
        }

        var body: HTTPResponseBody {
            .stream(length: nil) { writer in
                var offset = 0
                while offset < self.text.count {
                    let end = min(offset + self.piece, self.text.count)
                    try await writer.write(ByteBuffer(bytes: self.text[offset..<end]))
                    offset = end
                    self.produced.store(offset, ordering: .relaxed)
                }
            }
        }
    }

    /// Records, for each piece it receives, how much the producer had written by then.
    final class Observer: HTTPBodyWriter, Sendable {
        let producer: Producer
        let delay: Duration?
        let state = Mutex<(bytes: [UInt8], writes: [Int], producedAtWrite: [Int])>(([], [], []))

        init(_ producer: Producer, delay: Duration? = nil) {
            self.producer = producer
            self.delay = delay
        }

        func write(_ bytes: ByteBuffer) async throws {
            let produced = producer.produced.load(ordering: .relaxed)
            if let delay { try await Task.sleep(for: delay) }
            let copy = bytes.withUnsafeReadableBytes { Array($0) }
            state.withLock {
                $0.bytes += copy
                $0.writes.append(copy.count)
                $0.producedAtWrite.append(produced)
            }
        }
    }

    @Test(arguments: ContentCoding.allCases)
    func largeStreamIsCompressedIncrementallyWithBoundedPieces(_ coding: ContentCoding) async throws {
        var configuration = CompressionConfiguration()
        configuration.chunkSize = 8 * 1024
        let compression = Compression(configuration: configuration)
        let producer = Producer(total: 8 * 1024 * 1024, piece: 64 * 1024)
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain")
        let original = HTTPResponse(headers: headers, body: producer.body)
        let result = try await compress(original, headers: [("Accept-Encoding", String(describing: coding.token))],
                                        with: compression)
        #expect(result.header(.contentEncoding) == String(describing: coding.token))
        guard case .stream(let length, let run) = result.body else {
            Issue.record("not a stream")
            return
        }
        #expect(length == nil, "chunked on HTTP/1.1")
        let observer = Observer(producer)
        try await run(observer)
        let (bytes, writes, producedAtWrite) = observer.state.withLock { ($0.bytes, $0.writes, $0.producedAtWrite) }
        #expect(ContentCodec.decode(bytes, coding) == producer.text)
        // Bounded: no piece larger than chunkSize, so the response never holds more than one.
        #expect(writes.max()! <= configuration.chunkSize)
        #expect(writes.count > 4)
        // Incremental: compressed output reached the sink long before the producer finished.
        #expect(producedAtWrite.first! < producer.text.count / 2, "\(producedAtWrite.prefix(3))")
    }

    @Test func slowSinkPacesTheProducer() async throws {
        var configuration = CompressionConfiguration()
        configuration.chunkSize = 4 * 1024
        let producer = Producer(total: 2 * 1024 * 1024, piece: 16 * 1024)
        var headers = HTTPFields()
        headers.append(.contentType, "application/json")
        let original = HTTPResponse(headers: headers, body: producer.body)
        let result = try await compress(original, headers: [("Accept-Encoding", "gzip")],
                                        with: Compression(configuration: configuration))
        guard case .stream(_, let run) = result.body else { Issue.record("not a stream"); return }
        let observer = Observer(producer, delay: .milliseconds(2))
        try await run(observer)
        let (bytes, producedAtWrite) = observer.state.withLock { ($0.bytes, $0.producedAtWrite) }
        #expect(ContentCodec.decode(bytes, .gzip) == producer.text)
        // While the sink is slow the producer waits inside its write: output pieces arrive
        // throughout production, never more than a few producer writes apart (zlib holds up to
        // about 16K symbols before emitting a block), instead of all at the end.
        #expect(producedAtWrite.isSorted())
        #expect(producedAtWrite.count > 10)
        let gaps = zip(producedAtWrite, producedAtWrite.dropFirst()).map { $1 - $0 }
        #expect(gaps.max()! <= 8 * producer.piece, "\(gaps.max()!)")
        #expect(producedAtWrite.first! <= 8 * producer.piece)
    }

    @Test func producerErrorPropagates() async throws {
        struct Boom: Error {}
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain")
        let failing = HTTPResponse(headers: headers, body: .stream(length: nil) { writer in
            try await writer.write(ByteBuffer(bytes: sampleText(100_000)))
            throw Boom()
        })
        let result = try await compress(failing, headers: [("Accept-Encoding", "gzip")])
        guard case .stream(_, let run) = result.body else { Issue.record("not a stream"); return }
        await #expect(throws: Boom.self) { try await run(CollectingWriter()) }
    }

    @Test(arguments: [ContentCoding.gzip, .brotli])
    func largeFileIsStreamed(_ coding: ContentCoding) async throws {
        let text = sampleText(3 * 1024 * 1024 + 17, seed: 9)
        let url = FileManager.default.temporaryDirectory.appending(path: "sws-compression-\(UInt64.random(in: 0...UInt64.max)).txt")
        try Data(text).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try OwnedFileDescriptor.openForReading(path: url.path)
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain")
        headers.append(.contentLength, decimal: text.count)
        let original = HTTPResponse(headers: headers, body: .file(try FileRegion.entireFile(file)))
        let result = try await compress(original, headers: [("Accept-Encoding", String(describing: coding.token))])
        #expect(result.header(.contentLength) == nil)
        guard case .stream(nil, _) = result.body else { Issue.record("not an unsized stream"); return }
        let sink = CollectingWriter()
        let body = try await result.bodyBytes(into: sink)
        #expect(sink.writes.max()! <= CompressionConfiguration().chunkSize)
        #expect(ContentCodec.decode(body, coding) == text)
    }

    @Test func fileRegionOffsetIsHonoured() async throws {
        let text = sampleText(200_000, seed: 3)
        let url = FileManager.default.temporaryDirectory.appending(path: "sws-compression-\(UInt64.random(in: 0...UInt64.max)).txt")
        try Data(text).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try OwnedFileDescriptor.openForReading(path: url.path)
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain")
        let original = HTTPResponse(headers: headers, body: .file(FileRegion(file: file, offset: 1000, length: 150_000)))
        let result = try await compress(original, headers: [("Accept-Encoding", "gzip")])
        #expect(ContentCodec.decode(try await result.bodyBytes(), .gzip) == Array(text[1000..<151_000]))
    }
}

extension Array where Element: Comparable {
    func isSorted() -> Bool { zip(self, dropFirst()).allSatisfy { $0 <= $1 } }
}
