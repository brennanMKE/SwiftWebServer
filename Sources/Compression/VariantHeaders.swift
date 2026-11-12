public import HTTPCore

/// Header rules shared by ``Compression`` and precompressed static files: entity tags of
/// encoded variants and `Vary`.
public enum VariantHeaders {
    /// The entity tag of `coding`'s variant of a representation tagged `etag` (quotes
    /// included): a strong `"abc"` becomes `"abc-gz"`, so the variant has a validator of its
    /// own and `If-None-Match` can name exactly the variant a cache holds. A weak tag
    /// (`W/"abc"`) is kept as it is: weak tags already only promise equivalent content.
    /// Returns `nil` for a weak or malformed tag (keep the original).
    public static func variantETag(_ etag: Span<UInt8>, _ coding: ContentCoding) -> ByteBuffer? {
        let count = etag.count
        guard count >= 2, etag[0] == UInt8(ascii: "\""), etag[count &- 1] == UInt8(ascii: "\"") else { return nil }
        var tag = ByteBuffer(capacity: count + 4)
        tag.append(contentsOf: etag.extracting(0..<(count &- 1)))
        tag.append(coding.etagSuffix)
        tag.append(UInt8(ascii: "\""))
        return tag
    }

    /// True when an `If-None-Match` element of `fields` matches `etag` by weak comparison
    /// (RFC 9110 §8.8.3.2: opaque tags equal, `W/` ignored). `*` is not matched here: the
    /// handler that produced the representation answers it.
    public static func ifNoneMatchContains(_ fields: some HTTPFieldCollection, etag: Span<UInt8>) -> Bool {
        guard let wanted = opaque(etag) else { return false }
        var matched = false
        fields.forEachListElement(of: .ifNoneMatch) { element in
            guard !matched else { return }
            fields.withSpan(of: element) { candidate in
                guard let range = opaque(candidate), range.count == wanted.count else { return }
                var i = range.lowerBound
                var j = wanted.lowerBound
                while i < range.upperBound {
                    if candidate[i] != etag[j] { return }
                    i &+= 1
                    j &+= 1
                }
                matched = true
            }
        }
        return matched
    }

    /// The quoted part of `[W/]"…"`, or `nil` when malformed.
    static func opaque(_ tag: Span<UInt8>) -> Range<Int>? {
        var start = 0
        if tag.count >= 2, tag[0] == UInt8(ascii: "W"), tag[1] == UInt8(ascii: "/") { start = 2 }
        guard tag.count &- start >= 2, tag[start] == UInt8(ascii: "\""), tag[tag.count &- 1] == UInt8(ascii: "\"") else {
            return nil
        }
        return start..<tag.count
    }

    /// True when the `Vary` fields already list `Accept-Encoding` (any case) or `*`.
    @inlinable
    public static func varies(_ fields: some HTTPFieldCollection) -> Bool {
        fields.containsListElement("accept-encoding", in: .vary) || fields.containsListElement("*", in: .vary)
    }

    /// True when the `Vary` fields list `Accept-Encoding`: the response was negotiated on
    /// it by whoever produced it (precompressed static files), so it must not be encoded again.
    @inlinable
    public static func negotiated(_ fields: some HTTPFieldCollection) -> Bool {
        fields.containsListElement("accept-encoding", in: .vary)
    }

    /// Appends `Vary: Accept-Encoding` unless `Vary` already covers it.
    @inlinable
    public static func addVary(_ fields: inout HTTPFields) {
        if !varies(fields) { fields.append(.vary, "Accept-Encoding") }
    }
}
