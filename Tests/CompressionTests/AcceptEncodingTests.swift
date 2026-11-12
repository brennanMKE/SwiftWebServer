import Compression
import HTTPCore
import Testing

@Suite struct AcceptEncodingTests {
    static let all = ContentCodingSet(ContentCoding.allCases)

    func choose(_ values: [String], available: ContentCodingSet = all) -> ContentCoding? {
        let request = TestRequest(.get, "/", headers: values.map { ("Accept-Encoding", $0) })
        return AcceptEncoding.negotiate(request.request.headers, available: available)
    }

    @Test func absentHeaderMeansIdentity() {
        #expect(choose([]) == nil)
    }

    @Test func singleCodings() {
        #expect(choose(["gzip"]) == .gzip)
        #expect(choose(["br"]) == .brotli)
        #expect(choose(["deflate"]) == .deflate)
        #expect(choose(["x-gzip"]) == .gzip)
        #expect(choose(["GZip"]) == .gzip)
        #expect(choose(["compress"]) == nil)
        #expect(choose([""]) == nil)
    }

    @Test func equalWeightsPreferBrotliThenGzip() {
        #expect(choose(["gzip, deflate, br"]) == .brotli)
        #expect(choose(["deflate, gzip"]) == .gzip)
        #expect(choose(["gzip;q=0.8, br;q=0.8"]) == .brotli)
        // Split over two field lines.
        #expect(choose(["gzip", "br"]) == .brotli)
    }

    @Test func weightsDecide() {
        #expect(choose(["br;q=0.5, gzip"]) == .gzip)
        #expect(choose(["br;q=0.5, gzip;q=0.6"]) == .gzip)
        #expect(choose(["br;q=0.001, gzip;q=0"]) == .brotli)
        #expect(choose(["gzip;q=1.0, br;q=0.999"]) == .gzip)
        #expect(choose(["gzip; Q=0.9 , br ;q=0.8"]) == .gzip)
    }

    @Test func zeroWeightRefuses() {
        #expect(choose(["br;q=0, gzip"]) == .gzip)
        #expect(choose(["br;q=0, gzip;q=0"]) == nil)
        #expect(choose(["gzip;q=0.000"]) == nil)
    }

    @Test func wildcard() {
        #expect(choose(["*"]) == .brotli)
        #expect(choose(["*;q=0"]) == nil)
        #expect(choose(["br;q=0, *"]) == .gzip)
        #expect(choose(["*;q=0.3, gzip;q=0.5"]) == .gzip)
        #expect(choose(["*;q=0.6, gzip;q=0.5"]) == .brotli)
        #expect(choose(["gzip;q=0, *"]) == .brotli)
    }

    @Test func identity() {
        #expect(choose(["identity"]) == nil)
        // Identity listed higher than every coding wins.
        #expect(choose(["gzip;q=0.5, identity"]) == nil)
        #expect(choose(["gzip;q=0.5, identity;q=0.4"]) == .gzip)
        // Equal weights: the coding.
        #expect(choose(["gzip, identity"]) == .gzip)
        // identity;q=0 with nothing acceptable still sends identity (no 406).
        #expect(choose(["identity;q=0"]) == nil)
        #expect(choose(["identity;q=0, gzip"]) == .gzip)
    }

    @Test func malformedWeightsAreIgnored() {
        #expect(choose(["gzip;q=abc"]) == nil)
        #expect(choose(["gzip;q=1.5"]) == nil)
        #expect(choose(["gzip;q=0.1234"]) == nil)
        #expect(choose(["gzip;q="]) == nil)
        #expect(choose(["br;q=x, gzip"]) == .gzip)
        // Other parameters are ignored.
        #expect(choose(["gzip;level=9"]) == .gzip)
        #expect(choose(["gzip;level=9;q=0"]) == nil)
    }

    @Test func onlyAvailableCodingsAreChosen() {
        let gzipOnly = ContentCodingSet([.gzip])
        #expect(choose(["br, gzip"], available: gzipOnly) == .gzip)
        #expect(choose(["br"], available: gzipOnly) == nil)
        #expect(choose(["br"], available: .empty) == nil)
    }

    @Test func curlCompressedHeader() {
        // What `curl --compressed` sends when built with zlib only.
        #expect(choose(["deflate, gzip"]) == .gzip)
    }
}

@Suite struct CompressibleTypesTests {
    let types = CompressibleTypes(CompressionConfiguration().mimeTypes)

    func matches(_ type: String) -> Bool {
        let bytes = Array(type.utf8)
        return bytes.withUnsafeBufferPointer { types.matches($0.span) }
    }

    @Test func allowlist() {
        for type in ["text/html", "text/html; charset=utf-8", "TEXT/CSS", "text/plain", "application/json",
                     "application/ld+json", "application/javascript", "text/javascript", "image/svg+xml",
                     "application/xml", "application/rss+xml", "application/wasm", " text/csv ;x=y"] {
            #expect(matches(type), "\(type)")
        }
    }

    @Test func alreadyCompressedTypesAreRefused() {
        for type in ["image/png", "image/jpeg", "image/webp", "video/mp4", "audio/mpeg", "application/zip",
                     "application/gzip", "font/woff2", "application/octet-stream", "text/event-stream",
                     "text", "", "text/"] {
            #expect(!matches(type), "\(type)")
        }
    }
}
