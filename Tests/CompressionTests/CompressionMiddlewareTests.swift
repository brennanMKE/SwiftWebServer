import Compression
import Foundation
import HTTPCore
import Testing

@Suite struct CompressionMiddlewareTests {
    let page = sampleText(20_000)

    @Test(arguments: [("gzip", ContentCoding.gzip), ("br", .brotli), ("deflate", .deflate), ("br, gzip", .brotli)])
    func encodesNegotiatedCoding(_ accept: String, _ coding: ContentCoding) async throws {
        let original = response(page, extra: [("ETag", "\"abc\""), ("Content-Length", "20000"), ("Accept-Ranges", "bytes")])
        let result = try await compress(original, headers: [("Accept-Encoding", accept)])
        #expect(result.status.code == 200)
        #expect(result.header(.contentEncoding) == String(describing: coding.token))
        #expect(result.headerValues(.vary) == ["Accept-Encoding"])
        #expect(result.header(.contentLength) == nil)
        #expect(result.header(.acceptRanges) == nil)
        #expect(result.header(.etag) == "\"abc\(coding.etagSuffix)\"")
        #expect(result.header(.contentType) == "text/html; charset=utf-8")
        let body = try await result.bodyBytes()
        #expect(body.count < page.count / 2)
        #expect(ContentCodec.decode(body, coding) == page)
    }

    @Test func identityWhenNotAccepted() async throws {
        for headers in [[], [("Accept-Encoding", "identity")], [("Accept-Encoding", "gzip;q=0, br;q=0")]] {
            let result = try await compress(response(page), headers: headers)
            #expect(result.header(.contentEncoding) == nil)
            #expect(result.headerValues(.vary) == ["Accept-Encoding"], "the representation still varies")
            #expect(try await result.bodyBytes() == page)
        }
    }

    // MARK: Skip rules

    @Test func alreadyCompressedTypesAreNotEncoded() async throws {
        for type in ["image/png", "video/mp4", "application/zip", "font/woff2", "application/octet-stream"] {
            let result = try await compress(response(page, type: type), headers: [("Accept-Encoding", "gzip")])
            #expect(result.header(.contentEncoding) == nil, "\(type)")
            #expect(result.header(.vary) == nil, "\(type)")
        }
        // No Content-Type at all.
        let untyped = HTTPResponse(body: .bytes(ByteBuffer(bytes: page)))
        #expect(try await compress(untyped, headers: [("Accept-Encoding", "gzip")]).header(.contentEncoding) == nil)
    }

    @Test func smallBodiesAreNotEncoded() async throws {
        let small = response(sampleText(1023))
        let result = try await compress(small, headers: [("Accept-Encoding", "gzip")])
        #expect(result.header(.contentEncoding) == nil)
        #expect(result.header(.vary) == nil)
        var configuration = CompressionConfiguration()
        configuration.minimumSize = 100
        let lowered = try await compress(small, headers: [("Accept-Encoding", "gzip")], with: Compression(configuration: configuration))
        #expect(lowered.header(.contentEncoding) == "gzip")
    }

    @Test func statusesWithoutEncodableContentAreUntouched() async throws {
        for status in [HTTPStatus.partialContent, .notModified, .noContent] {
            let result = try await compress(response(page, status: status), headers: [("Accept-Encoding", "gzip")])
            #expect(result.header(.contentEncoding) == nil, "\(status.code)")
            #expect(result.header(.vary) == nil, "\(status.code)")
        }
        // Error pages are encoded.
        let notFound = try await compress(response(page, status: .notFound), headers: [("Accept-Encoding", "gzip")])
        #expect(notFound.header(.contentEncoding) == "gzip")
    }

    @Test func headIsNotEncodedButVaries() async throws {
        let result = try await compress(response(page), .head, headers: [("Accept-Encoding", "gzip")])
        #expect(result.header(.contentEncoding) == nil)
        #expect(result.headerValues(.vary) == ["Accept-Encoding"])
    }

    @Test func existingContentEncodingIsKept() async throws {
        let encoded = response(page, extra: [("Content-Encoding", "gzip")])
        let result = try await compress(encoded, headers: [("Accept-Encoding", "br")])
        #expect(result.headerValues(.contentEncoding) == ["gzip"])
        #expect(try await result.bodyBytes() == page)
    }

