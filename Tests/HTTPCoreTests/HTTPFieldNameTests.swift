import Testing
import HTTPCore

@Suite struct HTTPFieldNameTests {
    static let wellKnown = HTTPFieldName.allCases.filter(\.isWellKnown)

    @Test func rawValuesAreDenseAndBelow128() {
        #expect(HTTPFieldName.unknown.rawValue == 0)
        for (i, name) in HTTPFieldName.allCases.enumerated() {
            #expect(Int(name.rawValue) == i)
        }
        #expect(HTTPFieldName.allCases.count <= 128)
    }

    @Test func canonicalNamesAreLowercaseTokensAndUnique() {
        var seen = Set<String>()
        for name in Self.wellKnown {
            let text = name.canonicalName.description
            #expect(!text.isEmpty)
            #expect(text == text.lowercased(), "\(text)")
            let body = name.isPseudoHeader ? text.utf8.dropFirst() : text.utf8[...]
            #expect(body.allSatisfy { ASCII.isTokenCharacter($0) }, "\(text)")
            #expect(name.isPseudoHeader == text.hasPrefix(":"))
            #expect(seen.insert(text).inserted, "duplicate canonical name \(text)")
        }
    }

    @Test func roadmapRequiredNamesAreWellKnown() {
        let required: [StaticString] = [
            "host", "content-length", "transfer-encoding", "connection", "te", "expect", "date",
            "content-type", "if-none-match", "if-modified-since", "range", "accept-encoding",
            "upgrade", "sec-websocket-key", "sec-websocket-version", "sec-websocket-accept",
            "sec-websocket-protocol", "sec-websocket-extensions",
        ]
        for name in required {
            #expect(HTTPFieldName.lookup(name).isWellKnown, "\(name)")
        }
    }

    /// Every well-known name owns a distinct slot of the power-of-two table (a perfect hash)
    /// and fits the key.
    @Test func tableIsCollisionFree() {
        #expect(HTTPFieldName.tableSize.nonzeroBitCount == 1)
        var slots: [Int: HTTPFieldName] = [:]
        for name in Self.wellKnown {
            #expect(name.canonicalName.utf8CodeUnitCount <= HTTPFieldName.maximumWellKnownLength, "\(name)")
            let slot = Self.slot(name.canonicalName.description)
            #expect(slot >= 0 && slot < HTTPFieldName.tableSize)
            if let other = slots[slot] {
                Issue.record("\(name) collides with \(other) in slot \(slot)")
            }
            slots[slot] = name
        }
        #expect(slots.count == Self.wellKnown.count)
        #expect(Self.wellKnown.map { $0.canonicalName.utf8CodeUnitCount }.max() == HTTPFieldName.maximumWellKnownLength)
    }

