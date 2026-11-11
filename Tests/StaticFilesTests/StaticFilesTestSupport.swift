import Foundation
import HTTPCore
@testable import StaticFiles

/// A fixture tree under `$TMPDIR`, removed by ``remove()``.
final class Fixture {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "sws-staticfiles-\(UInt64.random(in: 0...UInt64.max))")
        root = base.appending(path: "Public")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { remove() }

    func remove() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ relative: String, _ text: String, in directory: URL? = nil) throws -> URL {
        try write(relative, Data(text.utf8), in: directory)
    }

    @discardableResult
    func write(_ relative: String, _ data: Data, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func mkdir(_ relative: String, in directory: URL? = nil) throws {
        try FileManager.default.createDirectory(at: (directory ?? root).appending(path: relative),
                                                withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: relative).path,
                                                   withDestinationPath: destination)
    }

    func files(_ configure: (inout StaticFilesConfiguration) -> Void = { _ in }) throws -> StaticFiles {
        var configuration = StaticFilesConfiguration()
        configure(&configuration)
        return try StaticFiles(root: root.path, configuration: configuration)
    }
}

/// A request built the way a connection builds one: target and fields in one storage.
struct TestRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(_ method: HTTPMethod = .get, _ target: String, headers: [(String, String)] = []) {
        storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 8)
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathStart = storage.buffer.writerIndex
        storage.buffer.append(contentsOf: Array(parts[0].utf8))
        let path = ByteView(offset: pathStart, length: storage.buffer.writerIndex - pathStart)
        var query = ByteView.empty
        if parts.count > 1 {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(parts[1].utf8))
            query = ByteView(offset: start, length: storage.buffer.writerIndex - start)
        }
        for (name, value) in headers {
            let nameStart = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(name.utf8))
            let nameView = ByteView(offset: nameStart, length: storage.buffer.writerIndex - nameStart)
            let valueStart = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(value.utf8))
            let valueView = ByteView(offset: valueStart, length: storage.buffer.writerIndex - valueStart)
            let hash = storage.buffer.withSpan(of: nameView) { ASCII.fnv1aLowercased($0) }
            storage.appendField(nameView: nameView, hash: hash, valueView: valueView)
        }
        request = HTTPRequest(method: method, path: path, query: query, headers: storage.fieldsView)
    }
}

extension StaticFiles {
    /// `handle(_:context:)` for a test request.
    func get(_ target: String, method: HTTPMethod = .get, headers: [(String, String)] = []) async throws -> HTTPResponse {
        let built = TestRequest(method, target, headers: headers)
        return try await handle(built.request, context: RequestContext())
    }
}

extension HTTPResponse {
    func header(_ name: HTTPFieldName) -> String? { headers.firstValueString(for: name) }

    /// The body bytes: the buffer, or the file region read with `pread`.
    var bodyBytes: [UInt8] {
        switch body {
        case .empty: return []
        case .bytes(let buffer): return buffer.withUnsafeReadableBytes { Array($0) }
        case .file(let region):
            var bytes = [UInt8](repeating: 0, count: Int(region.length))
            let n = bytes.withUnsafeMutableBytes { pread(region.file.rawValue, $0.baseAddress, Int(region.length), off_t(region.offset)) }
            return Array(bytes.prefix(max(n, 0)))
        default: return []
        }
    }

    var bodyText: String { String(decoding: bodyBytes, as: UTF8.self) }

    var isFileBody: Bool {
        if case .file = body { return true }
        return false
    }
}