    @Test func negotiatedUpstreamIsKept() async throws {
        // A precompressed static file sent unencoded already says it varies.
        let negotiated = response(page, extra: [("Vary", "Accept-Encoding")])
        let result = try await compress(negotiated, headers: [("Accept-Encoding", "gzip")])
        #expect(result.header(.contentEncoding) == nil)
        #expect(result.headerValues(.vary) == ["Accept-Encoding"])
    }

    @Test func varyIsMerged() async throws {
        let result = try await compress(response(page, extra: [("Vary", "Origin")]), headers: [("Accept-Encoding", "gzip")])
        #expect(result.headerValues(.vary) == ["Origin", "Accept-Encoding"])
        let star = try await compress(response(page, extra: [("Vary", "*")]), headers: [("Accept-Encoding", "gzip")])
        #expect(star.headerValues(.vary) == ["*"])
        #expect(star.header(.contentEncoding) == "gzip")
    }

    @Test func noTransformIsHonoured() async throws {
        let result = try await compress(response(page, extra: [("Cache-Control", "public, no-transform")]),
                                        headers: [("Accept-Encoding", "gzip")])
        #expect(result.header(.contentEncoding) == nil)
    }

    @Test func incompressibleBytesAreSentAsTheyAre() async throws {
        let noise = randomBytes(8192)
        let result = try await compress(response(noise, type: "text/plain", extra: [("ETag", "\"n\"")]),
                                        headers: [("Accept-Encoding", "gzip")])
        #expect(result.header(.contentEncoding) == nil)
        #expect(result.header(.etag) == "\"n\"")
        #expect(try await result.bodyBytes() == noise)
    }

    // MARK: ETags and 304

    @Test func weakETagIsKept() async throws {
        let result = try await compress(response(page, extra: [("ETag", "W/\"w1\"")]), headers: [("Accept-Encoding", "gzip")])
        #expect(result.header(.contentEncoding) == "gzip")
        #expect(result.header(.etag) == "W/\"w1\"")
    }

    @Test func ifNoneMatchOnTheVariantTagAnswers304() async throws {
        let original = response(page, extra: [("ETag", "\"v1\""), ("Cache-Control", "max-age=60"),
                                             ("Last-Modified", "Tue, 10 Nov 2026 10:00:00 GMT")])
        let hit = try await compress(original, headers: [("Accept-Encoding", "gzip"), ("If-None-Match", "\"x\", \"v1-gz\"")])
        #expect(hit.status.code == 304)
        #expect(hit.header(.etag) == "\"v1-gz\"")
        #expect(hit.headerValues(.vary) == ["Accept-Encoding"])
        #expect(hit.header(.cacheControl) == "max-age=60")
        #expect(hit.header(.lastModified) == "Tue, 10 Nov 2026 10:00:00 GMT")
        #expect(hit.header(.contentEncoding) == nil)
        if case .empty = hit.body {} else { Issue.record("304 has a body") }
        // Weak comparison: W/ on the client side still matches.
        let weak = try await compress(original, headers: [("Accept-Encoding", "gzip"), ("If-None-Match", "W/\"v1-gz\"")])
        #expect(weak.status.code == 304)
        // The variant the client holds is not the one negotiated now: full response.
        let other = try await compress(original, headers: [("Accept-Encoding", "br"), ("If-None-Match", "\"v1-gz\"")])
        #expect(other.status.code == 200)
        #expect(other.header(.etag) == "\"v1-br\"")
        // Not for HEAD (not encoded) or other methods.
        let head = try await compress(original, .head, headers: [("Accept-Encoding", "gzip"), ("If-None-Match", "\"v1-gz\"")])
        #expect(head.status.code == 200)
    }

    // MARK: Pooled encoders

    @Test func gzipEncodersAreReused() async throws {
        let compression = Compression()
        for _ in 0..<50 {
            let result = try await compress(response(page), headers: [("Accept-Encoding", "gzip")], with: compression)
            #expect(ContentCodec.decode(try await result.bodyBytes(), .gzip) == page)
        }
    }

    @Test func concurrentResponsesStayIndependent() async throws {
        let compression = Compression()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<16 {
                group.addTask {
                    let text = sampleText(30_000, seed: UInt64(task))
                    let coding: ContentCoding = task % 2 == 0 ? .gzip : .brotli
                    let result = try await compress(response(text), headers: [("Accept-Encoding", String(describing: coding.token))],
                                                    with: compression)
                    #expect(ContentCodec.decode(try await result.bodyBytes(), coding) == text)
                }
            }
            try await group.waitForAll()
        }
    }
}
