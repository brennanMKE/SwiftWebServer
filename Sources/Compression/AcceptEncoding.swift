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
    public static func negotiate(_ fields: some HTTPFieldCollection, available: ContentCodingSet) -> ContentCoding? {
        guard !available.isEmpty, fields.contains(.acceptEncoding) else { return nil }
        return select(weights(fields), available: available)
    }

    /// The choice for already parsed `weights`.
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
    public static func weights(_ fields: some HTTPFieldCollection) -> Weights {
        var weights = Weights()
        fields.forEachListElement(of: .acceptEncoding) { element in
            fields.withSpan(of: element) { parse($0, into: &weights) }
        }
        return weights
    }

    /// The weights of one header value such as `br;q=1.0, gzip;q=0.8, *;q=0` (for tests and
    /// callers holding raw bytes).
    public static func weights(value: Span<UInt8>) -> Weights {
        var weights = Weights()
        var start = 0
        var i = 0
        while i <= value.count {
            if i == value.count || value[i] == UInt8(ascii: ",") {
                var lo = start
                var hi = i
                while lo < hi, value[lo] == 0x20 || value[lo] == 0x09 { lo &+= 1 }
                while hi > lo, value[hi &- 1] == 0x20 || value[hi &- 1] == 0x09 { hi &-= 1 }
                if hi > lo { parse(value.extracting(lo..<hi), into: &weights) }
                start = i &+ 1
            }
            i &+= 1
        }
        return weights
    }

    /// Applies one list element, `coding *( OWS ";" OWS parameter )`.
    static func parse(_ element: Span<UInt8>, into weights: inout Weights) {
        var end = 0
        while end < element.count, element[end] != UInt8(ascii: ";") { end &+= 1 }
        var tokenEnd = end
        while tokenEnd > 0, element[tokenEnd &- 1] == 0x20 || element[tokenEnd &- 1] == 0x09 { tokenEnd &-= 1 }
        let token = element.extracting(0..<tokenEnd)
        var weight: Int16 = 1000
        // Parameters: only `q` matters; the last one given wins.
        var i = end
        while i < element.count {
            // At a ";": skip it and OWS, then read `name=value` up to the next ";".
            i &+= 1
            while i < element.count, element[i] == 0x20 || element[i] == 0x09 { i &+= 1 }
            var paramEnd = i
            while paramEnd < element.count, element[paramEnd] != UInt8(ascii: ";") { paramEnd &+= 1 }
            var valueEnd = paramEnd
            while valueEnd > i, element[valueEnd &- 1] == 0x20 || element[valueEnd &- 1] == 0x09 { valueEnd &-= 1 }
            let parameter = element.extracting(i..<valueEnd)
            if parameter.count >= 2, parameter[0] | 0x20 == UInt8(ascii: "q") {
                var j = 1
                while j < parameter.count, parameter[j] == 0x20 || parameter[j] == 0x09 { j &+= 1 }
                guard j < parameter.count, parameter[j] == UInt8(ascii: "=") else { return }
                j &+= 1
                while j < parameter.count, parameter[j] == 0x20 || parameter[j] == 0x09 { j &+= 1 }
                guard let q = qvalue(parameter.extracting(j..<parameter.count)) else { return }
                weight = q
            }
            i = paramEnd
        }
        func keep(_ slot: inout Int16) { if weight > slot { slot = weight } }
        if ASCII.equalsCaseInsensitive(token, "br") {
            keep(&weights.brotli)
        } else if ASCII.equalsCaseInsensitive(token, "gzip") || ASCII.equalsCaseInsensitive(token, "x-gzip") {
            keep(&weights.gzip)
        } else if ASCII.equalsCaseInsensitive(token, "deflate") {
            keep(&weights.deflate)
        } else if ASCII.equalsCaseInsensitive(token, "identity") {
            keep(&weights.identity)
        } else if token.count == 1, token[0] == UInt8(ascii: "*") {
            keep(&weights.any)
        }
    }

    /// `qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )` in thousandths, or `nil`.
    static func qvalue(_ bytes: Span<UInt8>) -> Int16? {
        guard bytes.count >= 1, bytes.count <= 5 else { return nil }
        let first = bytes[0]
        guard first == UInt8(ascii: "0") || first == UInt8(ascii: "1") else { return nil }
        var value = Int16(first &- UInt8(ascii: "0")) &* 1000
        guard bytes.count > 1 else { return value }
        guard bytes[1] == UInt8(ascii: ".") else { return nil }
        var scale: Int16 = 100
        for i in 2..<bytes.count {
            let digit = bytes[i]
            guard ASCII.isDigit(digit) else { return nil }
            value &+= Int16(digit &- UInt8(ascii: "0")) &* scale
            scale /= 10
        }
        return value <= 1000 ? value : nil
    }
}
