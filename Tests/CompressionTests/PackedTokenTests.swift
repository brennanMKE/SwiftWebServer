@testable import Compression
import Testing

/// The scanner compares coding tokens as packed integers; the constants must be `pack` of
/// each token.
@Suite struct PackedTokenTests {
    @Test func constantsMatchTheTokens() {
        #expect(AcceptEncoding.pack("*") == 0x2A)
        #expect(AcceptEncoding.pack("br") == 0x7262)
        #expect(AcceptEncoding.pack("gzip") == 0x7069_7A67)
        #expect(AcceptEncoding.pack("x-gzip") == 0x7069_7A67_2D78)
        #expect(AcceptEncoding.pack("deflate") == 0x65_7461_6C66_6564)
        #expect(AcceptEncoding.pack("identity") == 0x7974_6974_6E65_6469)
    }

    @Test func longerTokensDoNotCollide() {
        let request = TestRequest(.get, "/", headers: [("Accept-Encoding", "identityx, gzipper, brotli, deflate2")])
        #expect(AcceptEncoding.weights(request.request.headers) == AcceptEncoding.Weights())
    }
}
