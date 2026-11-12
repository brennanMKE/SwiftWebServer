public import HTTPCore

/// Content negotiation on `Accept-Encoding` (RFC 9110 §12.5.3).
///
/// - Each coding's weight is its own entry's `q`, else the `*` entry's, else 0 (not
///   acceptable). Entries with a malformed `q` are ignored; a coding listed twice keeps the
///   highest weight. `x-gzip` is `gzip`.
/// - The coding with the highest weight above 0 wins; equal weights go to the server's
///   preference, `br` > `gzip` > `deflate` (``ContentCoding``).
/// - `identity` wins only when it is listed with a higher weight than the best coding. When
///   no coding is acceptable the response is sent unencoded, even under `identity;q=0`
///   (RFC 9110 allows `415`, but an unencoded body is what every client can read).
/// - No `Accept-Encoding` field: unencoded.
///
/// Parsing walks the field bytes in place and allocates nothing.
public enum AcceptEncoding {
    /// Weights in thousandths (`q=0.5` is 500); -1 when not listed.
    public struct Weights: Sendable, Hashable {
        public var brotli: Int16 = -1
        public var gzip: Int16 = -1
        public var deflate: Int16 = -1
        public var identity: Int16 = -1
        public var any: Int16 = -1

        public init() {}

        /// The weight of `coding`: its own entry, else `*`, else 0.
        @inlinable
        public func weight(of coding: ContentCoding) -> Int16 {
            let own: Int16
            switch coding {
            case .brotli: own = brotli
            case .gzip: own = gzip
            case .deflate: own = deflate
            }
            if own >= 0 { return own }
            return any >= 0 ? any : 0
        }
    }

    /// The coding to apply for a request with `fields`, chosen among `available`, or `nil`
    /// to send the representation unencoded.
    @inlinable
    public static func negotiate(_ fields: some HTTPFieldCollection, available: ContentCodingSet) -> ContentCoding? {
        guard !available.isEmpty, fields.contains(.acceptEncoding) else { return nil }
        return select(weights(fields), available: available)
    }

    /// The choice for already parsed `weights`.
    @inlinable
    public static func select(_ weights: Weights, available: ContentCodingSet) -> ContentCoding? {
        var best: ContentCoding?
        var bestWeight: Int16 = 0
        for coding in ContentCoding.allCases where available.contains(coding) {
            let weight = weights.weight(of: coding)
            if weight > bestWeight {
                best = coding
                bestWeight = weight
            }
        }
        guard let best else { return nil }
        if weights.identity > bestWeight { return nil }
        return best
    }

    /// The weights listed in every `Accept-Encoding` field of `fields`.
    @inlinable
    public static func weights(_ fields: some HTTPFieldCollection) -> Weights {
        // One pass over each field's bytes (no closure per element): this runs on every
        // cached-variant hit.
        fields.withFieldStorage { index, arena in
            var weights = Weights()
            var position = 0
            while let i = index.firstIndex(of: .acceptEncoding, from: position) {
                arena.withSpan(of: index.valueViews[i]) { scan($0, into: &weights) }
                position = i &+ 1
            }
            return weights
        }
    }

    /// The weights of one header value such as `br;q=1.0, gzip;q=0.8, *;q=0` (for tests and
    /// callers holding raw bytes).
    public static func weights(value: Span<UInt8>) -> Weights {
        var weights = Weights()
        scan(value, into: &weights)
        return weights
    }

    /// Applies every comma-separated element of one field value:
    /// `coding *( OWS ";" OWS name [ OWS "=" OWS value ] )`. Only the `q` parameter counts; an
    /// element whose `q` is malformed, or with stray bytes, is ignored.
    @usableFromInline
    static func scan(_ value: Span<UInt8>, into weights: inout Weights) {
        value.withUnsafeBufferPointer { scan($0, into: &weights) }
    }

