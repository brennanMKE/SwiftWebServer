public import HTTPCore

/// Evaluates the preconditions of a request against the selected representation's
/// validators, in the order RFC 9110 §13.2.2 specifies (#0085, #0017, #0019).
///
/// 1. `If-Match` present: false (no listed tag matches by strong comparison, or `*` with no
///    representation) answers `412`.
/// 2. Otherwise `If-Unmodified-Since` with a valid date: modified after it answers `412`.
/// 3. `If-None-Match` present: a match (weak comparison, or `*`) answers `304` for `GET` and
///    `HEAD` and `412` for other methods.
/// 4. Otherwise, for `GET` and `HEAD` only, `If-Modified-Since` with a valid date: not modified
///    since answers `304`.
/// 5. Otherwise the request proceeds; for a `GET` with `Range`, ``ifRangeAllowsRange(fields:etag:lastModified:)``
///    decides whether the range is applied (`If-Range`, RFC 9110 §13.1.5).
///
/// Dates are compared in whole seconds: `lastModified` is the modification time truncated to
/// seconds, the same value rendered in `Last-Modified`, so a client that echoes it back gets
/// `304` even when the file's mtime has a fractional part (#0017). An invalid date, or a
/// date field sent more than once, is ignored (RFC 9110 §13.1.3, §13.1.4).
///
/// Callers apply it only where it applies: RFC 9110 §13.2.1 says preconditions are evaluated
/// after the checks that would give a `4xx` (or another non-`2xx`/`412` status) without them.
///
/// Evaluation allocates nothing: list elements are walked in place and dates are parsed by
/// fixed offsets (``HTTPDate``).
public enum ConditionalRequest {
    /// What the preconditions decided.
    public enum Outcome: Sendable, Hashable {
        /// No precondition stops the request: answer as usual.
        case proceed
        /// `304 Not Modified`.
        case notModified
        /// `412 Precondition Failed`.
        case preconditionFailed
    }

    /// True when any of `If-Match`, `If-None-Match`, `If-Modified-Since` or
    /// `If-Unmodified-Since` is present. `If-Range` is not included: it only matters with `Range`.
    @inlinable
    public static func hasPreconditions(_ fields: some HTTPFieldCollection) -> Bool {
        fields.contains(.ifMatch) || fields.contains(.ifNoneMatch)
            || fields.contains(.ifModifiedSince) || fields.contains(.ifUnmodifiedSince)
    }

    /// Evaluates steps 1-4 for a request with `method` and `fields` whose selected
    /// representation has the entity tag `etag` (quotes included, `W/` prefix if weak) and the
    /// modification time `lastModified` in whole seconds since the epoch. Pass `nil` for a
    /// validator the representation does not have, and `representationExists: false` when
    /// there is none at all (then `If-Match: *` fails and `If-None-Match: *` passes).
    public static func evaluate(method: HTTPMethod, fields: some HTTPFieldCollection,
                                etag: [UInt8]?, lastModified: Int64?,
                                representationExists: Bool = true) -> Outcome {
        let isGetOrHead = method == .get || method == .head
        // Step 1 and 2.
        if fields.contains(.ifMatch) {
            if !listMatches(fields, .ifMatch, etag: etag, exists: representationExists, weak: false) {
                return .preconditionFailed
            }
        } else if let lastModified, let since = singleDate(fields, .ifUnmodifiedSince) {
            if lastModified > since { return .preconditionFailed }
        }
        // Step 3 and 4.
        if fields.contains(.ifNoneMatch) {
            if listMatches(fields, .ifNoneMatch, etag: etag, exists: representationExists, weak: true) {
                return isGetOrHead ? .notModified : .preconditionFailed
            }
        } else if isGetOrHead, let lastModified, let since = singleDate(fields, .ifModifiedSince) {
            if lastModified <= since { return .notModified }
        }
        return .proceed
    }

