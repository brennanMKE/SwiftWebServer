import HTTPCore

/// Test helper: a minimal field-line scanner standing in for the HTTP/1.1 parser (#0075).
/// Hashes each name in the same pass that finds `:`, then hands the precomputed hash to
/// `HTTPRequestStorage.appendField`, which is the entry point the real parser uses.
enum FieldScanner {
    /// Appends `lines` (`Name: value` separated by CRLF, no final empty line) to the storage's
    /// buffer and indexes every field.
    static func fill(_ storage: HTTPRequestStorage, with lines: String) {
        let start = storage.buffer.writerIndex
        storage.buffer.append(contentsOf: Array(lines.utf8))
        let end = storage.buffer.writerIndex
        var lineStart = start
        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end, storage.buffer.byte(at: lineEnd) != 0x0D { lineEnd += 1 }
            var hasher = ASCII.FNV1a()
            var colon = lineStart
            while storage.buffer.byte(at: colon) != UInt8(ascii: ":") {
                hasher.combineLowercased(storage.buffer.byte(at: colon))
                colon += 1
            }
            var valueStart = colon + 1
            while valueStart < lineEnd, storage.buffer.byte(at: valueStart) == 0x20 { valueStart += 1 }
            var valueEnd = lineEnd
            while valueEnd > valueStart, storage.buffer.byte(at: valueEnd - 1) == 0x20 { valueEnd -= 1 }
            storage.appendField(nameView: ByteView(offset: lineStart, length: colon - lineStart),
                                hash: hasher.value,
                                valueView: ByteView(offset: valueStart, length: valueEnd - valueStart))
            lineStart = lineEnd + 2
        }
    }

    /// A fresh storage holding `lines`, and a view of it.
    static func view(_ lines: String) -> (HTTPRequestStorage, HTTPFieldsView) {
        let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 16)
        fill(storage, with: lines)
        return (storage, storage.fieldsView)
    }
}

extension HTTPFieldCollection {
    /// Test helper: every (name, value) pair as Strings, in order.
    var pairs: [(String, String)] {
        (0..<count).map { (nameString(at: $0), valueString(at: $0)) }
    }

    /// Test helper: the values of `name` as Strings, in order.
    func valueStrings(for name: HTTPFieldName) -> [String] {
        values(for: name).map { string(of: $0) }
    }
}
