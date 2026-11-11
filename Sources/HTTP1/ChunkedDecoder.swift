public import HTTPCore

/// Limits for ``ChunkedDecoder``.
public struct ChunkedDecoderLimits: Sendable, Hashable {
    /// Largest single chunk. A larger chunk-size is rejected before any of its data is read.
    public var maxChunkSize: UInt64
    /// Most bytes of chunk extensions (everything between the size and the CRLF) per chunk.
    public var maxExtensionLength: Int
    /// Most bytes of the trailer section, line endings included, not counting the final CRLF.
    public var maxTrailerBytes: Int
    /// Most trailer fields.
    public var maxTrailerFields: Int

    public static let defaultMaxChunkSize: UInt64 = 1 << 40
    public static let defaultMaxExtensionLength = 1024
    public static let defaultMaxTrailerBytes = 8 * 1024
    public static let defaultMaxTrailerFields = 32

    @inlinable
    public init(
        maxChunkSize: UInt64 = ChunkedDecoderLimits.defaultMaxChunkSize,
        maxExtensionLength: Int = ChunkedDecoderLimits.defaultMaxExtensionLength,
        maxTrailerBytes: Int = ChunkedDecoderLimits.defaultMaxTrailerBytes,
        maxTrailerFields: Int = ChunkedDecoderLimits.defaultMaxTrailerFields
    ) {
        self.maxChunkSize = maxChunkSize
        self.maxExtensionLength = maxExtensionLength
        self.maxTrailerBytes = maxTrailerBytes
        self.maxTrailerFields = maxTrailerFields
    }
}

/// Why a chunked body is invalid (RFC 9112 §7.1).
public enum ChunkedDecodingError: Error, Sendable, Hashable {
    /// The chunk-size is missing or has a byte that is not a hex digit.
    case invalidChunkSize
    /// The chunk-size exceeds ``ChunkedDecoderLimits/maxChunkSize`` (or 64 bits).
    case chunkTooLarge
    /// A chunk extension has a control byte or exceeds ``ChunkedDecoderLimits/maxExtensionLength``.
    case invalidExtension
    /// A CR not followed by LF, a bare LF, or chunk data not followed by CRLF.
    case missingCRLF
    /// A trailer line is not `name: value` (obs-fold included), or the trailer section exceeds
    /// its byte or field limits.
    case invalidTrailer
}