    /// Step 5: true when a `Range` on this request may be applied, that is when there is no
    /// `If-Range` or its validator names the current representation: the same strong entity
    /// tag (a weak tag never matches), or an HTTP-date equal to `lastModified` (RFC 9110 §13.1.5).
    public static func ifRangeAllowsRange(fields: some HTTPFieldCollection, etag: [UInt8]?,
                                          lastModified: Int64?) -> Bool {
        guard let view = fields.firstValue(for: .ifRange) else { return true }
        return fields.withSpan(of: view) { value in
            var start = 0
            var end = value.count
            while start < end, value[start] == 0x20 || value[start] == 0x09 { start &+= 1 }
            while end > start, value[end &- 1] == 0x20 || value[end &- 1] == 0x09 { end &-= 1 }
            let trimmed = value.extracting(start..<end)
            guard trimmed.count > 0 else { return false }
            if trimmed[0] == UInt8(ascii: "\"") || trimmed[0] == UInt8(ascii: "W") && trimmed.count > 1
                && trimmed[1] == UInt8(ascii: "/") {
                guard let etag else { return false }
                return etag.withUnsafeBufferPointer { tagMatches(trimmed, $0.span, weak: false) }
            }
            guard let lastModified, let date = HTTPDate.parse(trimmed) else { return false }
            return date == lastModified
        }
    }

    // MARK: Entity tags (RFC 9110 §8.8.3)

    /// True when any element of the `name` lists is `*` (and the representation exists) or an
    /// entity tag matching `etag` by strong or weak comparison.
    static func listMatches(_ fields: some HTTPFieldCollection, _ name: HTTPFieldName,
                            etag: [UInt8]?, exists: Bool, weak: Bool) -> Bool {
        var matched = false
        fields.forEachListElement(of: name) { element in
            guard !matched else { return }
            fields.withSpan(of: element) { candidate in
                if candidate.count == 1 && candidate[0] == UInt8(ascii: "*") {
                    matched = exists
                } else if let etag {
                    matched = etag.withUnsafeBufferPointer { tagMatches(candidate, $0.span, weak: weak) }
                }
            }
        }
        return matched
    }

    /// Compares two entity tags. Strong comparison: neither is weak and the opaque tags are
    /// equal. Weak comparison: the opaque tags are equal. A malformed tag matches nothing.
    static func tagMatches(_ a: Span<UInt8>, _ b: Span<UInt8>, weak: Bool) -> Bool {
        guard let ra = opaqueRange(a), let rb = opaqueRange(b) else { return false }
        if !weak && (ra.lowerBound != 0 || rb.lowerBound != 0) { return false }
        guard ra.count == rb.count else { return false }
        var i = ra.lowerBound
        var j = rb.lowerBound
        while i < ra.upperBound {
            if a[i] != b[j] { return false }
            i &+= 1
            j &+= 1
        }
        return true
    }

    /// The range of the quoted opaque tag in `tag` (quotes included), starting at 2 for a weak
    /// tag (`W/` is case-sensitive), or `nil` when `tag` is not `[W/]"<etagc>*"`.
    static func opaqueRange(_ tag: Span<UInt8>) -> Range<Int>? {
        var start = 0
        if tag.count >= 2 && tag[0] == UInt8(ascii: "W") && tag[1] == UInt8(ascii: "/") { start = 2 }
        let end = tag.count
        guard end - start >= 2, tag[start] == UInt8(ascii: "\""), tag[end &- 1] == UInt8(ascii: "\"") else {
            return nil
        }
        for i in (start &+ 1)..<(end &- 1) {
            let c = tag[i]
            // etagc = %x21 / %x23-7E / obs-text
            if c == UInt8(ascii: "\"") || c < 0x21 || c == 0x7F { return nil }
        }
        return start..<end
    }

    // MARK: Dates

    /// The date of `name` when it is sent exactly once and is a valid HTTP-date, else `nil`.
    static func singleDate(_ fields: some HTTPFieldCollection, _ name: HTTPFieldName) -> Int64? {
        guard let view = fields.firstValue(for: name), fields.count(of: name) == 1 else { return nil }
        return fields.withSpan(of: view) { HTTPDate.parse($0) }
    }
}
