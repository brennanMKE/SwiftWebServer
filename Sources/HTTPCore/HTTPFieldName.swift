/// A header field name as a small integer ID.
///
/// Well-known names (the HPACK and QPACK static-table names, the HTTP/1.1 framing and
/// connection fields, WebSocket handshake fields, and the HTTP/2 / HTTP/3 pseudo-headers) have
/// their own case; any other name is ``unknown`` and keeps its bytes in the field storage.
/// Comparing two IDs is one byte compare, which is how field lookup avoids string comparison
/// (docs/ROADMAP.md §7, "header names as small IDs").
///
/// Raw values are dense, start at 1 and stay below 128 so that a field collection can track
/// which IDs it contains in a 128-bit mask.
///
/// ## Resolving names
///
/// Names resolve through a 512-slot power-of-two table keyed by the 32-bit FNV-1a hash of the
/// lowercased name (``ASCII/FNV1a``). A parser that hashes the name while scanning for `:`
/// calls ``lookup(hash:name:)`` with that hash, so resolution costs one multiply, one table
/// load, one hash compare and one byte compare of the candidate name. The table has no
/// collisions between well-known names (checked when the table is built and by tests); an
/// unknown name that lands on a well-known slot is rejected by the hash and byte compare.
public enum HTTPFieldName: UInt8, CaseIterable, Sendable {
    /// A name that is not well known. Its bytes live in the field storage.
    case unknown = 0

    // Pseudo-headers (RFC 9113 §8.3, RFC 9114 §4.3, RFC 8441 `:protocol`).
    case pseudoAuthority
    case pseudoMethod
    case pseudoPath
    case pseudoScheme
    case pseudoStatus
    case pseudoProtocol

    case accept
    case acceptCharset
    case acceptEncoding
    case acceptLanguage
    case acceptRanges
    case accessControlAllowCredentials
    case accessControlAllowHeaders
    case accessControlAllowMethods
    case accessControlAllowOrigin
    case accessControlExposeHeaders
    case accessControlMaxAge
    case accessControlRequestHeaders
    case accessControlRequestMethod
    case age
    case allow
    case altSvc
    case authorization
    case cacheControl
    case connection
    case contentDisposition
    case contentEncoding
    case contentLanguage
    case contentLength
    case contentLocation
    case contentRange
    case contentSecurityPolicy
    case contentType
    case cookie
    case date
    case earlyData
    case etag
    case expect
    case expectCT
    case expires
    case forwarded
    case from
    case host
    case http2Settings
    case ifMatch
    case ifModifiedSince
    case ifNoneMatch
    case ifRange
    case ifUnmodifiedSince
    case keepAlive
    case lastModified
    case link
    case location
    case maxForwards
    case origin
    case pragma
    case priority
    case proxyAuthenticate
    case proxyAuthorization
    case proxyConnection
    case purpose
    case range
    case referer
    case refresh
    case retryAfter
    case secWebSocketAccept
    case secWebSocketExtensions
    case secWebSocketKey
    case secWebSocketProtocol
    case secWebSocketVersion
    case server
    case setCookie
    case strictTransportSecurity
    case te
    case timingAllowOrigin
    case trailer
    case transferEncoding
    case upgrade
    case upgradeInsecureRequests
    case userAgent
    case vary
    case via
    case wwwAuthenticate
    case xContentTypeOptions
    case xForwardedFor
    case xForwardedHost
    case xForwardedProto
    case xFrameOptions
    case xRequestID
    case xXSSProtection

