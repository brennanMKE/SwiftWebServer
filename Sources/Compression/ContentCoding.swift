/// A content coding this component can produce (RFC 9110 §8.4.1).
///
/// The raw values are the server's preference among codings the client weights equally:
/// `br` first, then `gzip`, then `deflate` (smaller is preferred).
public enum ContentCoding: Int, Sendable, Hashable, CaseIterable, Comparable {
    /// Brotli (RFC 7932), `br`.
    case brotli = 0
    /// Deflate in the gzip file format (RFC 1952), `gzip` (alias `x-gzip`).
    case gzip = 1
    /// Deflate in the zlib format (RFC 1950), `deflate`.
    case deflate = 2

    public static func < (lhs: ContentCoding, rhs: ContentCoding) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The token sent in `Content-Encoding` and matched in `Accept-Encoding`.
    public var token: StaticString {
        switch self {
        case .brotli: "br"
        case .gzip: "gzip"
        case .deflate: "deflate"
        }
    }

    /// The suffix added inside the quotes of a strong `ETag` for this coding's variant, so the
    /// variant has its own validator (`"abc"` becomes `"abc-gz"`).
    public var etagSuffix: StaticString {
        switch self {
        case .brotli: "-br"
        case .gzip: "-gz"
        case .deflate: "-df"
        }
    }

    /// The file name extension of a precompressed sidecar (`index.html.br`); `nil` for
    /// `deflate`, which has no conventional sidecar.
    public var sidecarExtension: String? {
        switch self {
        case .brotli: ".br"
        case .gzip: ".gz"
        case .deflate: nil
        }
    }

    /// Parses a configuration name: `br`/`brotli`, `gzip`, `deflate` (any case).
    public init?(name: String) {
        switch name.lowercased() {
        case "br", "brotli": self = .brotli
        case "gzip", "x-gzip": self = .gzip
        case "deflate": self = .deflate
        default: return nil
        }
    }

    /// True when the system library this coding needs is present (Brotli comes from
    /// `libcompression`, loaded at run time; gzip and deflate from `libz`).
    public var isAvailable: Bool {
        self == .brotli ? BrotliLibrary.shared != nil : true
    }
}

/// A set of ``ContentCoding``s as a bit mask: no allocation, cheap to test.
public struct ContentCodingSet: Sendable, Hashable {
    public var rawValue: UInt8

    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    public init(_ codings: some Sequence<ContentCoding>) {
        rawValue = 0
        for coding in codings { insert(coding) }
    }

    public static let empty = ContentCodingSet(rawValue: 0)

    @inlinable public var isEmpty: Bool { rawValue == 0 }

    @inlinable public func contains(_ coding: ContentCoding) -> Bool {
        rawValue & (1 << UInt8(coding.rawValue)) != 0
    }

    @inlinable public mutating func insert(_ coding: ContentCoding) {
        rawValue |= 1 << UInt8(coding.rawValue)
    }

    /// The members in preference order.
    public var members: [ContentCoding] { ContentCoding.allCases.filter(contains) }
}