    @usableFromInline
    static func scan(_ p: UnsafeBufferPointer<UInt8>, into weights: inout Weights) {
        let n = p.count
        var i = 0
        @inline(__always) func isOWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
        while i < n {
            var c = p[i]
            if isOWS(c) || c == UInt8(ascii: ",") {
                i &+= 1
                continue
            }
            // The coding token, packed little-endian with the ASCII case bit set (see `pack`).
            var packed: UInt64 = 0
            var length = 0
            while i < n {
                c = p[i]
                if c == UInt8(ascii: ";") || c == UInt8(ascii: ",") || isOWS(c) { break }
                if length < 8 { packed |= UInt64(c | 0x20) &<< UInt64(length &* 8) }
                length &+= 1
                i &+= 1
            }
            var weight: Int16 = 1000
            var valid = length <= 8
            // Parameters up to the next comma.
            while i < n, p[i] != UInt8(ascii: ",") {
                c = p[i]
                if isOWS(c) {
                    i &+= 1
                    continue
                }
                guard c == UInt8(ascii: ";") else {
                    valid = false
                    i &+= 1
                    continue
                }
                i &+= 1
                while i < n, isOWS(p[i]) { i &+= 1 }
                let nameStart = i
                while i < n, p[i] != UInt8(ascii: "="), p[i] != UInt8(ascii: ";"), p[i] != UInt8(ascii: ","), !isOWS(p[i]) {
                    i &+= 1
                }
                let isQ = i &- nameStart == 1 && p[nameStart] | 0x20 == UInt8(ascii: "q")
                while i < n, isOWS(p[i]) { i &+= 1 }
                guard i < n, p[i] == UInt8(ascii: "=") else {
                    if isQ { valid = false }
                    continue
                }
                i &+= 1
                while i < n, isOWS(p[i]) { i &+= 1 }
                let valueStart = i
                while i < n, p[i] != UInt8(ascii: ";"), p[i] != UInt8(ascii: ","), !isOWS(p[i]) { i &+= 1 }
                if isQ {
                    if let q = qvalue(UnsafeBufferPointer(rebasing: p[valueStart..<i])) {
                        weight = q
                    } else {
                        valid = false
                    }
                }
            }
            guard valid else { continue }
            // Constants are `pack` of each token (checked by the tests).
            switch packed {
            case 0x2A: weights.any = max(weights.any, weight)                                   // *
            case 0x7262: weights.brotli = max(weights.brotli, weight)                          // br
            case 0x7069_7A67, 0x7069_7A67_2D78: weights.gzip = max(weights.gzip, weight)       // gzip, x-gzip
            case 0x65_7461_6C66_6564: weights.deflate = max(weights.deflate, weight)           // deflate
            case 0x7974_6974_6E65_6469: weights.identity = max(weights.identity, weight)       // identity
            default: break
            }
        }
    }

    /// `literal` (lowercase, at most 8 bytes) packed as ``parse(_:into:)`` packs tokens.
    @usableFromInline @inline(__always)
    static func pack(_ literal: StaticString) -> UInt64 {
        var packed: UInt64 = 0
        let base = literal.utf8Start
        for k in 0..<literal.utf8CodeUnitCount { packed |= UInt64(base[k] | 0x20) &<< UInt64(k &* 8) }
        return packed
    }

    /// `qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )` in thousandths, or `nil`.
    @usableFromInline
    static func qvalue(_ bytes: UnsafeBufferPointer<UInt8>) -> Int16? {
        guard bytes.count >= 1, bytes.count <= 5 else { return nil }
        let first = bytes[0]
        guard first == UInt8(ascii: "0") || first == UInt8(ascii: "1") else { return nil }
        var value = Int16(first &- UInt8(ascii: "0")) &* 1000
        guard bytes.count > 1 else { return value }
        guard bytes[1] == UInt8(ascii: ".") else { return nil }
        var scale: Int16 = 100
        for i in 2..<bytes.count {
            let digit = bytes[i]
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
            value &+= Int16(digit &- UInt8(ascii: "0")) &* scale
            scale /= 10
        }
        return value <= 1000 ? value : nil
    }
}
