import Foundation
import Legacy
import Testing

@Suite struct LegacyRequestParserTests {
    @Test func parsesRequestLineQueryAndHeaders() throws {
        let raw = "GET /docs/index.html?lang=en&x=1 HTTP/1.1\r\nHost: localhost:8080\r\nAccept:  text/html \r\n\r\n"
        let request = try #require(HTTPRequest.parse(from: Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/docs/index.html")
        #expect(request.rawTarget == "/docs/index.html?lang=en&x=1")
        #expect(request.query == "lang=en&x=1")
        #expect(request.header(named: "host") == "localhost:8080")
        #expect(request.header(named: "ACCEPT") == "text/html")
        #expect(request.isSupportedMethod)
        #expect(request.includeBody)
    }

    @Test func headRequestIsSupportedWithoutBody() throws {
        let raw = "HEAD / HTTP/1.1\r\nHost: example\r\n\r\n"
        let request = try #require(HTTPRequest.parse(from: Data(raw.utf8)))
        #expect(request.isSupportedMethod)
        #expect(!request.includeBody)
        #expect(!request.isWebSocketUpgrade)
    }

    @Test func detectsWebSocketUpgradeCaseInsensitively() throws {
        let raw = "GET /chat HTTP/1.1\r\nupgrade: WebSocket\r\nConnection: Upgrade\r\n\r\n"
        let request = try #require(HTTPRequest.parse(from: Data(raw.utf8)))
        #expect(request.isWebSocketUpgrade)
    }

    @Test(arguments: ["", "GARBAGE", "\r\n\r\n"])
    func rejectsMalformedRequestLine(raw: String) {
        #expect(HTTPRequest.parse(from: Data(raw.utf8)) == nil)
    }

    @Test func unsupportedMethodIsFlagged() throws {
        let request = try #require(HTTPRequest.parse(from: Data("POST /form HTTP/1.1\r\n\r\n".utf8)))
        #expect(!request.isSupportedMethod)
    }
}

@Suite struct LegacyConfigTests {
    @Test func defaultsMatchDocumentedValues() {
        let config = HTTPConfig()
        #expect(config.port == 8080)
        #expect(config.defaultIndex == "index.html")
        #expect(config.maxRequestSize == 10 * 1024 * 1024)
        #expect(config.caching.enabled)
        #expect(config.caching.maxAge == 3600)
    }

    @Test func decodesConfigFile() throws {
        let json = """
        {
          "path": "Public", "port": 9090, "maxConnections": 10, "keepAliveTimeout": 2,
          "maxRequestSize": 1024, "enableCompression": false, "enableETags": true,
          "defaultIndex": "home.html", "caching": { "enabled": false, "maxAge": 0 },
          "defaultMimeType": "text/plain",
          "mimeTypes": [{ "pathExtensions": ["css"], "contentType": "text/css" }],
          "blockList": [".git"]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-config-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try HTTPConfig(configURL: url)
        #expect(config.port == 9090)
        #expect(config.defaultIndex == "home.html")
        #expect(config.mimeTypes.first?.contentType == "text/css")
        #expect(config.blockList == [".git"])
        #expect(!config.caching.enabled)
    }

    @Test func missingConfigFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        #expect(throws: (any Error).self) { try HTTPConfig(configURL: url) }
    }
}
