import HeaderCompression
import Testing
import QPACK

private let policies: [StringLiteral.HuffmanPolicy] = [.whenShorter, .always, .never]

private func randomBytes(_ rng: inout SplitMix64, maxCount: Int, alphabet: [UInt8]? = nil) -> [UInt8] {
    let count = Int.random(in: 0...maxCount, using: &rng)
    return (0..<count).map { _ in
        if let alphabet { return alphabet.randomElement(using: &rng)! }
        return UInt8.random(in: 0...255, using: &rng)
    }
}

private func randomField(_ rng: inout SplitMix64) -> Field {
    let tokenAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-_:".utf8)
    let index = Int.random(in: 0..<QPACKStaticTable.count, using: &rng)
    let name: [UInt8]
    let value: [UInt8]
    switch Int.random(in: 0..<5, using: &rng) {
    case 0:  // exact static entry
        name = QPACKStaticTable.name(at: index)
        value = QPACKStaticTable.value(at: index)
    case 1:  // static name, random value
        name = QPACKStaticTable.name(at: index)
        value = randomBytes(&rng, maxCount: 80)
    case 2:  // static name, value that is a near miss of a static value
        name = QPACKStaticTable.name(at: index)
        value = QPACKStaticTable.value(at: index) + [UInt8(ascii: "x")]
    case 3:  // token-like literal name
        name = randomBytes(&rng, maxCount: 24, alphabet: tokenAlphabet)
        value = randomBytes(&rng, maxCount: 80, alphabet: tokenAlphabet)
    default:  // arbitrary bytes, including long strings that need continuation bytes
        name = randomBytes(&rng, maxCount: 300)
        value = randomBytes(&rng, maxCount: 300)
    }
    return Field(name: name, value: value, neverIndexed: Int.random(in: 0..<8, using: &rng) == 0)
}

@Suite struct QPACKFuzzTests {
    @Test(arguments: [1, 2, 3, 0x5EED, 0xC0FFEE] as [UInt64])
    func randomFieldSectionsRoundTrip(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<300 {
            let fields = (0..<Int.random(in: 0...20, using: &rng)).map { _ in randomField(&rng) }
            let policy = policies.randomElement(using: &rng)!
            let bytes = encode(fields, huffman: policy)
            guard case .fields(let decoded, let size) = decode(bytes, maxFieldSectionSize: 1 << 20) else {
                Issue.record("seed \(seed): round trip failed for \(fields)")
                return
            }
            #expect(stripN(decoded) == stripN(fields))
            #expect(size == sectionSize(fields))
            for (field, out) in zip(fields, decoded) {
                let sensitive = field.name.withUnsafeBytes { QPACKEncoder.isSensitive(name: $0) }
                #expect(out.neverIndexed == (field.neverIndexed || sensitive))
            }
        }
    }

    @Test(arguments: [7, 8, 9] as [UInt64])
    func mutatedSectionsNeverCrash(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<500 {
            let fields = (0..<Int.random(in: 1...8, using: &rng)).map { _ in randomField(&rng) }
            var bytes = encode(fields, huffman: policies.randomElement(using: &rng)!)
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let position = Int.random(in: 0..<bytes.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[position] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
                case 1: bytes.removeSubrange(position...)
                default: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: position)
                }
                if bytes.isEmpty { break }
            }
            switch decode(bytes, maxFieldSectionSize: Int.random(in: 0...4096, using: &rng)) {
            case .fields(let decoded, let size):
                #expect(size == sectionSize(decoded))
            case .error(let error):
                #expect(error.code == .decompressionFailed)
            }
        }
    }

    @Test func randomBytesNeverCrashAnyParser() {
        var rng = SplitMix64(seed: 0xDEC0DE)
        for _ in 0..<2000 {
            let body = randomBytes(&rng, maxCount: 40)
            if case .error(let error) = decode([0x00, 0x00] + body) {
                #expect(error.code == .decompressionFailed)
            }
            body.withUnsafeBytes { raw in
                var encoderReader = QPACKEncoderStreamReader()
                var decoderReader = QPACKDecoderStreamReader()
                do throws(QPACKError) {
                    _ = try QPACKEncoderInstruction.parse(raw, maxStringLength: 64)
                    _ = try encoderReader.consume(raw)
                } catch {
                    #expect(error.code == .encoderStreamError)
                }
                do throws(QPACKError) {
                    _ = try QPACKDecoderInstruction.parse(raw)
                    _ = try decoderReader.next(raw)
                } catch {
                    #expect(error.code == .decoderStreamError)
                }
            }
        }
    }
}
