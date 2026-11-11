import HeaderCompression
import QPACK

struct Field: Equatable, CustomStringConvertible {
    var name: [UInt8]
    var value: [UInt8]
    var neverIndexed = false

    init(_ name: String, _ value: String, neverIndexed: Bool = false) {
        self.name = Array(name.utf8)
        self.value = Array(value.utf8)
        self.neverIndexed = neverIndexed
    }

    init(name: [UInt8], value: [UInt8], neverIndexed: Bool = false) {
        self.name = name
        self.value = value
        self.neverIndexed = neverIndexed
    }

    var description: String {
        "\(String(decoding: name, as: UTF8.self)): \(String(decoding: value, as: UTF8.self))"
            + (neverIndexed ? " [N]" : "")
    }
}

struct CollectingSink: QPACKFieldSink {
    var fields: [Field] = []

    mutating func field(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool) {
        fields.append(Field(name: Array(name), value: Array(value), neverIndexed: neverIndexed))
    }
}

func hex(_ string: String) -> [UInt8] {
    let digits = Array(string.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

func encode(
    _ fields: [Field], huffman: StringLiteral.HuffmanPolicy = .whenShorter, neverIndexAll: Bool = false
) -> [UInt8] {
    let encoder = QPACKEncoder(huffman: huffman)
    var out: [UInt8] = []
    encoder.encodePrefix(into: &out)
    for field in fields {
        field.name.withUnsafeBytes { name in
            field.value.withUnsafeBytes { value in
                encoder.encodeField(
                    name: name, value: value, neverIndexed: neverIndexAll || field.neverIndexed, into: &out)
            }
        }
    }
    return out
}

enum DecodeOutcome: Equatable {
    case fields([Field], size: Int)
    case error(QPACKError)
}

func decode(_ bytes: [UInt8], maxFieldSectionSize: Int = 16 * 1024) -> DecodeOutcome {
    var decoder = QPACKDecoder(maxFieldSectionSize: maxFieldSectionSize)
    var sink = CollectingSink()
    return bytes.withUnsafeBytes { raw in
        do throws(QPACKError) {
            let size = try decoder.decode(raw, into: &sink)
            return .fields(sink.fields, size: size)
        } catch {
            return .error(error)
        }
    }
}

func decodedFields(_ bytes: [UInt8], maxFieldSectionSize: Int = 16 * 1024) -> [Field]? {
    if case .fields(let fields, _) = decode(bytes, maxFieldSectionSize: maxFieldSectionSize) { return fields }
    return nil
}

func decodeError(_ bytes: [UInt8], maxFieldSectionSize: Int = 16 * 1024) -> QPACKError? {
    if case .error(let error) = decode(bytes, maxFieldSectionSize: maxFieldSectionSize) { return error }
    return nil
}

/// Fields with the N bit cleared, for comparisons that do not care about it.
func stripN(_ fields: [Field]) -> [Field] {
    fields.map { Field(name: $0.name, value: $0.value) }
}

func sectionSize(_ fields: [Field]) -> Int {
    fields.reduce(0) { $0 + $1.name.count + $1.value.count + 32 }
}

/// Deterministic generator for fuzz tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Request header sets as browsers send them over HTTP/3.
let browserRequests: [[Field]] = [
    [  // Chrome navigation
        Field(":method", "GET"), Field(":authority", "www.example.com"), Field(":scheme", "https"),
        Field(":path", "/"),
        Field("sec-ch-ua", "\"Chromium\";v=\"130\", \"Google Chrome\";v=\"130\", \"Not?A_Brand\";v=\"99\""),
        Field("sec-ch-ua-mobile", "?0"), Field("sec-ch-ua-platform", "\"macOS\""),
        Field("upgrade-insecure-requests", "1"),
        Field(
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        ),
        Field(
            "accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"
        ),
        Field("sec-fetch-site", "none"), Field("sec-fetch-mode", "navigate"), Field("sec-fetch-user", "?1"),
        Field("sec-fetch-dest", "document"), Field("accept-encoding", "gzip, deflate, br, zstd"),
        Field("accept-language", "en-US,en;q=0.9"), Field("priority", "u=0, i"),
    ],
    [  // Safari navigation
        Field(":method", "GET"), Field(":scheme", "https"), Field(":path", "/index.html"),
        Field(":authority", "localhost:8443"),
        Field("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        Field("sec-fetch-site", "none"), Field("accept-encoding", "gzip, deflate, br"),
        Field("sec-fetch-mode", "navigate"),
        Field(
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        ),
        Field("accept-language", "en-US,en;q=0.9"), Field("sec-fetch-dest", "document"),
        Field("priority", "u=0, i"), Field("cookie", "session=abc123; theme=dark"),
    ],
    [  // Firefox subresource
        Field(":method", "GET"), Field(":path", "/static/app.js?v=3"), Field(":authority", "cdn.example.org"),
        Field(":scheme", "https"),
        Field("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:132.0) Gecko/20100101 Firefox/132.0"),
        Field("accept", "*/*"), Field("accept-language", "en-US,en;q=0.5"),
        Field("accept-encoding", "gzip, deflate, br, zstd"), Field("referer", "https://www.example.org/"),
        Field("sec-fetch-dest", "script"), Field("sec-fetch-mode", "no-cors"),
        Field("sec-fetch-site", "cross-site"), Field("te", "trailers"),
    ],
    [  // fetch() POST with a bearer token
        Field(":method", "POST"), Field(":authority", "api.example.com"), Field(":scheme", "https"),
        Field(":path", "/v1/items"), Field("content-length", "27"), Field("content-type", "application/json"),
        Field("authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.e30.ZRrHA1JJJW8opsbCGfG_HACGpVUMN_a9IV7pAx_Zmeo"),
        Field("origin", "https://app.example.com"), Field("accept", "application/json"),
        Field("cache-control", "no-cache"),
    ],
]

let typicalResponses: [[Field]] = [
    [
        Field(":status", "200"), Field("content-type", "text/html; charset=utf-8"),
        Field("content-length", "1234"), Field("date", "Wed, 11 Nov 2026 12:00:00 GMT"),
        Field("server", "SwiftWebServer"), Field("cache-control", "max-age=604800"),
        Field("etag", "\"5f3a-1b2c\""), Field("last-modified", "Tue, 10 Nov 2026 08:30:00 GMT"),
        Field("strict-transport-security", "max-age=31536000; includesubdomains"),
        Field("x-content-type-options", "nosniff"), Field("alt-svc", "h3=\":8443\"; ma=86400"),
    ],
    [Field(":status", "304"), Field("etag", "\"abc\""), Field("vary", "accept-encoding")],
    [
        Field(":status", "404"), Field("content-type", "text/plain"), Field("content-length", "0"),
        Field("set-cookie", "id=a3fWa; Expires=Thu, 21 Oct 2027 07:28:00 GMT; Secure; HttpOnly"),
    ],
    [
        Field(":status", "206"), Field("accept-ranges", "bytes"), Field("content-range", "bytes 0-1023/146515"),
        Field("content-type", "image/png"), Field("access-control-allow-origin", "*"),
    ],
]
