import HTTPCore

/// The outcome of a `Range` header against a representation of known size (RFC 9110 §14).
enum RangeRequest: Equatable {
    /// Serve the whole representation: no usable range (absent, another unit, more than one
    /// range, or a syntax error, all of which RFC 9110 §14.2 lets a server ignore).
    case full
    /// Serve `offset ..< offset + length` with `206`.
    case partial(offset: Int64, length: Int64)
    /// `416` with `Content-Range: bytes */size`.
    case unsatisfiable

    /// Parses `value` (the field value of `Range`) for a representation of `size` bytes.
    ///
    /// Accepts one `bytes=first-last`, `bytes=first-` or `bytes=-suffix` range, with optional
    /// whitespace around it. `last` past the end is clamped. A range that starts at or after
    /// `size`, or a zero-length suffix, is unsatisfiable.
    static func parse(_ value: Span<UInt8>, size: Int64) -> RangeRequest {
        var start = 0
        var end = value.count
        while start < end, value[start] == UInt8(ascii: " ") || value[start] == UInt8(ascii: "\t") { start += 1 }
        while end > start, value[end - 1] == UInt8(ascii: " ") || value[end - 1] == UInt8(ascii: "\t") { end -= 1 }
        let unit: StaticString = "bytes="
        let unitLength = unit.utf8CodeUnitCount
        guard end - start > unitLength,
              ASCII.equalsCaseInsensitive(value.extracting(start..<(start + unitLength)), unit) else { return .full }
        start += unitLength
        while start < end, value[start] == UInt8(ascii: " ") { start += 1 }
        var dash = -1
        for i in start..<end {
            switch value[i] {
            case UInt8(ascii: ","): return .full            // multiple ranges: serve 200
            case UInt8(ascii: "-") where dash < 0: dash = i
            case UInt8(ascii: "0")...UInt8(ascii: "9"): continue
            default: return .full
            }
        }
        guard dash >= 0 else { return .full }
        let firstBytes = value.extracting(start..<dash)
        let lastBytes = value.extracting((dash + 1)..<end)
        if firstBytes.isEmpty {
            // Suffix range: the last N bytes.
            guard let suffix = ASCII.parseDecimal(lastBytes) else { return .full }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            let length = min(Int64(clamping: suffix), size)
            return .partial(offset: size - length, length: length)
        }
        guard let first = ASCII.parseDecimal(firstBytes) else { return .full }
        var last = UInt64(max(size - 1, 0))
        if !lastBytes.isEmpty {
            guard let parsed = ASCII.parseDecimal(lastBytes) else { return .full }
            guard parsed >= first else { return .full }    // invalid range-spec: ignore
            last = min(parsed, last)
        }
        guard first < UInt64(size) else { return .unsatisfiable }
        return .partial(offset: Int64(first), length: Int64(last - first + 1))
    }
}
