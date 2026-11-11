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

    /// Every well-known name owns a distinct slot of the power-of-two table.
    @Test func tableIsCollisionFree() {
        #expect(HTTPFieldName.tableSize.nonzeroBitCount == 1)
        var slots: [Int: HTTPFieldName] = [:]
        for name in Self.wellKnown {
            let slot = HTTPFieldName.tableSlot(forHash: ASCII.fnv1aLowercased(name.canonicalName))
            #expect(slot >= 0 && slot < HTTPFieldName.tableSize)
            if let other = slots[slot] {
                Issue.record("\(name) collides with \(other) in slot \(slot)")
            }
            slots[slot] = name
        }
        #expect(slots.count == Self.wellKnown.count)
    }

    @Test func everyWellKnownNameResolvesInAnyCase() {
        for name in Self.wellKnown {
            let lower = name.canonicalName.description
            for variant in [lower, lower.uppercased(), Self.alternatingCase(lower)] {
                var bytes = Array(variant.utf8)
                let resolved = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup($0.span) }
                #expect(resolved == name, "\(variant)")
                let hash = bytes.withUnsafeMutableBufferPointer { ASCII.fnv1aLowercased($0.span) }
                let viaHash = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup(hash: hash, name: $0.span) }
                #expect(viaHash == name, "\(variant)")
            }
        }
    }

    @Test func unknownNamesResolveToUnknown() {
        for name: StaticString in ["x-custom", "content-lengthx", "hos", "", "contentlength", "content_length", ":foo"] {
            #expect(HTTPFieldName.lookup(name) == .unknown, "\(name)")
        }
    }

    /// An unknown name whose hash lands on an occupied slot is rejected by the full-hash
    /// and byte compares.
    @Test func unknownNameInOccupiedSlotIsRejected() {
        let occupied = Set(Self.wellKnown.map { HTTPFieldName.tableSlot(forHash: ASCII.fnv1aLowercased($0.canonicalName)) })
        var found = 0
        for i in 0..<10_000 where found < 20 {
            var bytes = Array("x-probe-\(i)".utf8)
            let hash = bytes.withUnsafeMutableBufferPointer { ASCII.fnv1aLowercased($0.span) }
            guard occupied.contains(HTTPFieldName.tableSlot(forHash: hash)) else { continue }
            found += 1
            let resolved = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup(hash: hash, name: $0.span) }
            #expect(resolved == .unknown)
        }
        #expect(found == 20)
    }

    /// A wrong precomputed hash for a well-known name's bytes never resolves.
    @Test func mismatchedHashIsRejected() {
        var bytes = Array("host".utf8)
        let resolved = bytes.withUnsafeMutableBufferPointer { HTTPFieldName.lookup(hash: 12345, name: $0.span) }
        #expect(resolved == .unknown)
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
