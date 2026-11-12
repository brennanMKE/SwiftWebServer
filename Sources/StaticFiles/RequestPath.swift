import HTTPCore

/// Why a request path is refused before the file system is touched.
enum PathRejection: Error, Equatable {
    /// Malformed: no leading `/`, a bad `%` escape, or a decoded NUL, `/` or `\`. Answers `400`.
    case malformed
    /// A `..` component or a blocked name. Answers `403`.
    case forbidden
}

/// Lowercased block-list entries, matched against whole path components (#0013).
struct BlockList: Sendable {
    let names: [[UInt8]]
    let blockDotfiles: Bool

    init(names: [String], blockDotfiles: Bool) {
        self.names = names.map { Array($0.utf8).map(ASCII.lowercased) }
        self.blockDotfiles = blockDotfiles
    }

    /// True when the component `bytes` is refused.
    func blocks(_ bytes: Span<UInt8>) -> Bool {
        if blockDotfiles, bytes.count > 0, bytes[0] == UInt8(ascii: ".") {
            if !Self.equalsLowercased(bytes, Self.wellKnown) { return true }
        }
        for name in names where Self.equalsLowercased(bytes, name) { return true }
        return false
    }

    /// True when every component of the `/`-separated `path` is allowed.
    func allows(path: Span<UInt8>) -> Bool {
        var start = 0
        var i = 0
        while i <= path.count {
            if i == path.count || path[i] == UInt8(ascii: "/") {
                if i > start, blocks(path.extracting(start..<i)) { return false }
                start = i + 1
            }
            i += 1
        }
        return true
    }

    static let wellKnown = Array(".well-known".utf8)

    static func equalsLowercased(_ bytes: Span<UInt8>, _ lowercased: [UInt8]) -> Bool {
        guard bytes.count == lowercased.count else { return false }
        for i in 0..<bytes.count where ASCII.lowercased(bytes[i]) != lowercased[i] { return false }
        return true
    }
}

/// A request path decoded once and normalized (#0015).
struct DecodedPath: Equatable {
    /// Components joined by `/`, without a leading or trailing `/`; empty for the root.
    var relative: [UInt8]
    /// The raw path ended with `/`.
    var trailingSlash: Bool

    /// Decodes `raw` (the still-encoded request path) exactly once and checks every component.
    ///
    /// Percent escapes are decoded only when `%` is present, and a decoded `%` stays a literal
    /// byte, so `%2525` is the file `%25`, never `%`. Every check runs on the decoded bytes,
    /// the same bytes used to open the file:
    /// - malformed escapes, NUL, `\` and an encoded `/` are ``PathRejection/malformed``;
    /// - a `..` component (however encoded) and a blocked name are ``PathRejection/forbidden``;
    /// - empty and `.` components are dropped.
    static func decode(_ raw: Span<UInt8>, blockList: BlockList) throws(PathRejection) -> DecodedPath {
        guard raw.count > 0, raw[0] == UInt8(ascii: "/") else {
            if raw.count == 0 { return DecodedPath(relative: [], trailingSlash: true) }
            throw .malformed
        }
        var output: [UInt8] = []
        output.reserveCapacity(raw.count)
        var segmentStart = 0          // index in `output` where the current component starts
        var i = 1
        func endSegment() throws(PathRejection) {
            let length = output.count - segmentStart
            if length == 0 { return }
            if length == 1 && output[segmentStart] == UInt8(ascii: ".") {
                output.removeLast(1)
            } else if length == 2 && output[segmentStart] == UInt8(ascii: ".")
                        && output[segmentStart + 1] == UInt8(ascii: ".") {
                throw .forbidden
            } else if output.withUnsafeBufferPointer({ [segmentStart] in
                blockList.blocks($0.span.extracting(segmentStart..<$0.count))
            }) {
                throw .forbidden
            } else {
                output.append(UInt8(ascii: "/"))
                segmentStart = output.count
                return
            }
        }
        while i < raw.count {
            var byte = raw[i]
            if byte == UInt8(ascii: "/") {
                try endSegment()
                i += 1
                continue
            }
            if byte == UInt8(ascii: "%") {
                guard i + 2 < raw.count,
                      let high = ASCII.hexDigitValue(raw[i + 1]),
                      let low = ASCII.hexDigitValue(raw[i + 2]) else { throw .malformed }
                byte = high << 4 | low
                if byte == UInt8(ascii: "/") { throw .malformed }
                i += 3
            } else {
                i += 1
            }
            if byte == 0 || byte == UInt8(ascii: "\\") { throw .malformed }
            output.append(byte)
        }
        try endSegment()
        if output.last == UInt8(ascii: "/") { output.removeLast() }
        return DecodedPath(relative: output, trailingSlash: raw[raw.count - 1] == UInt8(ascii: "/"))
    }

    /// The last component (the file name), or empty for the root.
    var lastComponent: ArraySlice<UInt8> {
        guard let slash = relative.lastIndex(of: UInt8(ascii: "/")) else { return relative[...] }
        return relative[(slash + 1)...]
    }

    /// `/` + the relative path percent-encoded where needed + `/`: the `Location` of the
    /// redirect that adds a trailing slash to a directory. Built from the normalized path, so
    /// a request such as `//evil.example` can never produce a scheme-relative redirect.
    func redirectLocation(query: Span<UInt8>) -> [UInt8] {
        var location: [UInt8] = [UInt8(ascii: "/")]
        for byte in relative {
            if Self.isPathSafe(byte) {
                location.append(byte)
            } else {
                location.append(UInt8(ascii: "%"))
                location.append(Self.upperHex(byte >> 4))
                location.append(Self.upperHex(byte & 0xF))
            }
        }
        if !relative.isEmpty { location.append(UInt8(ascii: "/")) }
        if query.count > 0 {
            location.append(UInt8(ascii: "?"))
            for i in 0..<query.count { location.append(query[i]) }
        }
        return location
    }

    static func upperHex(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "A") + nibble - 10
    }

    /// RFC 3986 `pchar` minus `%` (which must be re-encoded), plus `/`.
    static func isPathSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            // unreserved "-._~", sub-delims "!$&'()*+,;=", ":@" and "/".
            return "-._~!$&'()*+,;=:@/".utf8.contains(byte)
        }
    }
}
