// IP addresses and CIDR ranges for `trustedProxies` (#0121).
import Darwin

/// An IPv4 or IPv6 address range: `10.0.0.0/8`, `192.168.1.10`, `::1`, `fd00::/8`. IPv4 is
/// kept as an IPv4-mapped IPv6 address, so `::ffff:10.1.2.3` matches `10.0.0.0/8` too.
public struct IPAddressRange: Sendable, Hashable, CustomStringConvertible {
    /// The network address, IPv4 mapped into `::ffff:0:0/96`.
    let network: UInt128
    let mask: UInt128
    public let description: String

    /// Parses `address` or `address/prefix`. Returns nil for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let (address, isIPv4) = Self.parse(Substring(parts[0])) else { return nil }
        let maxBits = isIPv4 ? 32 : 128
        var bits = maxBits
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(parts[1]), n <= maxBits else { return nil }
            bits = n
        }
        let prefix = isIPv4 ? 96 + bits : bits
        mask = prefix == 0 ? 0 : ~UInt128(0) << (128 - prefix)
        network = address & mask
        description = text
    }

    /// Whether the numeric address `host` (as in ``HTTPCore/TransportAddress/host``) is in the
    /// range. A host that is not a numeric address never matches.
    public func contains(_ host: String) -> Bool {
        guard let (address, _) = Self.parse(Substring(host)) else { return false }
        return contains(address)
    }

    func contains(_ address: UInt128) -> Bool { address & mask == network }

    /// The address as 128 bits (IPv4 mapped) and whether the text was IPv4. No allocation for
    /// the short strings addresses are.
    static func parse(_ text: Substring) -> (UInt128, Bool)? {
        var host = text
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        // A zone (`fe80::1%en0`) is not part of the address.
        if let percent = host.firstIndex(of: "%") { host = host[..<percent] }
        var string = String(host)
        return string.withUTF8 { utf8 -> (UInt128, Bool)? in
            // NUL-terminated copy on the stack (addresses are at most 45 bytes).
            guard utf8.count < 64 else { return nil }
            return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { c -> (UInt128, Bool)? in
                for i in 0..<utf8.count { c[i] = CChar(bitPattern: utf8[i]) }
                c[utf8.count] = 0
                var v4 = in_addr()
                if inet_pton(AF_INET, c.baseAddress!, &v4) == 1 {
                    return (UInt128(0xFFFF) << 32 | UInt128(UInt32(bigEndian: v4.s_addr)), true)
                }
                var v6 = in6_addr()
                if inet_pton(AF_INET6, c.baseAddress!, &v6) == 1 {
                    var value: UInt128 = 0
                    withUnsafeBytes(of: &v6) { for b in $0 { value = value << 8 | UInt128(b) } }
                    return (value, false)
                }
                return nil
            }
        }
    }
}

extension [IPAddressRange] {
    /// Whether `host` is in any of the ranges.
    func containsAddress(_ host: String?) -> Bool {
        guard let host, !isEmpty, let (address, _) = IPAddressRange.parse(Substring(host)) else { return false }
        return contains { $0.contains(address) }
    }
}