    /// The lowercase name bytes; empty for ``unknown``.
    @inlinable
    public var canonicalName: StaticString {
        switch self {
        case .unknown: ""
        case .pseudoAuthority: ":authority"
        case .pseudoMethod: ":method"
        case .pseudoPath: ":path"
        case .pseudoScheme: ":scheme"
        case .pseudoStatus: ":status"
        case .pseudoProtocol: ":protocol"
        case .accept: "accept"
        case .acceptCharset: "accept-charset"
        case .acceptEncoding: "accept-encoding"
        case .acceptLanguage: "accept-language"
        case .acceptRanges: "accept-ranges"
        case .accessControlAllowCredentials: "access-control-allow-credentials"
        case .accessControlAllowHeaders: "access-control-allow-headers"
        case .accessControlAllowMethods: "access-control-allow-methods"
        case .accessControlAllowOrigin: "access-control-allow-origin"
        case .accessControlExposeHeaders: "access-control-expose-headers"
        case .accessControlMaxAge: "access-control-max-age"
        case .accessControlRequestHeaders: "access-control-request-headers"
        case .accessControlRequestMethod: "access-control-request-method"
        case .age: "age"
        case .allow: "allow"
        case .altSvc: "alt-svc"
        case .authorization: "authorization"
        case .cacheControl: "cache-control"
        case .connection: "connection"
        case .contentDisposition: "content-disposition"
        case .contentEncoding: "content-encoding"
        case .contentLanguage: "content-language"
        case .contentLength: "content-length"
        case .contentLocation: "content-location"
        case .contentRange: "content-range"
        case .contentSecurityPolicy: "content-security-policy"
        case .contentType: "content-type"
        case .cookie: "cookie"
        case .date: "date"
        case .earlyData: "early-data"
        case .etag: "etag"
        case .expect: "expect"
        case .expectCT: "expect-ct"
        case .expires: "expires"
        case .forwarded: "forwarded"
        case .from: "from"
        case .host: "host"
        case .http2Settings: "http2-settings"
        case .ifMatch: "if-match"
        case .ifModifiedSince: "if-modified-since"
        case .ifNoneMatch: "if-none-match"
        case .ifRange: "if-range"
        case .ifUnmodifiedSince: "if-unmodified-since"
        case .keepAlive: "keep-alive"
        case .lastModified: "last-modified"
        case .link: "link"
        case .location: "location"
        case .maxForwards: "max-forwards"
        case .origin: "origin"
        case .pragma: "pragma"
        case .priority: "priority"
        case .proxyAuthenticate: "proxy-authenticate"
        case .proxyAuthorization: "proxy-authorization"
        case .proxyConnection: "proxy-connection"
        case .purpose: "purpose"
        case .range: "range"
        case .referer: "referer"
        case .refresh: "refresh"
        case .retryAfter: "retry-after"
        case .secWebSocketAccept: "sec-websocket-accept"
        case .secWebSocketExtensions: "sec-websocket-extensions"
        case .secWebSocketKey: "sec-websocket-key"
        case .secWebSocketProtocol: "sec-websocket-protocol"
        case .secWebSocketVersion: "sec-websocket-version"
        case .server: "server"
        case .setCookie: "set-cookie"
        case .strictTransportSecurity: "strict-transport-security"
        case .te: "te"
        case .timingAllowOrigin: "timing-allow-origin"
        case .trailer: "trailer"
        case .transferEncoding: "transfer-encoding"
        case .upgrade: "upgrade"
        case .upgradeInsecureRequests: "upgrade-insecure-requests"
        case .userAgent: "user-agent"
        case .vary: "vary"
        case .via: "via"
        case .wwwAuthenticate: "www-authenticate"
        case .xContentTypeOptions: "x-content-type-options"
        case .xForwardedFor: "x-forwarded-for"
        case .xForwardedHost: "x-forwarded-host"
        case .xForwardedProto: "x-forwarded-proto"
        case .xFrameOptions: "x-frame-options"
        case .xRequestID: "x-request-id"
        case .xXSSProtection: "x-xss-protection"
        }
    }

    /// True for every case except ``unknown``.
    @inlinable public var isWellKnown: Bool { self != .unknown }