/// Decodes the chunked transfer coding (RFC 9112 §7.1) as a pure state machine.
///
/// Feed it the readable bytes of the receive buffer with ``decode(_:)``; each call returns one
/// ``Step`` saying how many bytes it consumed and what they were. Data is never copied: a
/// ``Step/Kind/data`` step points at the chunk data inside the bytes passed in. The decoder keeps
/// only counters between calls, so any split of the input across calls yields the same data and
/// trailer bytes (split invariance).
///
/// - Chunk extensions are validated (no control bytes, bounded length) and ignored.
/// - The trailer section is validated line by line (`token ":" field-value CRLF`, no obs-fold,
///   bounded bytes and field count) and handed out as raw bytes in ``Step/range`` of
///   ``Step/Kind/needMoreBytes`` and ``Step/Kind/end`` steps; ``parseTrailers(_:)`` turns the
///   collected bytes into ``HTTPFields``.
/// - Strict line endings: a bare LF or a CR without LF is an error.
public struct ChunkedDecoder: Sendable, Hashable {
    /// One result of ``decode(_:)``.
    public struct Step: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// `range` is chunk data. Call again with the bytes after `consumed`.
            case data
            /// Every byte was consumed; `range` holds trailer-section bytes (possibly empty).
            case needMoreBytes
            /// The body ended after `consumed` bytes; `range` holds the last trailer-section bytes
            /// (possibly empty). Bytes after `consumed` belong to the next message.
            case end
            /// The body is malformed. Nothing after the error is meaningful.
            case error(ChunkedDecodingError)
        }

        public var kind: Kind
        /// Bytes consumed from the start of the input.
        public var consumed: Int
        /// The payload within the consumed bytes (data or trailer bytes), relative to the input.
        public var range: Range<Int>

        @inlinable
        public init(kind: Kind, consumed: Int, range: Range<Int>) {
            self.kind = kind
            self.consumed = consumed
            self.range = range
        }
    }

    @usableFromInline
    enum State: Sendable, Hashable {
        /// The first hex digit of a chunk-size.
        case sizeStart
        /// More hex digits, BWS, `;` or CR.
        case size
        /// BWS after the size: only more BWS or `;` may follow.
        case sizeWhitespace
        /// Inside the chunk extensions, until CR.
        case extensions
        /// CR seen after the size line; LF must follow.
        case sizeLF
        /// Chunk data, `remaining` bytes left.
        case data
        /// The CR after chunk data.
        case dataCR
        /// The LF after chunk data.
        case dataLF
        /// The start of a trailer line, or the CR of the final empty line.
        case trailerLineStart
        /// A trailer field name, until `:`.
        case trailerName
        /// A trailer field value, until CR.
        case trailerValue
        /// The LF ending a trailer line.
        case trailerLF
        /// The LF of the final empty line.
        case finalLF
        /// The body ended.
        case done
        /// The body is malformed.
        case failed(ChunkedDecodingError)
    }

    public var limits: ChunkedDecoderLimits
    @usableFromInline var state: State
    @usableFromInline var remaining: UInt64
    @usableFromInline var sizeDigits: Int
    @usableFromInline var extensionLength: Int
    @usableFromInline var trailerBytes: Int
    @usableFromInline var trailerFields: Int
    @usableFromInline var nameLength: Int

    public init(limits: ChunkedDecoderLimits = ChunkedDecoderLimits()) {
        self.limits = limits
        state = .sizeStart
        remaining = 0
        sizeDigits = 0
        extensionLength = 0
        trailerBytes = 0
        trailerFields = 0
        nameLength = 0
    }

    /// Starts a new body with the same limits.
    public mutating func reset() {
        self = ChunkedDecoder(limits: limits)
    }

    /// True once the last chunk and the trailer section were decoded.
    public var isComplete: Bool { state == .done }

    /// Decodes from the start of `bytes`.
    public mutating func decode(_ bytes: Span<UInt8>) -> Step {
        let count = bytes.count
        var i = 0
        var trailerStart = -1
        while i < count {
            switch state {
            case .data:
                let available = UInt64(count &- i)
                let take = Int(min(remaining, available))
                remaining &-= UInt64(take)
                if remaining == 0 { state = .dataCR }
                return Step(kind: .data, consumed: i &+ take, range: i..<(i &+ take))

            case .sizeStart, .size:
                let byte = bytes[i]
                if let digit = ASCII.hexDigitValue(byte) {
                    // 16 hex digits fill 64 bits; leading zeros are allowed but bounded too.
                    if remaining > (UInt64.max >> 4) || sizeDigits >= 32 { return fail(.chunkTooLarge, i) }
                    remaining = remaining << 4 | UInt64(digit)
                    if remaining > limits.maxChunkSize { return fail(.chunkTooLarge, i) }
                    sizeDigits &+= 1
                    state = .size
                } else if state == .sizeStart {
                    return fail(.invalidChunkSize, i)
                } else if byte == 0x0D {
                    state = .sizeLF
                } else if byte == UInt8(ascii: ";") {
                    state = .extensions
                } else if byte == 0x20 || byte == 0x09 {
                    state = .sizeWhitespace
                } else if byte == 0x0A {
                    return fail(.missingCRLF, i)
                } else {
                    return fail(.invalidChunkSize, i)
                }
                i &+= 1

            case .sizeWhitespace:
                let byte = bytes[i]
                if byte == UInt8(ascii: ";") {
                    state = .extensions
                } else if byte != 0x20 && byte != 0x09 {
                    return fail(.invalidChunkSize, i)
                }
                if extensionLength >= limits.maxExtensionLength { return fail(.invalidExtension, i) }
                extensionLength &+= 1
                i &+= 1

            case .extensions:
                // Token, quoted-string and BWS bytes are all field-value characters; anything
                // else (controls, a bare LF) is invalid. The content itself is ignored.
                let byte = bytes[i]
                if byte == 0x0D {
                    state = .sizeLF
                } else if byte == 0x0A {
                    return fail(.missingCRLF, i)
                } else if !ASCII.isFieldValueCharacter(byte) {
                    return fail(.invalidExtension, i)
                } else {
                    if extensionLength >= limits.maxExtensionLength { return fail(.invalidExtension, i) }
                    extensionLength &+= 1
                }
                i &+= 1

            case .sizeLF:
                guard bytes[i] == 0x0A else { return fail(.missingCRLF, i) }
                i &+= 1
                extensionLength = 0
                sizeDigits = 0
                if remaining == 0 {
                    state = .trailerLineStart
                    if trailerStart < 0 { trailerStart = i }
                } else {
                    state = .data
                }

            case .dataCR:
                guard bytes[i] == 0x0D else { return fail(.missingCRLF, i) }
                state = .dataLF
                i &+= 1

            case .dataLF:
                guard bytes[i] == 0x0A else { return fail(.missingCRLF, i) }
                state = .sizeStart
                i &+= 1

            case .trailerLineStart:
                if trailerStart < 0 { trailerStart = i }
                let byte = bytes[i]
                if byte == 0x0D {
                    state = .finalLF
                    i &+= 1
                    continue
                }
                if byte == 0x0A { return fail(.missingCRLF, i) }
                guard ASCII.isTokenCharacter(byte) else { return fail(.invalidTrailer, i) }
                if trailerFields >= limits.maxTrailerFields { return fail(.invalidTrailer, i) }
                trailerFields &+= 1
                nameLength = 0
                state = .trailerName
                // Re-read the byte as part of the name.

            case .trailerName:
                if trailerStart < 0 { trailerStart = i }
                let byte = bytes[i]
                if byte == UInt8(ascii: ":") {
                    guard nameLength > 0 else { return fail(.invalidTrailer, i) }
                    state = .trailerValue
                } else if ASCII.isTokenCharacter(byte) {
                    nameLength &+= 1
                } else {
                    return fail(.invalidTrailer, i)
                }
                if !countTrailerByte() { return fail(.invalidTrailer, i) }
                i &+= 1

            case .trailerValue:
                if trailerStart < 0 { trailerStart = i }
                let byte = bytes[i]
                if byte == 0x0D {
                    state = .trailerLF
                } else if byte == 0x0A {
                    return fail(.missingCRLF, i)
                } else if !ASCII.isFieldValueCharacter(byte) {
                    return fail(.invalidTrailer, i)
                }
                if !countTrailerByte() { return fail(.invalidTrailer, i) }
                i &+= 1

            case .trailerLF:
                if trailerStart < 0 { trailerStart = i }
                guard bytes[i] == 0x0A else { return fail(.missingCRLF, i) }
                if !countTrailerByte() { return fail(.invalidTrailer, i) }
                state = .trailerLineStart
                i &+= 1

            case .finalLF:
                guard bytes[i] == 0x0A else { return fail(.missingCRLF, i) }
                state = .done
                // The trailer bytes end before the final CRLF. With no trailer byte in this
                // call, the final CR arrived in an earlier one.
                let range = trailerStart < 0 ? i..<i : trailerStart..<max(trailerStart, i &- 1)
                return Step(kind: .end, consumed: i &+ 1, range: range)

            case .done:
                return Step(kind: .end, consumed: i, range: i..<i)

            case .failed(let error):
                return Step(kind: .error(error), consumed: i, range: i..<i)
            }
        }
        switch state {
        case .done:
            return Step(kind: .end, consumed: count, range: count..<count)
        case .failed(let error):
            return Step(kind: .error(error), consumed: count, range: count..<count)
        default:
            // A trailing CR of the final line is not trailer content.
            var end = count
            if state == .finalLF { end = max(trailerStart, count &- 1) }
            let start = trailerStart < 0 ? end : trailerStart
            return Step(kind: .needMoreBytes, consumed: count, range: start..<end)
        }
    }

    @inlinable
    mutating func countTrailerByte() -> Bool {
        trailerBytes &+= 1
        return trailerBytes <= limits.maxTrailerBytes
    }

    @inlinable
    mutating func fail(_ error: ChunkedDecodingError, _ position: Int) -> Step {
        state = .failed(error)
        return Step(kind: .error(error), consumed: position, range: position..<position)
    }

    /// Parses a trailer section collected from ``Step/range``s (validated by the decoder) into
    /// fields: `name: value` per CRLF-terminated line, optional whitespace around the value
    /// trimmed.
    public static func parseTrailers(_ section: ByteBuffer) -> HTTPFields {
        var fields = HTTPFields()
        section.withReadableSpan { bytes in
            var lineStart = 0
            var i = 0
            while i < bytes.count {
                guard bytes[i] == 0x0A else { i &+= 1; continue }
                // A line is bytes[lineStart..<i-1] (without CRLF).
                let lineEnd = i &- 1
                var colon = lineStart
                while colon < lineEnd && bytes[colon] != UInt8(ascii: ":") { colon &+= 1 }
                var valueStart = colon &+ 1
                var valueEnd = lineEnd
                while valueStart < valueEnd && (bytes[valueStart] == 0x20 || bytes[valueStart] == 0x09) { valueStart &+= 1 }
                while valueEnd > valueStart && (bytes[valueEnd &- 1] == 0x20 || bytes[valueEnd &- 1] == 0x09) { valueEnd &-= 1 }
                if colon > lineStart && colon < lineEnd {
                    fields.append(name: bytes.extracting(lineStart..<colon), value: bytes.extracting(valueStart..<valueEnd))
                }
                i &+= 1
                lineStart = i
            }
        }
        return fields
    }
}
