import Foundation
import Synchronization
import Testing
import HTTPCore

/// Records each send so the default `sendFile` loop's chunking can be asserted.
private final class SpyTransport: ByteStreamTransport {
    let sends = Mutex<[ByteBuffer]>([])
    var info: ConnectionInfo { ConnectionInfo() }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int { 0 }
    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        sends.withLock { $0.append(bytes) }
    }
    func close(_ reason: CloseReason) async {}

    var sizes: [Int] { sends.withLock { $0.map(\.readableBytes) } }
    var joined: ByteBuffer {
        sends.withLock { sends in
            var all = ByteBuffer()
            for send in sends { all.append(send) }
            return all
        }
    }
}

private struct StreamStub: StreamIdentified {
    let streamID: UInt64
}

/// A temporary file in `$TMPDIR`, removed when the test ends.
private struct TempFile: ~Copyable {
    let url: URL
    init(_ contents: ByteBuffer) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransportTests-\(UInt64.random(in: 0 ... .max)).bin")
        try contents.makeData().write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func pattern(_ count: Int) -> ByteBuffer {
    ByteBuffer(bytes: (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
}

@Suite(.timeLimit(.minutes(1))) struct TransportTests {
    @Test func sendFileReadsInBoundedChunks() async throws {
        let file = try TempFile(pattern(10_500))
        let region = FileRegion(file: try OwnedFileDescriptor.openForReading(path: file.url.path), length: 10_500)
        let spy = SpyTransport()
        try await spy.sendFileByReading(region, chunkSize: 1_000)
        #expect(spy.sizes == Array(repeating: 1_000, count: 10) + [500])
        #expect(spy.joined == pattern(10_500))
    }

    @Test func defaultSendFileHonoursOffsetAndLength() async throws {
        let contents = pattern(300_000)
        let file = try TempFile(contents)
        let fd = try OwnedFileDescriptor.openForReading(path: file.url.path)
        let spy = SpyTransport()
        try await spy.sendFile(FileRegion(file: fd, offset: 1_234, length: 200_000))
        #expect(spy.sizes.allSatisfy { $0 <= FileRegion.defaultChunkSize })
        var expected = ByteBuffer()
        expected.append(ByteView(offset: 1_234, length: 200_000), from: contents)
        #expect(spy.joined == expected)
    }

    @Test func emptyRegionSendsNothing() async throws {
        let file = try TempFile(pattern(10))
        let spy = SpyTransport()
        try await spy.sendFile(FileRegion(file: try OwnedFileDescriptor.openForReading(path: file.url.path), length: 0))
        #expect(spy.sizes.isEmpty)
    }

    @Test func regionPastEndOfFileThrows() async throws {
        let file = try TempFile(pattern(100))
        let fd = try OwnedFileDescriptor.openForReading(path: file.url.path)
        #expect(try FileRegion.entireFile(fd).length == 100)
        let spy = SpyTransport()
        await #expect(throws: TransportError.unexpectedEndOfFile) {
            try await spy.sendFileByReading(FileRegion(file: fd, offset: 50, length: 100), chunkSize: 30)
        }
        #expect(spy.sizes == [30, 20])   // the bytes that existed were sent first
    }

    @Test func unreadableDescriptorThrowsFileReadFailed() async throws {
        let file = try TempFile(pattern(10))
        let raw = open(file.url.path, O_WRONLY)
        #expect(raw >= 0)
        let fd = OwnedFileDescriptor(takingOwnershipOf: raw)
        await #expect(throws: TransportError.fileReadFailed(errno: EBADF)) {
            try await SpyTransport().sendFile(FileRegion(file: fd, length: 10))
        }
    }

    @Test func openMissingFileThrows() {
        #expect(throws: TransportError.fileOpenFailed(errno: ENOENT)) {
            _ = try OwnedFileDescriptor.openForReading(path: "/nonexistent-\(UInt64.random(in: 0 ... .max))")
        }
    }

    @Test func sendFileStopsWhenCancelled() async throws {
        let file = try TempFile(pattern(4_096))
        let fd = try OwnedFileDescriptor.openForReading(path: file.url.path)
        let spy = SpyTransport()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await spy.sendFileByReading(FileRegion(file: fd, length: 4_096), chunkSize: 1_024)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(spy.sizes.isEmpty)
    }

    @Test func closeReasonAbortiveness() {
        #expect(CloseReason.abort.isAbortive)
        for reason in [CloseReason.normal, .timeout, .protocolError, .shutdown] {
            #expect(!reason.isAbortive)
        }
    }

    @Test func streamIDBits() {
        #expect(StreamStub(streamID: 0).isClientInitiated)
        #expect(!StreamStub(streamID: 0).isUnidirectional)
        #expect(StreamStub(streamID: 2).isUnidirectional)
        #expect(!StreamStub(streamID: 3).isClientInitiated)
        #expect(StreamStub(streamID: 3).isUnidirectional)
    }

    @Test func addressDescription() {
        #expect(TransportAddress(host: "127.0.0.1", port: 8080).description == "127.0.0.1:8080")
        #expect(TransportAddress(host: "::1", port: 443).description == "[::1]:443")
        let info = ConnectionInfo()
        #expect(info.localAddress == nil && !info.isSecure && info.negotiatedALPN == nil)
    }
}
