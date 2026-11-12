import HTTPCore

/// Why a set of virtual hosts could not be compiled. Thrown by ``VirtualHosts/init(_:unmatched:recordsHost:)``.
public enum VirtualHostsError: Error, Equatable, CustomStringConvertible {
    /// A host name is malformed; `reason` says how.
    case invalidName(name: String, reason: String)
    /// Two hosts claim the same name.
    case duplicateName(String)
    /// More than one host is marked default.
    case multipleDefaults

    public var description: String {
        switch self {
        case .invalidName(let name, let reason): "invalid host name '\(name)': \(reason)"
        case .duplicateName(let name): "host name '\(name)' is configured twice"
        case .multipleDefaults: "more than one default host"
        }
    }
}

/// A configured name: an exact host or a `*.suffix` wildcard, lowercased.
enum HostPattern: Equatable {
    /// `example.com`
    case exact([UInt8])
    /// `*.example.com`, stored as the suffix with its leading dot: `.example.com`.
    case suffix([UInt8])

    /// Parses and normalizes `name`: lowercased, one trailing dot removed. IDNs must be
    /// written in their ASCII (punycode, `xn--`) form, as clients send them.
    static func parse(_ name: String) throws(VirtualHostsError) -> HostPattern {
        func fail(_ reason: String) -> VirtualHostsError { .invalidName(name: name, reason: reason) }
        var bytes = Array(name.utf8).map(ASCII.lowercased)
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        guard !bytes.isEmpty else { throw fail("empty") }
        guard bytes.count <= 255 else { throw fail("longer than 255 bytes") }
        if bytes.first == UInt8(ascii: "[") {
            // IPv6 literal: "[" hex, ":" and "." "]".
            guard bytes.last == UInt8(ascii: "]"), bytes.count > 2,
                  bytes.dropFirst().dropLast().allSatisfy({ ASCII.isHexDigit($0) || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") })
            else { throw fail("an IPv6 literal is written [hex:digits]") }
            return .exact(bytes)
        }
        var wildcard = false
        if bytes.starts(with: Array("*.".utf8)) {
            wildcard = true
            bytes.removeFirst()
            guard bytes.count > 1 else { throw fail("a wildcard needs a suffix after '*.'") }
        }
        for (i, byte) in bytes.enumerated() {
            if byte == UInt8(ascii: ":") { throw fail("names must not include a port") }
            if byte == UInt8(ascii: "*") { throw fail("'*' is allowed only as the whole first label ('*.example.com')") }
            let allowed = ASCII.isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
            guard allowed else {
                throw fail(byte >= 0x80 ? "write internationalized names in punycode (xn--…)" : "unexpected character")
            }
            if byte == UInt8(ascii: "."), i > 0, bytes[i - 1] == UInt8(ascii: ".") { throw fail("empty label") }
        }
        if !wildcard && bytes.first == UInt8(ascii: ".") { throw fail("empty label") }
        return wildcard ? .suffix(bytes) : .exact(bytes)
    }
}

/// The compiled host lookup (built once, read-only afterwards).
///
/// Two open-addressing hash tables, exact names and wildcard suffixes, keyed by a lowercased
/// FNV-1a hash computed from the *last* byte to the first. One right-to-left pass over the
/// request's host then yields the hash of every suffix that starts at a dot (probed in the
/// suffix table, so the longest matching wildcard wins) and, at the end, of the whole name
/// (probed in the exact table, which wins over any wildcard). No allocation, no `String`.
final class HostTable: Sendable {
    struct Slot {
        var hash: UInt32 = 0
        var start: Int32 = 0
        var length: Int32 = 0
        /// Host index, or -1 for an empty slot.
        var host: Int32 = -1
    }

    let exact: [Slot]
    let suffix: [Slot]
    let exactMask: Int
    let suffixMask: Int
    let hasSuffixes: Bool
    /// Lowercased name bytes the slots point into.
    let bytes: [UInt8]

    /// `names[i]` are the patterns of host `i`.
    init(_ names: [[HostPattern]]) throws(VirtualHostsError) {
        var exactEntries: [([UInt8], Int32)] = []
        var suffixEntries: [([UInt8], Int32)] = []
        for (host, patterns) in names.enumerated() {
            for pattern in patterns {
                switch pattern {
                case .exact(let bytes):
                    if exactEntries.contains(where: { $0.0 == bytes }) {
                        throw .duplicateName(String(decoding: bytes, as: UTF8.self))
                    }
                    exactEntries.append((bytes, Int32(host)))
                case .suffix(let bytes):
                    if suffixEntries.contains(where: { $0.0 == bytes }) {
                        throw .duplicateName("*" + String(decoding: bytes, as: UTF8.self))
                    }
                    suffixEntries.append((bytes, Int32(host)))
                }
            }
        }
        var bytes: [UInt8] = []
        func build(_ entries: [([UInt8], Int32)]) -> ([Slot], Int) {
            var capacity = 4
            while capacity < entries.count * 2 { capacity <<= 1 }
            var slots = [Slot](repeating: Slot(), count: capacity)
            let mask = capacity - 1
            for (name, host) in entries {
                let hash = name.withUnsafeBufferPointer { HostTable.reverseHash(Span(_unsafeElements: $0)) }
                var index = Int(hash) & mask
                while slots[index].host >= 0 { index = (index + 1) & mask }
                slots[index] = Slot(hash: hash, start: Int32(bytes.count), length: Int32(name.count), host: host)
                bytes.append(contentsOf: name)
            }
            return (slots, mask)
        }
        (exact, exactMask) = build(exactEntries)
        (suffix, suffixMask) = build(suffixEntries)
        hasSuffixes = !suffixEntries.isEmpty
        self.bytes = bytes
    }

    static let basis: UInt32 = 0x811C_9DC5
    static let prime: UInt32 = 0x0100_0193

    /// FNV-1a of the lowercased bytes, last to first.
    static func reverseHash(_ bytes: Span<UInt8>) -> UInt32 {
        var hash = basis
        var i = bytes.count
        while i > 0 {
            i &-= 1
            hash = (hash ^ UInt32(ASCII.lowercased(bytes[i]))) &* prime
        }
        return hash
    }

    /// The end of the host part of an authority: a trailing `:port` (digits, possibly none)
    /// and then one trailing `.` are excluded. `[v6]:port` keeps the brackets.
    @inline(__always)
    static func hostEnd(_ authority: Span<UInt8>) -> Int {
        var end = authority.count
        var j = end
        while j > 0 && ASCII.isDigit(authority[j &- 1]) { j &-= 1 }
        if j > 0 && authority[j &- 1] == UInt8(ascii: ":") { end = j &- 1 }
        if end > 0 && authority[end &- 1] == UInt8(ascii: ".") { end &-= 1 }
        return end
    }

    /// The host index for `authority` (`Host` or `:authority` bytes), or -1.
    @inline(__always)
    func lookup(authority: Span<UInt8>) -> Int32 {
        let end = HostTable.hostEnd(authority)
        guard end > 0 else { return -1 }
        var hash = HostTable.basis
        var best: Int32 = -1
        var i = end
        let suffixes = hasSuffixes
        while i > 0 {
            i &-= 1
            let byte = ASCII.lowercased(authority[i])
            hash = (hash ^ UInt32(byte)) &* HostTable.prime
            // A wildcard needs at least one byte before its dot; longer suffixes come later
            // in this leftward scan and replace shorter ones.
            if suffixes && byte == UInt8(ascii: ".") && i > 0 {
                let host = probe(suffix, mask: suffixMask, hash: hash, authority: authority, start: i, end: end)
                if host >= 0 { best = host }
            }
        }
        let host = probe(exact, mask: exactMask, hash: hash, authority: authority, start: 0, end: end)
        return host >= 0 ? host : best
    }

    @inline(__always)
    private func probe(_ slots: [Slot], mask: Int, hash: UInt32, authority: Span<UInt8>, start: Int, end: Int) -> Int32 {
        let length = end &- start
        var index = Int(hash) & mask
        while true {
            let slot = slots[index]
            if slot.host < 0 { return -1 }
            if slot.hash == hash && Int(slot.length) == length {
                var k = 0
                let base = Int(slot.start)
                while k < length && bytes[base &+ k] == ASCII.lowercased(authority[start &+ k]) { k &+= 1 }
                if k == length { return slot.host }
            }
            index = (index &+ 1) & mask
        }
    }
}
