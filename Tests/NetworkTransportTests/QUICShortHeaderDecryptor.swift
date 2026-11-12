import CommonCrypto
import CryptoKit
import Foundation

/// Decrypts 1-RTT (short header) QUIC packets with a TLS 1.3 traffic secret from an
/// `SSLKEYLOGFILE` (RFC 9001 §5), for the #0104 close-code probe: it lets a test read the
/// frames a Network.framework server sent, without a packet capture or new tools.
///
/// Supports TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384 (picked by a 48-byte secret; curl
/// and Network.framework negotiate it on loopback) and TLS_CHACHA20_POLY1305_SHA256, no key
/// update, and small packet numbers (the probe's connections send a few dozen).
struct QUICShortHeaderDecryptor {
    enum Suite: CaseIterable {
        case aes128GCM
        case aes256GCM
        case chaCha20Poly1305
    }

    let secret: [UInt8]
    /// Length of the destination connection ID the packets carry (the receiver's CID).
    let connectionIDLength: Int

    /// The frames' plaintext, or `nil` if no supported suite decrypts the packet.
    func decrypt(_ packet: [UInt8]) -> [UInt8]? {
        let suites: [Suite] = secret.count == 48 ? [.aes256GCM] : [.aes128GCM, .chaCha20Poly1305]
        for suite in suites {
            if let plain = decrypt(packet, suite: suite) { return plain }
        }
        return nil
    }

    func decrypt(_ packet: [UInt8], suite: Suite) -> [UInt8]? {
        let keyLength = suite == .aes128GCM ? 16 : 32
        let key = Self.expandLabel(secret, "quic key", keyLength)
        let iv = Self.expandLabel(secret, "quic iv", 12)
        let hp = Self.expandLabel(secret, "quic hp", keyLength)
        let isAES = suite != .chaCha20Poly1305
        let pnOffset = 1 + connectionIDLength
        guard packet.count >= pnOffset + 4 + 16, packet[0] & 0x80 == 0 else { return nil }
        let sample = Array(packet[(pnOffset + 4)..<(pnOffset + 20)])
        guard let mask = isAES ? Self.aesECB(key: hp, block: sample) : Self.chaChaMask(key: hp, sample: sample)
        else { return nil }
        var header = Array(packet[0..<pnOffset])
        header[0] ^= mask[0] & 0x1f
        let pnLength = Int(header[0] & 0x03) + 1
        var pn: UInt64 = 0
        for i in 0..<pnLength {
            let byte = packet[pnOffset + i] ^ mask[1 + i]
            header.append(byte)
            pn = pn << 8 | UInt64(byte)
        }
        var nonce = iv
        for i in 0..<8 { nonce[11 - i] ^= UInt8(truncatingIfNeeded: pn >> (8 * UInt64(i))) }
        let body = Array(packet[(pnOffset + pnLength)...])
        guard body.count > 16 else { return nil }
        let ciphertext = body.dropLast(16)
        let tag = body.suffix(16)
        do {
            switch suite {
            case .aes128GCM, .aes256GCM:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header))
            case .chaCha20Poly1305:
                let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return Array(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: header))
            }
        } catch {
            return nil
        }
    }

    /// The CONNECTION_CLOSE frames in a decrypted payload: (frame type 0x1c or 0x1d, code).
    /// Stops at the first frame type it does not know how to skip.
    static func connectionCloses(in frames: [UInt8]) -> [(type: UInt64, code: UInt64)] {
        var result: [(UInt64, UInt64)] = []
        var i = 0
        func varint() -> UInt64? {
            guard i < frames.count else { return nil }
            let length = 1 << Int(frames[i] >> 6)
            guard i + length <= frames.count else { return nil }
            var value = UInt64(frames[i] & 0x3f)
            for j in 1..<length { value = value << 8 | UInt64(frames[i + j]) }
            i += length
            return value
        }
        while let type = varint() {
            switch type {
            case 0x00, 0x01, 0x1e:   // PADDING, PING, HANDSHAKE_DONE
                continue
            case 0x02, 0x03:   // ACK
                guard varint() != nil, varint() != nil, let count = varint(), varint() != nil else { return result }
                for _ in 0..<count { guard varint() != nil, varint() != nil else { return result } }
                if type == 0x03 { for _ in 0..<3 { guard varint() != nil else { return result } } }
            case 0x04:   // RESET_STREAM
                for _ in 0..<3 { guard varint() != nil else { return result } }
            case 0x05, 0x11, 0x15:   // STOP_SENDING, MAX_STREAM_DATA, STREAM_DATA_BLOCKED
                for _ in 0..<2 { guard varint() != nil else { return result } }
            case 0x10, 0x12, 0x13, 0x14, 0x16, 0x17, 0x19:   // MAX_DATA, MAX_STREAMS, *_BLOCKED, RETIRE_CONNECTION_ID
                guard varint() != nil else { return result }
            case 0x08...0x0f:   // STREAM
                guard varint() != nil else { return result }
                if type & 0x04 != 0 { guard varint() != nil else { return result } }
                if type & 0x02 != 0 {
                    guard let length = varint() else { return result }
                    i += Int(length)
                } else {
                    i = frames.count
                }
            case 0x18:   // NEW_CONNECTION_ID
                guard varint() != nil, varint() != nil, i < frames.count else { return result }
                i += 1 + Int(frames[i]) + 16
            case 0x1c, 0x1d:
                guard let code = varint() else { return result }
                if type == 0x1c { guard varint() != nil else { return result } }
                guard let reasonLength = varint() else { return result }
                result.append((type, code))
                i += Int(reasonLength)
            default:
                return result
            }
        }
        return result
    }

    // MARK: Crypto helpers

    /// HKDF-Expand-Label with an empty context (RFC 8446 §7.1): SHA-384 for a 48-byte
    /// secret, SHA-256 otherwise.
    static func expandLabel(_ secret: [UInt8], _ label: String, _ length: Int) -> [UInt8] {
        let full = Array("tls13 \(label)".utf8)
        let info = [UInt8(length >> 8), UInt8(length & 0xff), UInt8(full.count)] + full + [0]
        let key = secret.count == 48
            ? HKDF<SHA384>.expand(pseudoRandomKey: SymmetricKey(data: secret), info: info, outputByteCount: length)
            : HKDF<SHA256>.expand(pseudoRandomKey: SymmetricKey(data: secret), info: info, outputByteCount: length)
        return key.withUnsafeBytes { Array($0) }
    }

    static func aesECB(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, key.count, nil, block, 16, &out, 16, &moved)
        return status == kCCSuccess ? out : nil
    }

    /// ChaCha20 header protection mask (RFC 9001 §5.4.4): the first 5 bytes of the keystream
    /// for counter = sample[0..<4] (little endian) and nonce = sample[4..<16].
    static func chaChaMask(key: [UInt8], sample: [UInt8]) -> [UInt8]? {
        func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        var state: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
        for i in 0..<8 { state.append(word(key, 4 * i)) }
        state.append(word(sample, 0))
        for i in 0..<3 { state.append(word(sample, 4 + 4 * i)) }
        var x = state
        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] << 16 | x[d] >> 16
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] << 12 | x[b] >> 20
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] << 8 | x[d] >> 24
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] << 7 | x[b] >> 25
        }
        for _ in 0..<10 {
            quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15)
            quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14)
        }
        var out: [UInt8] = []
        for i in 0..<2 {
            let value = x[i] &+ state[i]
            for j in 0..<4 { out.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(j)))) }
        }
        return Array(out.prefix(5))
    }
}
