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
/// Names resolve through a 512-slot perfect-hash table keyed by the name's length and its
/// lowercased first and last eight bytes, loaded as 64-bit words (``lookup(_:from:to:)``).
/// Resolution costs four unaligned loads with SWAR lowercasing, one multiply, two table loads
/// and one combined compare, with no branch on the name and no per-byte hash (#0112). Every
/// well-known name has its own slot (checked when the table is built and by tests); an
/// unknown name that lands on a well-known slot is rejected by the length and word compares,
/// which cover every byte of the name.
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
    /// Length in bytes of the longest well-known name (`access-control-allow-credentials`).
    /// Longer names resolve to ``unknown`` without touching the table.
    @inlinable public static var maximumWellKnownLength: Int { 32 }

    /// Multiplier that spreads the key word before taking the top ``tableBits`` bits.
    ///
    /// Chosen by search so that every well-known name gets its own slot (a perfect hash).
    /// Adding a name can introduce a collision, which traps when the table is built and fails
    /// `HTTPFieldNameTests.tableIsCollisionFree`; pick a new odd multiplier (or a larger table)
    /// by trying random odd 64-bit values until the test passes.
    @inlinable static var tableMultiplier: UInt64 { 0x384D_A682_48A3_FF77 }

    /// log2 of the table size.
    @inlinable static var tableBits: UInt64 { 9 }

    /// Number of slots in the table (a power of two).
    @inlinable public static var tableSize: Int { 1 << Int(tableBits) }

    /// The table slot for a name of `length` bytes whose lowercased first and last eight
    /// bytes are `first` and `last` (the ``Key`` words `0` and `3`).
    @inlinable
    public static func tableSlot(length: Int, first: UInt64, last: UInt64) -> Int {
        let key = first ^ (last &>> 1) ^ UInt64(truncatingIfNeeded: length)
        return Int(truncatingIfNeeded: (key &* tableMultiplier) &>> (64 &- tableBits))
    }

    /// The table slot a name of 1 to ``maximumWellKnownLength`` bytes hashes to, for tests
    /// and diagnostics.
    public static func tableSlot(for name: Span<UInt8>) -> Int {
        precondition(name.count >= 1 && name.count <= maximumWellKnownLength, "name length outside 1...32")
        let key = Key(name, from: 0, to: name.count)
        return tableSlot(length: name.count, first: key.w0, last: key.w3)
    }

    /// A name of 1 to 32 bytes as four lowercased little-endian words that together cover
    /// every byte: word `k` holds the eight bytes at offset `min(8k, max(length - 8, 0))`, so
    /// word 0 is the first eight bytes and word 3 the last eight. A name under eight bytes is
    /// zero-padded and repeated in all four words. Two names are equal (ignoring ASCII case)
    /// exactly when their lengths and keys are equal.
    @usableFromInline
    struct Key {
        @usableFromInline var w0: UInt64
        @usableFromInline var w1: UInt64
        @usableFromInline var w2: UInt64
        @usableFromInline var w3: UInt64

        @inlinable
        init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
            self.w0 = w0
            self.w1 = w1
            self.w2 = w2
            self.w3 = w3
        }

        /// The key of `bytes[start..<end]`, `1 <= end - start <= 32`, with four unaligned loads
        /// and no branches when eight bytes from `start` are in the span; otherwise byte by
        /// byte (a short name at the very end of a span).
        @inlinable @inline(__always)
        init(_ bytes: Span<UInt8>, from start: Int, to end: Int) {
            let length = end &- start
            // With this, every load below is inside the span, so it skips its own check.
            precondition(start >= 0 && end <= bytes.count, "HTTPFieldName lookup range outside the span")
            if _fastPath(start &+ 8 <= bytes.count) {
                let raw = bytes.bytes
                let tail = Swift.max(length &- 8, 0)
                // Bytes past the name (only when it is under eight bytes) are masked off.
                let mask = length >= 8 ? ~UInt64(0) : ~UInt64(0) &>> UInt64(truncatingIfNeeded: 64 &- 8 &* length)
                @inline(__always) func word(_ offset: Int) -> UInt64 {
                    let w = UInt64(littleEndian: raw.unsafeLoadUnaligned(fromUncheckedByteOffset: start &+ offset, as: UInt64.self))
                    return ASCII.lowercased(word: w & mask)
                }
                self.init(w0: word(0), w1: word(Swift.min(8, tail)), w2: word(Swift.min(16, tail)), w3: word(tail))
            } else {
                // Fewer than eight bytes remain in the span, so the name is under eight bytes.
                var w: UInt64 = 0
                var i = end
                while i > start {
                    i &-= 1
                    w = w &<< 8 | UInt64(bytes[i])
                }
                w = ASCII.lowercased(word: w)
                self.init(w0: w, w1: w, w2: w, w3: w)
            }
        }
    }

    /// One well-known ID's length and ``Key``.
    @usableFromInline
    struct Entry {
        /// Name length in bytes; 0 for ``unknown``, which no name matches.
        @usableFromInline var length: Int
        @usableFromInline var key: Key
        @usableFromInline var name: HTTPFieldName
    }

    /// The well-known name table: slot-to-ID bytes plus one ``Entry`` per ID, built once and
    /// never freed. Plain pointers keep a lookup free of array bounds checks and reference
    /// counting; the slot index is in range by construction (the top ``tableBits`` bits of a
    /// 64-bit product) and IDs come from the table.
    ///
    /// ``HTTPFieldName/lookup(_:from:to:)`` reaches the table through a lazily initialized
    /// global. A parser that resolves many names can copy ``HTTPFieldName/table`` into a
    /// stored property once and call ``lookup(_:from:to:)`` on it, so the hot path loads two
    /// pointers from its own storage instead of checking the global's initialization.
    public struct Table: @unchecked Sendable {
        /// `slots[tableSlot(...)]` is the raw ID of the name in that slot, or 0.
        @usableFromInline let slots: UnsafePointer<UInt8>
        /// `entries[id]` describes the name with raw ID `id`.
        @usableFromInline let entries: UnsafePointer<Entry>

        init() {
            let count = HTTPFieldName.allCases.count
            precondition(Int(HTTPFieldName.allCases[count - 1].rawValue) == count - 1 && count <= 128,
                         "HTTPFieldName raw values must be dense and below 128")
            let slots = UnsafeMutablePointer<UInt8>.allocate(capacity: HTTPFieldName.tableSize)
            slots.initialize(repeating: 0, count: HTTPFieldName.tableSize)
            let entries = UnsafeMutablePointer<Entry>.allocate(capacity: count)
            for name in HTTPFieldName.allCases {
                var entry = Entry(length: 0, key: Key(w0: 0, w1: 0, w2: 0, w3: 0), name: name)
                if name.isWellKnown {
                    // Padded so that the key loads stay inside the buffer for short names.
                    let bytes = name.canonicalName.withUTF8Buffer { Array($0) } + Array(repeating: 0, count: 8)
                    let length = bytes.count - 8
                    precondition(length <= HTTPFieldName.maximumWellKnownLength,
                                 "\(name) is longer than maximumWellKnownLength")
                    let key = bytes.withUnsafeBufferPointer { Key($0.span, from: 0, to: length) }
                    entry = Entry(length: length, key: key, name: name)
                    let slot = HTTPFieldName.tableSlot(length: length, first: key.w0, last: key.w3)
                    precondition(slots[slot] == 0,
                                 "HTTPFieldName table collision: \(name) and \(HTTPFieldName(rawValue: slots[slot])!) share slot \(slot); choose a new tableMultiplier")
                    slots[slot] = name.rawValue
                }
                (entries + Int(name.rawValue)).initialize(to: entry)
            }
            self.slots = UnsafePointer(slots)
            self.entries = UnsafePointer(entries)
        }

        /// Resolves the name in `bytes[start..<end]` case-insensitively; ``unknown`` for any
        /// name that is not well known. See ``HTTPFieldName/lookup(_:from:to:)``.
        @inlinable @inline(__always)
        public func lookup(_ bytes: Span<UInt8>, from start: Int, to end: Int) -> HTTPFieldName {
            let length = end &- start
            // One unsigned compare rejects empty, reversed and over-long ranges.
            guard UInt(bitPattern: length &- 1) < UInt(HTTPFieldName.maximumWellKnownLength) else { return .unknown }
            let key = Key(bytes, from: start, to: end)
            let id = slots[HTTPFieldName.tableSlot(length: length, first: key.w0, last: key.w3)]
            let entry = entries[Int(id)]
            // `unknown` (ID 0) has length 0, so an empty slot never matches.
            let difference = UInt64(bitPattern: Int64(entry.length ^ length))
                | (entry.key.w0 ^ key.w0) | (entry.key.w1 ^ key.w1)
                | (entry.key.w2 ^ key.w2) | (entry.key.w3 ^ key.w3)
            return difference == 0 ? entry.name : .unknown
        }
    }

    /// The well-known name table, built on first use.
    public static let table = Table()

    /// Resolves the name in `bytes[start..<end]` case-insensitively; ``unknown`` for any name
    /// that is not well known.
    ///
    /// This may read up to eight bytes from `start` even when the name is shorter, so a
    /// parser passes the whole receive span and the name's range instead of a slice: the key
    /// is then four unaligned loads with the bytes past the name masked off. Cost: the four
    /// loads, four SWAR lowercases, one multiply, two table loads and one combined compare,
    /// with no branch on the name's length or bytes and no hash of the whole name.
    ///
    /// - Precondition: `0 <= start` and `end <= bytes.count`.
    @inlinable
    public static func lookup(_ bytes: Span<UInt8>, from start: Int, to end: Int) -> HTTPFieldName {
        table.lookup(bytes, from: start, to: end)
    }

    /// Resolves a name; returns ``unknown`` for any name that is not well known.
    ///
    /// `name` may be in any case; well-known names match case-insensitively.
    @inlinable
    public static func lookup(_ name: Span<UInt8>) -> HTTPFieldName {
        lookup(name, from: 0, to: name.count)
    }

    /// Resolves a name. `hash` is ignored: it is the lowercased FNV-1a hash older callers
    /// computed while scanning, which the table no longer needs (#0112). Kept for source
    /// compatibility; prefer ``lookup(_:)`` or ``lookup(_:from:to:)``.
    @inlinable
    public static func lookup(hash: UInt32, name: Span<UInt8>) -> HTTPFieldName {
        lookup(name, from: 0, to: name.count)
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
