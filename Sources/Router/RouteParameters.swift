public import HTTPCore

/// Byte ranges captured while matching, held inline (no allocation).
///
/// Each slot packs an offset and a length (both < 2³²) into one word; bit `i` of
/// ``percentMask`` records that capture `i` contains `%` and needs decoding.
struct Captures: Sendable {
    /// Most parameters (including the wildcard) one pattern may have.
    static let capacity = 8

    var slots: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0)
    var count = 0
    var percentMask: UInt8 = 0

    @inline(__always)
    mutating func push(offset: Int, length: Int, hasPercent: Bool) {
        let packed = UInt64(truncatingIfNeeded: offset) << 32 | UInt64(truncatingIfNeeded: length)
        let index = count
        withUnsafeMutableBytes(of: &slots) { $0.storeBytes(of: packed, toByteOffset: index &* 8, as: UInt64.self) }
        if hasPercent { percentMask |= 1 << UInt8(index) } else { percentMask &= ~(1 << UInt8(index)) }
        count = index &+ 1
    }

    @inline(__always)
    mutating func pop() { count &-= 1 }

    @inline(__always)
    func view(_ index: Int, base: Int) -> ByteView {
        let packed = withUnsafeBytes(of: slots) { $0.load(fromByteOffset: index &* 8, as: UInt64.self) }
        return ByteView(offset: base &+ Int(packed >> 32), length: Int(packed & 0xFFFF_FFFF))
    }
}

/// The names of a route's parameters, in pattern order (shared by every match of the route).
final class ParameterNames: Sendable {
    let names: [String]
    /// Index of the wildcard capture, or -1.
    let wildcardIndex: Int

    init(names: [String], wildcardIndex: Int) {
        self.names = names
        self.wildcardIndex = wildcardIndex
    }
}

/// Path parameters captured by a route match (#0094).
///
/// Captures are byte ranges in the request's path, recorded during matching without
/// allocating. Converting one to a `String` (``subscript(_:)``) allocates and percent-decodes
/// it, only if the captured bytes contain `%`. ``withBytes(_:_:)`` reads the raw bytes without
/// allocating. Like the request, the parameters are valid only while the handler runs.
public struct RouteParameters: Sendable {
    let nameTable: ParameterNames?
    let source: HTTPFieldsView?
    let base: Int
    let captures: Captures

    init(names: ParameterNames?, source: HTTPFieldsView?, base: Int, captures: Captures) {
        self.nameTable = names
        self.source = source
        self.base = base
        self.captures = captures
    }

    /// No parameters.
    public init() {
        self.init(names: nil, source: nil, base: 0, captures: Captures())
    }

    /// Number of captured parameters, the wildcard included.
    public var count: Int { nameTable == nil ? 0 : captures.count }

    /// True when nothing was captured.
    public var isEmpty: Bool { count == 0 }

    /// Parameter names in pattern order (a wildcard is `*` unless named).
    public var names: [String] { nameTable.map { Array($0.names.prefix(captures.count)) } ?? [] }

    /// The position of the parameter called `name`, or `nil`.
    public func index(of name: String) -> Int? {
        guard let names = nameTable else { return nil }
        for i in 0..<min(names.names.count, captures.count) where names.names[i] == name { return i }
        return nil
    }

    /// The percent-decoded value of the parameter called `name`, or `nil`. Allocates.
    public subscript(_ name: String) -> String? {
        guard let i = index(of: name) else { return nil }
        return value(at: i)
    }

    /// The percent-decoded value of the parameter at `index` (pattern order). Allocates.
    public func value(at index: Int) -> String {
        precondition(index >= 0 && index < count, "parameter index \(index) out of range")
        let view = captures.view(index, base: base)
        let decode = captures.percentMask & (1 << UInt8(index)) != 0
        return source!.withSpan(of: view) { bytes in
            decode ? RouteParameters.percentDecoded(bytes) : ASCII.string(from: bytes)
        }
    }

    /// The raw (still percent-encoded) value of the parameter called `name`. Allocates.
    public func rawValue(_ name: String) -> String? {
        guard let i = index(of: name) else { return nil }
        return source!.string(of: captures.view(i, base: base))
    }

    /// The captured range of the parameter called `name` in the request buffer (see
    /// ``HTTPRequest/withSpan(of:_:)``).
    public func view(_ name: String) -> ByteView? {
        index(of: name).map { captures.view($0, base: base) }
    }

    /// True when the parameter called `name` contains `%` (so ``subscript(_:)`` decodes it).
    public func isPercentEncoded(_ name: String) -> Bool {
        guard let i = index(of: name) else { return false }
        return captures.percentMask & (1 << UInt8(i)) != 0
    }

    /// Calls `body` with the raw bytes of the parameter called `name`, or returns `nil`.
    /// Does not allocate.
    public func withBytes<R, E: Error>(_ name: String, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R? {
        guard let i = index(of: name), let source else { return nil }
        return try source.withSpan(of: captures.view(i, base: base), body)
    }

    /// The parameter called `name` as an unsigned decimal integer, or `nil` (missing, not
    /// digits, or overflow). Does not allocate.
    public func decimal(_ name: String) -> UInt64? {
        withBytes(name) { ASCII.parseDecimal($0) } ?? nil
    }

    /// The decoded remainder captured by a trailing wildcard, or `nil` when the route has none.
    public var wildcard: String? {
        guard let names = nameTable, names.wildcardIndex >= 0, names.wildcardIndex < captures.count else { return nil }
        return value(at: names.wildcardIndex)
    }

    /// Decodes `%XX` escapes; a malformed escape is kept as written. `+` is not a space in a
    /// path. Invalid UTF-8 after decoding becomes U+FFFD.
    static func percentDecoded(_ bytes: Span<UInt8>) -> String {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "%"), i + 2 < bytes.count,
               let high = ASCII.hexDigitValue(bytes[i + 1]), let low = ASCII.hexDigitValue(bytes[i + 2]) {
                output.append(high << 4 | low)
                i += 3
            } else {
                output.append(byte)
                i += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// The context a ``RouteHandler`` receives: the request's ``RequestContext`` plus the
/// captured ``params``. Members of `RequestContext` (`connection`, `startTime`) read through.
@dynamicMemberLookup
public struct RouteContext: Sendable {
    /// The context the router received.
    public var requestContext: RequestContext
    /// The path parameters of the matched route.
    public let params: RouteParameters

    public init(requestContext: RequestContext, params: RouteParameters) {
        self.requestContext = requestContext
        self.params = params
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<RequestContext, T>) -> T {
        requestContext[keyPath: keyPath]
    }

    /// A typed value a component set (see ``RequestContextKey``).
    public subscript<Key: RequestContextKey>(key: Key.Type) -> Key.Value {
        requestContext[key]
    }

    /// ``requestContext`` with ``params`` set as ``RequestContext/routeParameters``, to hand to
    /// an ``HTTPHandler``. Costs one small allocation (one context value).
    public var requestContextWithParameters: RequestContext {
        var context = requestContext
        context[RouteParametersKey.self] = params
        return context
    }
}

/// The ``RequestContext`` key under which routes served by an ``HTTPHandler`` find their
/// parameters.
public enum RouteParametersKey: RequestContextKey {
    public static var defaultValue: RouteParameters? { nil }
}

extension RequestContext {
    /// The parameters of the route that matched, when the route is served by an
    /// ``HTTPHandler`` (closure routes read ``RouteContext/params``).
    public var routeParameters: RouteParameters? { self[RouteParametersKey.self] }
}
