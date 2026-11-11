import Testing
import HTTPCore

@Suite struct ByteViewTests {
    /// "GET /a?b=1 HTTP/1.1\r\nContent-Length: 42\r\nX-Chunk: 1F\r\n"
    static let request = ByteBuffer("GET /a?b=1 HTTP/1.1\r\nContent-Length: 42\r\nX-Chunk: 1F\r\n")
    static let method = ByteView(offset: 0, length: 3)
    static let path = ByteView(offset: 4, length: 2)
    static let query = ByteView(offset: 7, length: 3)
    static let headerName = ByteView(offset: 21, length: 14)
    static let headerValue = ByteView(offset: 37, length: 2)
    static let chunkValue = ByteView(offset: 50, length: 2)

    @Test func basicProperties() {
        let view = ByteView(offset: 3, length: 4)
        #expect(view.endOffset == 7)
        #expect(!view.isEmpty)
        #expect(ByteView.empty.isEmpty)
        #expect(ByteView.empty == ByteView(offset: 0, length: 0))
        #expect(view.subview(1..<3) == ByteView(offset: 4, length: 2))
        #expect(view.subview(0..<4) == view)
        #expect(view.subview(4..<4).isEmpty)
        #expect(Set([view, view, ByteView.empty]).count == 2)
    }

    @Test func stringOnDemand() {
        let buffer = Self.request
        #expect(Self.method.string(in: buffer) == "GET")
        #expect(Self.path.string(in: buffer) == "/a")
        #expect(Self.query.string(in: buffer) == "b=1")
        #expect(Self.headerName.string(in: buffer) == "Content-Length")
        #expect(ByteView.empty.string(in: buffer) == "")
        #expect(buffer.readableView.string(in: buffer).hasPrefix("GET /a"))
    }

    @Test func caseInsensitiveComparison() {
        let buffer = Self.request
        #expect(Self.headerName.equalsCaseInsensitive("content-length", in: buffer))
        #expect(Self.headerName.equalsCaseInsensitive("CONTENT-LENGTH", in: buffer))
        #expect(!Self.headerName.equalsCaseInsensitive("content-type", in: buffer))
        #expect(!Self.headerName.equalsCaseInsensitive("content-lengt", in: buffer))
        #expect(ByteView.empty.equalsCaseInsensitive("", in: buffer))
        #expect(Self.method.equals("GET", in: buffer))
        #expect(!Self.method.equals("get", in: buffer))
        #expect(!Self.method.equals("GETS", in: buffer))
    }

    @Test func numericValues() {
        let buffer = Self.request
        #expect(Self.headerValue.decimalValue(in: buffer) == 42)
        #expect(Self.chunkValue.hexValue(in: buffer) == 0x1F)
        #expect(Self.chunkValue.decimalValue(in: buffer) == nil)
        #expect(ByteView.empty.decimalValue(in: buffer) == nil)
        #expect(ByteView.empty.hexValue(in: buffer) == nil)
    }

    @Test func hashMatchesLiteral() {
        let buffer = Self.request
        #expect(Self.headerName.fnv1aLowercased(in: buffer) == ASCII.fnv1aLowercased("content-length"))
    }

    @Test func spanOfView() {
        let buffer = Self.request
        buffer.withSpan(of: Self.path) { span in
            #expect(span.count == 2)
            #expect(span[0] == UInt8(ascii: "/"))
            #expect(span[1] == UInt8(ascii: "a"))
        }
        buffer.withSpan(of: ByteView(offset: buffer.writerIndex, length: 0)) { #expect($0.count == 0) }
    }

    @Test func viewOfConsumedBytesStaysReadable() {
        var buffer = Self.request
        buffer.moveReaderIndex(forwardBy: 21)   // past the request line
        #expect(Self.method.string(in: buffer) == "GET")
    }
}
