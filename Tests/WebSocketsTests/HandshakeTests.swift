import Testing
@testable import WebSockets

@Suite struct HandshakeTests {
    @Test func rfcExampleAccept() {
        // RFC 6455 §1.3.
        #expect(WebSocketHandshake.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func base64() {
        #expect(Base64.encode([]) == "")
        #expect(Base64.encode(Array("f".utf8)) == "Zg==")
        #expect(Base64.encode(Array("fo".utf8)) == "Zm8=")
        #expect(Base64.encode(Array("foobar".utf8)) == "Zm9vYmFy")
        #expect(Base64.decode(Array("Zm9vYmE=".utf8)) == Array("fooba".utf8))
        #expect(Base64.decode(Array("Zg==".utf8)) == Array("f".utf8))
        for bad in ["Zg=", "Z===", "Zg=a", "Zh==", "Zm9=Zm9v", "Zm9v YmFy", "Zm9v\u{0}mFy"] {
            #expect(Base64.decode(Array(bad.utf8)) == nil, "\(bad)")
        }
        #expect(Base64.decode(Array("dGhlIHNhbXBsZSBub25jZQ==".utf8))?.count == 16)
    }
}
