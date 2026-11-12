import HTTPCore

/// Settings for ``Compression`` and for precompressed static files (#0091).
public struct CompressionConfiguration: Sendable, Equatable {
    /// Codings offered, by default all three. Among codings a client weights equally the
    /// server prefers `br`, then `gzip`, then `deflate`, whatever the order here. Brotli is
    /// dropped at run time when `libcompression` lacks it (``ContentCoding/isAvailable``).
    public var encodings: [ContentCoding] = [.brotli, .gzip, .deflate]

    /// Bodies shorter than this many bytes are sent as they are: the coding's framing and
    /// the CPU cost outweigh the saving. A body of unknown length (a stream) is compressed.
    public var minimumSize = 1024

    /// Media types worth compressing, compared case-insensitively with the response's
    /// `Content-Type` (parameters ignored):
    /// - `type/*` matches every subtype (`text/*`);
    /// - `*+suffix` matches a structured syntax suffix (`*+json` matches
    ///   `application/ld+json`);
    /// - anything else matches exactly.
    ///
    /// Types that are already compressed (images other than SVG, audio, video, archives,
    /// `font/woff2`) are left out on purpose; so is `text/event-stream`, whose events must
    /// not wait for a compressor's buffer (it is refused even when a pattern matches).
    public var mimeTypes: [String] = [
        "text/*",
        "application/json", "*+json",
        "application/javascript", "application/x-javascript", "application/ecmascript",
        "application/xml", "*+xml",           // includes image/svg+xml, application/rss+xml
        "application/wasm",
        "application/yaml", "application/x-yaml", "application/toml",
        "font/ttf", "font/otf", "application/vnd.ms-fontobject",
        "image/x-icon", "image/bmp",
    ]

    /// zlib level (1...9) for `gzip` and `deflate` produced per response. 4 compresses HTML to
    /// about the size Brotli's built-in level gives, at about half the CPU of level 6
    /// (docs/benchmarks/M6-compression.md).
    public var level = 4

    /// zlib level (1...9) for variants compressed once and cached (static files).
    public var precompressionLevel = 9

    /// Output is sent in pieces of this many bytes when a stream or a large file is
    /// compressed; large files are read in pieces of this size too. Bounds the memory a
    /// streamed response holds beyond the compressor's own state.
    public var chunkSize = 16 * 1024

    /// Most idle zlib encoders kept for reuse per coding. Each holds about 256 KiB; reuse
    /// saves its allocation and initialization on every response.
    public var pooledEncoders = 16

    public init() {}

    /// The configured codings this system can produce.
    public var availableEncodings: ContentCodingSet {
        ContentCodingSet(encodings.filter(\.isAvailable))
    }
}

/// ``CompressionConfiguration/mimeTypes`` compiled to byte patterns.
public struct CompressibleTypes: Sendable {
    enum Pattern: Sendable {
        case exact([UInt8])
        case prefix([UInt8])          // "text/" for "text/*"
        case suffix([UInt8])          // "+json" for "*+json"
    }

    let patterns: [Pattern]

    public init(_ types: [String]) {
        patterns = types.compactMap { type in
            let bytes = Array(type.lowercased().utf8)
            guard !bytes.isEmpty else { return nil }
            if bytes.count >= 2, bytes[bytes.count - 1] == UInt8(ascii: "*"), bytes[bytes.count - 2] == UInt8(ascii: "/") {
                return .prefix(Array(bytes.dropLast()))
            }
            if bytes[0] == UInt8(ascii: "*") { return .suffix(Array(bytes.dropFirst())) }
            return .exact(bytes)
        }
    }

    /// True when the `Content-Type` value `value` (parameters allowed) matches a pattern.
    public func matches(_ value: Span<UInt8>) -> Bool {
        var end = 0
        while end < value.count, value[end] != UInt8(ascii: ";") { end &+= 1 }
        while end > 0, value[end &- 1] == 0x20 || value[end &- 1] == 0x09 { end &-= 1 }
        var start = 0
        while start < end, value[start] == 0x20 || value[start] == 0x09 { start &+= 1 }
        let type = value.extracting(start..<end)
        if ASCII.equalsCaseInsensitive(type, "text/event-stream") { return false }
        for pattern in patterns {
            switch pattern {
            case .exact(let bytes):
                if Self.equal(type, from: 0, bytes) && type.count == bytes.count { return true }
            case .prefix(let bytes):
                if type.count > bytes.count && Self.equal(type, from: 0, bytes) { return true }
            case .suffix(let bytes):
                if type.count > bytes.count && Self.equal(type, from: type.count - bytes.count, bytes) { return true }
            }
        }
        return false
    }

    /// True when `type[offset...]` starts with the lowercase `bytes`, ignoring case.
    @inline(__always)
    static func equal(_ type: Span<UInt8>, from offset: Int, _ bytes: [UInt8]) -> Bool {
        guard offset >= 0, type.count - offset >= bytes.count else { return false }
        for i in 0..<bytes.count where ASCII.lowercased(type[offset &+ i]) != bytes[i] { return false }
        return true
    }
}