    @Test func everyWellKnownNameResolvesInAnyCase() {
        for name in Self.wellKnown {
            let lower = name.canonicalName.description
            for variant in [lower, lower.uppercased(), Self.alternatingCase(lower)] {
                var bytes = Array(variant.utf8)
                let resolved = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup($0.span) }
                #expect(resolved == name, "\(variant)")
                let viaHash = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup(hash: 0, name: $0.span) }
                #expect(viaHash == name, "\(variant)")
            }
        }
    }

    /// A name inside a larger span resolves from its range alone, whatever surrounds it: the
    /// key loads read past a short name (masked off) or, at the very end of the span, byte by
    /// byte. Covers both load paths for every well-known name.
    @Test func everyWellKnownNameResolvesInsideALargerSpan() {
        for name in Self.wellKnown {
            let body = Array(Self.alternatingCase(name.canonicalName.description).utf8)
            for prefix in [0, 1, 7, 13] {
                for suffix in [0, 1, 3, 7, 8, 20] {
                    for filler: UInt8 in [0x00, 0x3A, 0x41, 0xFF] {
                        var bytes = Array(repeating: filler, count: prefix) + body + Array(repeating: filler, count: suffix)
                        let resolved = bytes.withUnsafeMutableBufferPointer {
                            HTTPFieldName.lookup($0.span, from: prefix, to: prefix + body.count)
                        }
                        #expect(resolved == name, "\(name) prefix \(prefix) suffix \(suffix) filler \(filler)")
                    }
                }
            }
        }
    }

    @Test func unknownNamesResolveToUnknown() {
        for name: StaticString in ["x-custom", "content-lengthx", "hos", "", "contentlength", "content_length", ":foo",
                                   "access-control-allow-credentialsx", "ccess-control-allow-credentials"] {
            #expect(HTTPFieldName.lookup(name) == .unknown, "\(name)")
        }
        // Empty, reversed and over-long ranges.
        var bytes = Array("host: access-control-allow-credentials-and-more".utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            let span = buffer.span
            #expect(HTTPFieldName.lookup(span, from: 2, to: 2) == .unknown)
            #expect(HTTPFieldName.lookup(span, from: 4, to: 0) == .unknown)
            #expect(HTTPFieldName.lookup(span, from: 6, to: 6 + 33) == .unknown)
            #expect(HTTPFieldName.lookup(span, from: 6, to: 6 + 32) == .accessControlAllowCredentials)
            #expect(HTTPFieldName.lookup(span, from: 0, to: 4) == .host)
        }
    }

    /// Changing any one byte of a well-known name gives an unknown name, unless the change is
    /// a letter's case. The replacements include each byte's case partner (`c ^ 0x20`), which
    /// for `-`, digits and `:` is a control byte, and the bytes around the letter ranges, so a
    /// lowercasing or compare that is not exact per byte would match one of them.
    @Test func everySingleByteChangeOfAWellKnownNameIsRejected() {
        var checked = 0
        for name in Self.wellKnown {
            let canonical = Array(name.canonicalName.description.utf8)
            for position in canonical.indices {
                let original = canonical[position]
                let replacements: Set<UInt8> = [original ^ 0x20, original ^ 0x01, original &+ 0x80, 0x00, 0x2D, 0x40, 0x5B,
                                                0x5E, 0x5F, 0x60, 0x7B, 0x7E, 0x7F, 0x41, 0x5A, 0x61, 0x7A]
                for replacement in replacements where replacement != original {
                    var bytes = canonical
                    bytes[position] = replacement
                    let resolved = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup($0.span) }
                    let isCaseChange = ASCII.lowercased(replacement) == original
                    #expect(resolved == (isCaseChange ? name : .unknown),
                            "\(name) byte \(position) -> \(replacement): \(resolved)")
                    checked += 1
                }
            }
        }
        #expect(checked > 15_000)
    }

    /// Unknown names that land on a well-known name's slot (collisions in the perfect hash)
    /// are rejected by the length and word compares, including ones with the same length and
    /// the same first and last eight bytes as a well-known name.
    @Test func unknownNameInOccupiedSlotIsRejected() {
        let occupied = Set(Self.wellKnown.map { Self.slot($0.canonicalName.description) })
        var found = 0
        for i in 0..<100_000 where found < 50 {
            let probe = "x-probe-\(i)"
            guard occupied.contains(Self.slot(probe)) else { continue }
            found += 1
            #expect(Self.lookup(probe) == .unknown, "\(probe)")
        }
        #expect(found == 50)
        // These differ from a well-known name only in the middle words, so they hash to that
        // name's slot and only the middle compares reject them.
        let siblings: [(String, HTTPFieldName)] = [
            ("access-cXXXXXXXXXXXXXXXXdentials", .accessControlAllowCredentials),
            ("access-cXXXXXXXXXXXX-headers", .accessControlAllowHeaders),
            ("sec-websXXXXXXXXtensions", .secWebSocketExtensions),
            ("if-unmodXXXed-since", .ifUnmodifiedSince),
        ]
        for (probe, sibling) in siblings {
            #expect(probe.utf8.count == sibling.canonicalName.utf8CodeUnitCount, "\(probe)")
            #expect(Self.slot(probe) == Self.slot(sibling.canonicalName.description), "\(probe)")
            #expect(Self.lookup(probe) == .unknown, "\(probe)")
        }
    }

    /// The precomputed hash argument is ignored (#0112): only the bytes decide.
    @Test func hashArgumentIsIgnored() {
        var bytes = Array("host".utf8)
        let resolved = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup(hash: 12345, name: $0.span) }
        #expect(resolved == .host)
    }

    /// ``ASCII/lowercased(word:)`` matches the per-byte fold for every byte value in every lane.
    @Test func wordLowercaseMatchesByteLowercase() {
        for value in 0...255 {
            let byte = UInt8(value)
            for lane in 0..<8 {
                // Neighbours that would expose a carry or borrow between lanes.
                for neighbour: UInt8 in [0x00, 0x40, 0x5A, 0x7F, 0x80, 0xFF] {
                    var bytes = [UInt8](repeating: neighbour, count: 8)
                    bytes[lane] = byte
                    let word = bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
                    let expected = bytes.map(ASCII.lowercased).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
                    #expect(ASCII.lowercased(word: word) == expected, "byte \(value) lane \(lane) neighbour \(neighbour)")
                }
            }
        }
    }

    static func slot(_ text: String) -> Int {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { HTTPFieldName.tableSlot(for: $0.span) }
    }

    static func lookup(_ text: String) -> HTTPFieldName {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup($0.span) }
    }

    @Test func pseudoHeaderClassification() {
        let pseudo: [HTTPFieldName] = [.pseudoAuthority, .pseudoMethod, .pseudoPath, .pseudoScheme, .pseudoStatus, .pseudoProtocol]
        for name in HTTPFieldName.allCases {
            #expect(name.isPseudoHeader == pseudo.contains(name), "\(name)")
        }
        #expect(HTTPFieldName.lookup(":path") == .pseudoPath)
    }

    static func alternatingCase(_ text: String) -> String {
        String(text.enumerated().map { $0.offset.isMultiple(of: 2) ? Character($0.element.uppercased()) : $0.element })
    }
}