    /// True for `:authority`, `:method`, `:path`, `:scheme`, `:status` and `:protocol`.
    @inlinable public var isPseudoHeader: Bool {
        rawValue &- HTTPFieldName.pseudoAuthority.rawValue <= HTTPFieldName.pseudoProtocol.rawValue &- HTTPFieldName.pseudoAuthority.rawValue
    }
}

// MARK: - Well-known name table

extension HTTPFieldName {
    /// Multiplier that spreads the FNV-1a hash before taking the top ``tableBits`` bits.
    ///
    /// Chosen by search so that every well-known name gets its own slot. Adding a name can
    /// introduce a collision, which traps when the table is built and fails
    /// `HTTPFieldNameTests.tableIsCollisionFree`; pick a new odd multiplier (or a larger
    /// table) by trying random odd 32-bit values until the test passes.
    @usableFromInline static let tableMultiplier: UInt32 = 0x014C_6DC7

    /// log2 of the table size.
    @usableFromInline static let tableBits: UInt32 = 9

    /// Number of slots in the table (a power of two).
    public static var tableSize: Int { 1 << Int(tableBits) }

    /// The table slot for an FNV-1a hash.
    @inlinable
    public static func tableSlot(forHash hash: UInt32) -> Int {
        Int(truncatingIfNeeded: (hash &* tableMultiplier) >> (32 &- tableBits))
    }

    /// Slot-to-ID table plus the full hash of each ID, built once.
    @usableFromInline
    struct Table: Sendable {
        /// `slots[tableSlot(forHash:)]` is the raw ID of the name in that slot, or 0.
        @usableFromInline let slots: [UInt8]
        /// `hashes[id]` is the FNV-1a hash of the ID's canonical name (0 for ``unknown``).
        @usableFromInline let hashes: [UInt32]

        init() {
            var slots = [UInt8](repeating: 0, count: HTTPFieldName.tableSize)
            let count = HTTPFieldName.allCases.count
            precondition(Int(HTTPFieldName.allCases[count - 1].rawValue) == count - 1 && count <= 128,
                         "HTTPFieldName raw values must be dense and below 128")
            var hashes = [UInt32](repeating: 0, count: count)
            for name in HTTPFieldName.allCases where name.isWellKnown {
                let hash = ASCII.fnv1aLowercased(name.canonicalName)
                let slot = HTTPFieldName.tableSlot(forHash: hash)
                precondition(slots[slot] == 0,
                             "HTTPFieldName table collision: \(name) and \(HTTPFieldName(rawValue: slots[slot])!) share slot \(slot); choose a new tableMultiplier")
                slots[slot] = name.rawValue
                hashes[Int(name.rawValue)] = hash
            }
            self.slots = slots
            self.hashes = hashes
        }
    }

    @usableFromInline static let table = Table()

    /// Resolves a name whose lowercased FNV-1a hash the caller already computed (for example
    /// while scanning for `:`). Returns ``unknown`` for any name that is not well known.
    ///
    /// `name` may be in any case; well-known names match case-insensitively.
    @inlinable
    public static func lookup(hash: UInt32, name: Span<UInt8>) -> HTTPFieldName {
        let table = Self.table
        let id = table.slots[tableSlot(forHash: hash)]
        guard id != 0, table.hashes[Int(id)] == hash,
              let candidate = HTTPFieldName(rawValue: id),
              ASCII.equalsCaseInsensitive(name, candidate.canonicalName)
        else { return .unknown }
        return candidate
    }

    /// Resolves a name, hashing it first.
    @inlinable
    public static func lookup(_ name: Span<UInt8>) -> HTTPFieldName {
        lookup(hash: ASCII.fnv1aLowercased(name), name: name)
    }

    /// Resolves a static name, such as one a handler passes when adding a response field.
    @inlinable
    public static func lookup(_ name: StaticString) -> HTTPFieldName {
        name.withUTF8Buffer { lookup($0.span) }
    }
}

extension HTTPFieldName: CustomStringConvertible {
    public var description: String {
        isWellKnown ? canonicalName.description : "unknown"
    }
}
