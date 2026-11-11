/// A request method (RFC 9110 §9).
///
/// The standard methods are cases; any other token is ``other(_:)`` holding its bytes inline,
/// so a method never allocates and never needs the receive buffer to outlive the request.
/// Methods are case-sensitive (RFC 9110 §9.1): `get` is an extension method, not ``get``.
///
/// ``init(_:)`` parses by word compare: up to eight bytes are packed into one `UInt64` and
/// matched against constants, so recognizing `GET` is a load, a few shifts and a compare
/// (docs/ROADMAP.md §7, "method enum by word compare").
public enum HTTPMethod: Sendable, Hashable {
    case get
    case head
    case post
    case put
    case delete
    case connect
    case options
    case trace
    case patch
    /// An extension method token such as `PROPFIND`.
    case other(Token)

    /// An extension method token of 1 to ``maximumLength`` `tchar` bytes, stored inline.
    public struct Token: Sendable, Hashable {
        /// Longest extension method accepted. Longer methods are rejected by the parser
        /// (501 Not Implemented); every registered method in the IANA registry fits.
        public static let maximumLength = 24

        @usableFromInline let lane0: UInt64
        @usableFromInline let lane1: UInt64
        @usableFromInline let lane2: UInt64
        /// Number of bytes.
        public let count: Int

        @inlinable
        init(lane0: UInt64, lane1: UInt64, lane2: UInt64, count: Int) {
            self.lane0 = lane0
            self.lane1 = lane1
            self.lane2 = lane2
            self.count = count
        }

        /// Packs `bytes` if it is a valid token of at most ``maximumLength`` bytes.
        @inlinable
        public init?(_ bytes: Span<UInt8>) {
            guard let packed = HTTPMethod.pack(bytes) else { return nil }
            self = packed
        }

        /// Packs a static token, for tests and handlers that compare against a custom method.
        @inlinable
        public init?(_ literal: StaticString) {
            guard let token = literal.withUTF8Buffer({ Token($0.span) }) else { return nil }
            self = token
        }

        /// The byte at `position` (`0..<count`).
        @inlinable
        public subscript(position: Int) -> UInt8 {
            precondition(position >= 0 && position < count, "Token index \(position) out of range")
            let lane = position < 8 ? lane0 : position < 16 ? lane1 : lane2
            return UInt8(truncatingIfNeeded: lane >> UInt64((position & 7) &* 8))
        }

        /// Appends the token bytes to `buffer`.
        @inlinable
        public func append(to buffer: inout ByteBuffer) {
            for i in 0..<count { buffer.append(self[i]) }
        }
    }

    // MARK: Word constants

    // Little-endian packing of the method bytes, zero padded: "GET" is 0x54_45_47.
    @usableFromInline static let wordGET: UInt64 = 0x0054_4547
    @usableFromInline static let wordHEAD: UInt64 = 0x4441_4548
    @usableFromInline static let wordPOST: UInt64 = 0x5453_4F50
    @usableFromInline static let wordPUT: UInt64 = 0x0054_5550
    @usableFromInline static let wordDELETE: UInt64 = 0x4554_454C_4544
    @usableFromInline static let wordCONNECT: UInt64 = 0x0054_4345_4E4E_4F43
    @usableFromInline static let wordOPTIONS: UInt64 = 0x0053_4E4F_4954_504F
    @usableFromInline static let wordTRACE: UInt64 = 0x45_4341_5254
    @usableFromInline static let wordPATCH: UInt64 = 0x48_4354_4150

    /// Packs up to 24 token bytes into three little-endian lanes, or `nil` if `bytes` is
    /// empty, too long or contains a non-`tchar` byte.
    @inlinable
    static func pack(_ bytes: Span<UInt8>) -> Token? {
        let count = bytes.count
        guard count > 0, count <= Token.maximumLength else { return nil }
        var lanes: (UInt64, UInt64, UInt64) = (0, 0, 0)
        for i in 0..<count {
            let byte = bytes[i]
            guard ASCII.isTokenCharacter(byte) else { return nil }
            let shifted = UInt64(byte) << UInt64((i & 7) &* 8)
            switch i >> 3 {
            case 0: lanes.0 |= shifted
            case 1: lanes.1 |= shifted
            default: lanes.2 |= shifted
            }
        }
        return Token(lane0: lanes.0, lane1: lanes.1, lane2: lanes.2, count: count)
    }

    // MARK: Parsing

    /// Parses a method token such as the first word of a request line or an HTTP/2 `:method`
    /// value. Returns `nil` for an empty, over-long or non-token input.
    @inlinable
    public init?(_ bytes: Span<UInt8>) {
        guard let token = HTTPMethod.pack(bytes) else { return nil }
        self.init(token: token)
    }

    /// Parses a static method name.
    @inlinable
    public init?(_ literal: StaticString) {
        guard let method = literal.withUTF8Buffer({ HTTPMethod($0.span) }) else { return nil }
        self = method
    }

    /// Classifies a packed token: a standard method if its single word matches, otherwise
    /// ``other(_:)``.
    @inlinable
    public init(token: Token) {
        guard token.count <= 7 else {
            self = .other(token)
            return
        }
        switch token.lane0 {
        case HTTPMethod.wordGET: self = .get
        case HTTPMethod.wordHEAD: self = .head
        case HTTPMethod.wordPOST: self = .post
        case HTTPMethod.wordPUT: self = .put
        case HTTPMethod.wordDELETE: self = .delete
        case HTTPMethod.wordCONNECT: self = .connect
        case HTTPMethod.wordOPTIONS: self = .options
        case HTTPMethod.wordTRACE: self = .trace
        case HTTPMethod.wordPATCH: self = .patch
        default: self = .other(token)
        }
    }

    // MARK: Rendering

    /// The method name of a standard method, or `nil` for ``other(_:)``.
    @inlinable
    public var standardName: StaticString? {
        switch self {
        case .get: "GET"
        case .head: "HEAD"
        case .post: "POST"
        case .put: "PUT"
        case .delete: "DELETE"
        case .connect: "CONNECT"
        case .options: "OPTIONS"
        case .trace: "TRACE"
        case .patch: "PATCH"
        case .other: nil
        }
    }

    /// Appends the method bytes to `buffer`.
    @inlinable
    public func append(to buffer: inout ByteBuffer) {
        if let name = standardName {
            buffer.append(name)
        } else if case .other(let token) = self {
            token.append(to: &buffer)
        }
    }

    /// The standard methods, in RFC 9110 order followed by PATCH (RFC 5789).
    public static let standardMethods: [HTTPMethod] = [
        .get, .head, .post, .put, .delete, .connect, .options, .trace, .patch,
    ]
}

extension HTTPMethod: CustomStringConvertible {
    public var description: String {
        var buffer = ByteBuffer(capacity: 24)
        append(to: &buffer)
        return buffer.withReadableSpan { ASCII.string(from: $0) }
    }
}

extension HTTPMethod.Token: CustomStringConvertible {
    public var description: String {
        HTTPMethod.other(self).description
    }
}
