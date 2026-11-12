import Foundation
import Compression
import HTTPCore
import StaticFiles
import Testing
@testable import ConfigFile

/// `http-config.json` parsing (#0086, legacy #0023): every key optional with a documented
/// default, unknown keys warn, bad values fail naming the key.
@Suite struct ConfigFileTests {
    func parse(_ json: String, defaults: ServerSettings = ServerSettings()) throws(ConfigFileError) -> ConfigFile {
        try ConfigFile.parse(Data(json.utf8), source: "test.json", defaults: defaults)
    }

    func error(_ json: String) -> ConfigFileError? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return error
        }
    }

    /// A temporary directory removed on deinit.
    final class Directory {
        let url: URL
        var path: String { url.path }
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "sws-configfile-\(UInt64.random(in: 0...UInt64.max))")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func write(_ text: String, to relative: String) throws {
            let file = url.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Defaults

    @Test func emptyObjectGivesTheDocumentedDefaults() throws {
        let file = try parse("{}")
        let settings = file.settings
        #expect(settings == ServerSettings())
        #expect(file.warnings.isEmpty)
        #expect(settings.host == "127.0.0.1")
        #expect(settings.port == 8080)
        #expect(settings.root == "Public")
        #expect(settings.index == ["index.html"])
        #expect(settings.mimeTypes.isEmpty)
        #expect(settings.defaultMimeType == "application/octet-stream")
        #expect(settings.blockList == ["http-config.json", ".git", ".DS_Store"])
        #expect(settings.blockDotfiles)
        #expect(settings.maxAge == 3600)
        #expect(settings.maxConnections == 1024)
        #expect(settings.drainTimeout == .seconds(10))
        #expect(settings.timeouts.header == .seconds(10))
        #expect(settings.timeouts.idle == .seconds(5))
        #expect(settings.timeouts.body == .seconds(30))
        #expect(settings.timeouts.send == .seconds(30))
        #expect(settings.timeouts.linger == .seconds(2))
        #expect(settings.maxBodySize == 10 * 1024 * 1024)
        #expect(settings.transport == .bsd)
        #expect(settings.errorPages == .generated)
    }

    /// #0086 acceptance: `{"port": 0}` is a complete config.
    @Test func portOnlyKeepsEveryOtherDefault() throws {
        let file = try parse(#"{"port": 0}"#)
        var expected = ServerSettings()
        expected.port = 0
        #expect(file.settings == expected)
        #expect(file.keys == ["port"])
    }

    /// Legacy #0023: removing `enableCompression` (or any key) must not fail.
    @Test func legacyConfigWithoutEnableCompressionParses() throws {
        let file = try parse("""
            {"path": "Public", "port": 8080, "maxConnections": 100, "maxRequestSize": 1024,
             "keepAliveTimeout": 5, "enableETags": true, "defaultIndex": "index.html",
             "defaultMimeType": "application/octet-stream", "caching": {"enabled": true, "maxAge": 60},
             "mimeTypes": [{"contentType": "text/css", "pathExtensions": ["css", "CSS2"]}],
             "blockList": ["http-config.json"]}
            """)
        let settings = file.settings
        #expect(settings.root == "Public")
        #expect(settings.maxConnections == 100)
        #expect(settings.maxBodySize == 1024)
        #expect(settings.timeouts.idle == .seconds(5))
        #expect(settings.index == ["index.html"])
        #expect(settings.maxAge == 60)
        #expect(settings.mimeTypes == ["css": "text/css", "css2": "text/css"])
        #expect(settings.blockList == ["http-config.json"])
        #expect(file.warnings.count == 1)
        #expect(file.warnings.first?.contains("\"enableETags\" has no effect") == true)
    }

    /// The legacy `Root/http-config.json` as it shipped before the cut-over still starts.
    @Test func previousShippedConfigParsesWithWarningsOnly() throws {
        let legacy = """
            {"path": "Public", "port": 8080, "maxConnections": 100, "maxRequestSize": 10485760,
             "keepAliveTimeout": 5, "enableCompression": false, "enableETags": true,
             "defaultIndex": "index.html", "defaultMimeType": "application/octet-stream",
             "caching": {"enabled": true, "maxAge": 3600},
             "mimeTypes": [{"contentType": "text/html", "pathExtensions": ["html", "htm"]}],
             "blockList": ["http-config.json", ".git", ".DS_Store"]}
            """
        let file = try parse(legacy)
        #expect(file.warnings.count == 1)   // enableETags; enableCompression: false is honoured (#0091)
        #expect(file.settings.mimeTypes == ["html": "text/html", "htm": "text/html"])
    }

    @Test func shippedConfigParsesWithoutWarningsAndBuildsItsHandler() throws {
        let path = Self.packageRoot.appending(path: "Root/http-config.json").path
        let file = try ConfigFile.load(path: path)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        #expect(file.settings.port == 8080)
        #expect(file.settings.host == "127.0.0.1")
        #expect(file.settings.resolvedRoot == Self.packageRoot.appending(path: "Root/Public").path)
        #expect(file.settings.errorPages == .files([404: "Custom/404.html", 405: "Custom/405.html"]))
        _ = try file.settings.makeHandler()
    }

    // MARK: Keys

    @Test func everyKeyApplies() throws {
        let settings = try parse("""
            {"host": "::1", "port": 9000, "root": "/srv/www", "index": ["index.htm", "default.html"],
             "mimeTypes": {".MD": "text/markdown; charset=utf-8"}, "defaultMimeType": "text/plain",
             "blockList": [".env"], "blockDotfiles": false, "caching": {"maxAge": 10},
             "maxConnections": 7, "drainTimeout": 0.25,
             "timeouts": {"header": 1, "idle": 0, "body": null, "send": 2.5, "linger": 0.001},
             "maxBodySize": 0, "transport": "nw", "errorPages": false}
            """).settings
        #expect(settings.host == "::1")
        #expect(settings.port == 9000)
        #expect(settings.resolvedRoot == "/srv/www")
        #expect(settings.index == ["index.htm", "default.html"])
        #expect(settings.mimeTypes == ["md": "text/markdown; charset=utf-8"])
        #expect(settings.defaultMimeType == "text/plain")
        #expect(settings.blockList == [".env"])
        #expect(!settings.blockDotfiles)
        #expect(settings.maxAge == 10)
        #expect(settings.maxConnections == 7)
        #expect(settings.drainTimeout == .milliseconds(250))
        #expect(settings.timeouts.header == .seconds(1))
        #expect(settings.timeouts.idle == nil)
        #expect(settings.timeouts.body == nil)
        #expect(settings.timeouts.send == .milliseconds(2500))
        #expect(settings.timeouts.linger == .milliseconds(1))
        #expect(settings.maxBodySize == 0)
        #expect(settings.transport == .nw)
        #expect(settings.errorPages == .off)
    }

    @Test func cachingCanBeTurnedOff() throws {
        #expect(try parse(#"{"caching": {"enabled": false, "maxAge": 60}}"#).settings.maxAge == nil)
        #expect(try parse(#"{"caching": false}"#).settings.maxAge == nil)
        #expect(try parse(#"{"caching": true}"#).settings.maxAge == 3600)
    }

    @Test func singleIndexStringAndErrorPageFiles() throws {
        let settings = try parse(#"{"index": "home.html", "errorPages": {"404": "e/404.html"}}"#).settings
        #expect(settings.index == ["home.html"])
        #expect(settings.errorPages == .files([404: "e/404.html"]))
    }

    @Test func drainTimeoutNullWaitsIndefinitely() throws {
        #expect(try parse(#"{"drainTimeout": null}"#).settings.drainTimeout == nil)
        #expect(try parse(#"{"drainTimeout": 0}"#).settings.drainTimeout == .zero)
    }

    @Test func newKeysWinOverLegacyAliases() throws {
        let file = try parse(#"{"root": "a", "path": "b", "maxBodySize": 1, "maxRequestSize": 2, "timeouts": {"idle": 3}, "keepAliveTimeout": 4}"#)
        #expect(file.settings.root == "a")
        #expect(file.settings.maxBodySize == 1)
        #expect(file.settings.timeouts.idle == .seconds(3))
        #expect(file.warnings.count == 3)
    }

    @Test func unknownKeysWarnInsteadOfFailing() throws {
        let file = try parse(#"{"port": 1, "colour": "blue", "timeouts": {"nap": 1}, "caching": {"etag": true}}"#)
        #expect(file.settings.port == 1)
        #expect(file.warnings.count == 3)
        #expect(file.warnings.contains { $0.contains("unknown key \"colour\"") })
        #expect(file.warnings.contains { $0.contains("unknown key \"timeouts.nap\"") })
        #expect(file.warnings.contains { $0.contains("unknown key \"caching.etag\"") })
    }

    /// `accessLog` was reserved until #0125 claimed it: no warning, no reserved value.
    @Test func accessLogIsNoLongerReserved() throws {
        let file = try parse(#"{"accessLog": true}"#)
        #expect(file.reserved.isEmpty)
        #expect(file.warnings.isEmpty)
        #expect(file.settings.accessLog == ServerSettings.AccessLogSettings())
    }

    // MARK: TLS and HTTP/3 (#0089)

    @Test func tlsAndHTTP3AreOffByDefault() throws {
        let settings = try parse("{}").settings
        #expect(settings.tls == nil)
        #expect(settings.http3 == nil)
        #expect(try settings.tlsPassword(environment: [:]) == nil)
        try settings.validate()
    }

    @Test func tlsKeysApply() throws {
        var defaults = ServerSettings()
        defaults.baseDirectory = "/etc/sws"
        let file = try parse(#"{"tls": {"identity": "id/server.p12", "password": "pw", "port": 0, "colour": 1}}"#, defaults: defaults)
        let tls = try #require(file.settings.tls)
        #expect(tls == ServerSettings.TLSSettings(identity: "id/server.p12", password: .literal("pw"), port: 0))
        #expect(file.settings.resolvedIdentityPath == "/etc/sws/id/server.p12")
        #expect(try file.settings.tlsPassword(environment: [:]) == "pw")
        #expect(file.settings.http3 == nil)
        #expect(file.warnings.count == 1)
        #expect(file.warnings.first?.contains("unknown key \"tls.colour\"") == true)

        let fromEnvironment = try parse(#"{"tls": {"identity": "/a.p12", "passwordEnv": "PW"}}"#).settings
        #expect(fromEnvironment.tls?.port == 8443)
        #expect(fromEnvironment.resolvedIdentityPath == "/a.p12")
        #expect(try fromEnvironment.tlsPassword(environment: ["PW": "secret"]) == "secret")
        #expect(throws: ConfigFileError.self) { try fromEnvironment.tlsPassword(environment: [:]) }

        #expect(try parse(#"{"tls": {"enabled": false}}"#).settings.tls == nil)
        #expect(try parse(#"{"tls": false}"#).settings.tls == nil)
        #expect(try parse(#"{"tls": null}"#).settings.tls == nil)
    }

    @Test func http3KeysApply() throws {
        let tls = #""tls": {"identity": "a.p12", "password": "p"}"#
        #expect(try parse("{\(tls), \"http3\": true}").settings.http3 == ServerSettings.HTTP3Settings())
        #expect(try parse("{\(tls), \"http3\": false}").settings.http3 == nil)
        #expect(try parse("{\(tls), \"http3\": {\"enabled\": false}}").settings.http3 == nil)
        let http3 = try #require(try parse("{\(tls), \"http3\": {\"port\": 9443, \"altSvcMaxAge\": 60}}").settings.http3)
        #expect(http3.port == 9443)
        #expect(http3.altSvcMaxAge == 60)
        #expect(try parse("{\(tls), \"http3\": {\"port\": null}}").settings.http3?.port == nil)
        #expect(ServerSettings.HTTP3Settings().altSvcMaxAge == 86_400)
    }

    @Test(arguments: [
        (#"{"http3": true}"#, "http3"),
        (#"{"tls": {"identity": "a", "password": "b"}, "http3": 1}"#, "http3"),
        (#"{"tls": {"identity": "a", "password": "b"}, "http3": {"port": -1}}"#, "http3.port"),
        (#"{"tls": {"identity": "a", "password": "b"}, "http3": {"altSvcMaxAge": "1d"}}"#, "http3.altSvcMaxAge"),
        (#"{"tls": {"identity": "a", "password": "b"}, "http3": {"enabled": "yes"}}"#, "http3.enabled"),
        (#"{"tls": {"identity": "a", "password": "b"}, "http3": true, "tls2": 1}"#, nil),
        (#"{"tls": true}"#, "tls"),
        (#"{"tls": "server.p12"}"#, "tls"),
        (#"{"tls": {"password": "b"}}"#, "tls.identity"),
        (#"{"tls": {"identity": ""}}"#, "tls.identity"),
        (#"{"tls": {"identity": "a"}}"#, "tls.password"),
        (#"{"tls": {"identity": "a", "password": 1}}"#, "tls.password"),
        (#"{"tls": {"identity": "a", "passwordEnv": ""}}"#, "tls.passwordEnv"),
        (#"{"tls": {"identity": "a", "password": "b", "passwordEnv": "C"}}"#, "tls"),
        (#"{"tls": {"identity": "a", "password": "b", "port": 65536}}"#, "tls.port"),
    ] as [(String, String?)])
    func tlsAndHTTP3ErrorsNameTheKey(json: String, key: String?) {
        let failure = error(json)
        #expect(failure?.key == key, "\(json): \(failure?.description ?? "no error")")
        if let key { #expect(failure?.description.contains("\"\(key)\"") == true, "\(failure?.description ?? "")") }
    }

    // MARK: HTTP/2 (#0119)

    @Test func http2IsOnForTLSWithCleartextOffByDefault() throws {
        let http2 = try #require(try parse("{}").settings.http2)
        #expect(http2 == ServerSettings.HTTP2Settings())
        #expect(!http2.cleartext)
        #expect(http2.maxConcurrentStreams == 100)
        #expect(http2.initialWindowSize == 65_535)
        #expect(http2.maxRequestBodySize == nil)
        #expect(http2.abuseLimits == ServerSettings.AbuseLimitOverrides())
    }

    @Test func http2KeysApply() throws {
        #expect(try parse(#"{"http2": false}"#).settings.http2 == nil)
        #expect(try parse(#"{"http2": null}"#).settings.http2 == nil)
        #expect(try parse(#"{"http2": {"enabled": false, "cleartext": true}}"#).settings.http2 == nil)
        #expect(try parse(#"{"http2": true}"#).settings.http2 == ServerSettings.HTTP2Settings())
        let file = try parse(#"""
            {"http2": {"cleartext": true, "maxConcurrentStreams": 250, "initialWindowSize": 1048576,
             "maxRequestBodySize": 4096, "colour": 1,
             "abuseLimits": {"window": 5, "maxResetStreamsPerWindow": 50, "maxControlFramesPerWindow": null,
                             "smallDataFrameSize": 128, "windowStallTimeout": null, "maxStreamsPerConnection": 10}}}
            """#)
        let http2 = try #require(file.settings.http2)
        #expect(http2.cleartext)
        #expect(http2.maxConcurrentStreams == 250)
        #expect(http2.initialWindowSize == 1_048_576)
        #expect(http2.maxRequestBodySize == 4096)
        #expect(http2.abuseLimits.window == .seconds(5))
        #expect(http2.abuseLimits.maxResetStreamsPerWindow == .some(50))
        #expect(http2.abuseLimits.maxControlFramesPerWindow == .some(nil), "null turns the limit off")
        #expect(http2.abuseLimits.maxEmptyFramesPerWindow == nil, "unset keeps the default")
        #expect(http2.abuseLimits.smallDataFrameSize == 128)
        #expect(http2.abuseLimits.windowStallTimeout == .some(nil))
        #expect(http2.abuseLimits.maxStreamsPerConnection == .some(10))
        #expect(file.warnings == ["config file test.json: unknown key \"http2.colour\" ignored"])
    }

    @Test(arguments: [
        (#"{"http2": 1}"#, "http2"),
        (#"{"http2": "on"}"#, "http2"),
        (#"{"http2": {"enabled": "yes"}}"#, "http2.enabled"),
        (#"{"http2": {"cleartext": 1}}"#, "http2.cleartext"),
        (#"{"http2": {"maxConcurrentStreams": -1}}"#, "http2.maxConcurrentStreams"),
        (#"{"http2": {"maxConcurrentStreams": 65537}}"#, "http2.maxConcurrentStreams"),
        (#"{"http2": {"initialWindowSize": 2147483648}}"#, "http2.initialWindowSize"),
        (#"{"http2": {"maxRequestBodySize": "1M"}}"#, "http2.maxRequestBodySize"),
        (#"{"http2": {"abuseLimits": []}}"#, "http2.abuseLimits"),
        (#"{"http2": {"abuseLimits": {"window": 0}}}"#, "http2.abuseLimits.window"),
        (#"{"http2": {"abuseLimits": {"maxResetStreamsPerWindow": -5}}}"#, "http2.abuseLimits.maxResetStreamsPerWindow"),
        (#"{"http2": {"abuseLimits": {"maxStreamsPerConnection": 0}}}"#, "http2.abuseLimits.maxStreamsPerConnection"),
        (#"{"http2": {"abuseLimits": {"windowStallTimeout": "30s"}}}"#, "http2.abuseLimits.windowStallTimeout"),
    ] as [(String, String?)])
    func http2ErrorsNameTheKey(json: String, key: String?) {
        let failure = error(json)
        #expect(failure?.key == key, "\(json): \(failure?.description ?? "no error")")
        if let key { #expect(failure?.description.contains("\"\(key)\"") == true, "\(failure?.description ?? "")") }
    }

    /// Whole-settings checks run after command-line overrides.
    @Test func validateChecksHTTP3NeedsTLSAndDistinctTCPPorts() throws {
        var settings = ServerSettings()
        settings.http3 = ServerSettings.HTTP3Settings()
        #expect(throws: ConfigFileError(key: "http3", "\"http3\" needs \"tls\": HTTP/3 uses the TLS identity")) { try settings.validate() }
        settings.tls = ServerSettings.TLSSettings(identity: "a", password: .literal("b"), port: 8080)
        #expect { try settings.validate() } throws: { ($0 as? ConfigFileError)?.key == "tls.port" }
        settings.port = 0
        settings.tls?.port = 0
        try settings.validate()   // two port-0 listeners get different ports
        settings.port = 8080
        settings.tls?.port = 8443
        try settings.validate()
    }

    /// `Root/http-config.tls.json`: HTTPS on 8443 and HTTP/3 on the same port number, with the
    /// identity from `scripts/make-test-identity.sh`.
    @Test func shippedTLSExampleConfigParses() throws {
        let path = Self.packageRoot.appending(path: "Root/http-config.tls.json").path
        let file = try ConfigFile.load(path: path)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        let tls = try #require(file.settings.tls)
        #expect(tls.port == 8443)
        #expect(tls.password == .literal("sws-test-password"))
        #expect(file.settings.resolvedIdentityPath == Self.packageRoot.appending(path: "Root/../.test-identity/server.p12").path)
        #expect(file.settings.http3 == ServerSettings.HTTP3Settings(port: nil, altSvcMaxAge: 86_400))
        try file.settings.validate()
        _ = try file.settings.makeHandler()
    }

    // MARK: Errors name the key

    @Test(arguments: [
        (#"{"port": "8080"}"#, "port"),
        (#"{"port": 65536}"#, "port"),
        (#"{"port": 1.5}"#, "port"),
        (#"{"port": true}"#, "port"),
        (#"{"host": 1}"#, "host"),
        (#"{"host": ""}"#, "host"),
        (#"{"root": []}"#, "root"),
        (#"{"index": [1]}"#, "index"),
        (#"{"index": ["a/b"]}"#, "index"),
        (#"{"maxConnections": 0}"#, "maxConnections"),
        (#"{"maxBodySize": -1}"#, "maxBodySize"),
        (#"{"blockDotfiles": 1}"#, "blockDotfiles"),
        (#"{"transport": "udp"}"#, "transport"),
        (#"{"timeouts": {"idle": -1}}"#, "timeouts.idle"),
        (#"{"timeouts": {"idle": "5"}}"#, "timeouts.idle"),
        (#"{"timeouts": 5}"#, "timeouts"),
        (#"{"caching": {"maxAge": "1h"}}"#, "caching.maxAge"),
        (#"{"drainTimeout": -1}"#, "drainTimeout"),
        (#"{"mimeTypes": {"md": 1}}"#, "mimeTypes.md"),
        (#"{"mimeTypes": "text"}"#, "mimeTypes"),
        (#"{"errorPages": {"200": "x.html"}}"#, "errorPages.200"),
        (#"{"errorPages": "yes"}"#, "errorPages"),
        (#"{"blockList": ".git"}"#, "blockList"),
    ])
    func wrongTypeOrRangeNamesTheKey(json: String, key: String) {
        let failure = error(json)
        #expect(failure?.key == key, "\(json)")
        #expect(failure?.description.contains("\"\(key)\"") == true, "\(failure?.description ?? "no error")")
    }

    @Test func malformedFilesFail() throws {
        #expect(error("{ not json")?.description.contains("not valid JSON") == true)
        #expect(error("[1, 2]")?.description.contains("not a JSON object") == true)
        #expect(throws: ConfigFileError.self) { try ConfigFile.load(path: "/nonexistent/\(UUID().uuidString).json") }
        do {
            _ = try ConfigFile.load(path: "/nonexistent/x.json")
        } catch {
            #expect(error.description.contains("cannot read config file /nonexistent/x.json"))
        }
    }

    // MARK: Files and components

    @Test func relativeRootResolvesAgainstTheConfigFile() throws {
        let directory = try Directory()
        try directory.write(#"{"root": "site"}"#, to: "conf/http-config.json")
        let file = try ConfigFile.load(path: directory.url.appending(path: "conf/http-config.json").path)
        #expect(file.settings.resolvedRoot == directory.url.appending(path: "conf/site").path)
    }

    @Test func mapsToComponentConfigurations() throws {
        let settings = try parse("""
            {"maxConnections": 5, "drainTimeout": 1, "maxBodySize": 99, "timeouts": {"idle": 0, "header": 3},
             "index": ["a.html"], "blockList": ["x"], "blockDotfiles": false, "mimeTypes": {"md": "text/markdown"},
             "defaultMimeType": "text/plain", "caching": {"maxAge": 5}}
            """).settings
        #expect(settings.serverConfiguration.maxConnections == 5)
        #expect(settings.serverConfiguration.drainTimeout == .seconds(1))
        #expect(settings.http1Configuration.maxBodySize == 99)
        #expect(settings.http1Configuration.timeouts.idle == nil)
        #expect(settings.http1Configuration.timeouts.header == .seconds(3))
        let files = settings.staticFilesConfiguration
        #expect(files.indexFiles == ["a.html"])
        #expect(files.blockedNames == ["x"])
        #expect(!files.blockDotfiles)
        #expect(files.mimeTypes == ["md": "text/markdown"])
        #expect(files.defaultMIMEType == "text/plain")
        #expect(files.effectiveCacheControl == "public, max-age=5")
    }

    /// Components left out by the config are not in the chain.
    @Test func errorPagesAreRegisteredOnlyWhenEnabled() throws {
        let directory = try Directory()
        try directory.write("<h1>gone</h1>", to: "404.html")
        func components(_ json: String) throws -> (errorPages: Int, staticFiles: Int) {
            var defaults = ServerSettings()
            defaults.root = directory.path
            let handler = try ConfigFile.parse(Data(json.utf8), defaults: defaults).settings.makeHandler()
            var counts = (errorPages: 0, staticFiles: 0)
            MiddlewareChainInspector.visit(handler) { element in
                if element is ErrorPages { counts.errorPages += 1 }
                if element is StaticFiles { counts.staticFiles += 1 }
            }
            return counts
        }
        #expect(try components(#"{"errorPages": false}"#) == (0, 1))
        #expect(try components("{}") == (1, 1))
        #expect(try components(#"{"errorPages": {"404": "404.html"}}"#) == (1, 1))
    }

    // MARK: Compression (#0091)

    @Test func compressionKeyAndLegacyAlias() throws {
        #expect(try parse("{}").settings.compression == nil)
        #expect(try parse(#"{"compression": true}"#).settings.compression == ServerSettings.CompressionSettings())
        #expect(try parse(#"{"compression": false}"#).settings.compression == nil)
        #expect(try parse(#"{"compression": {"enabled": false}}"#).settings.compression == nil)
        let legacy = try parse(#"{"enableCompression": true}"#)
        #expect(legacy.settings.compression == ServerSettings.CompressionSettings())
        #expect(legacy.warnings.isEmpty)
        #expect(try parse(#"{"enableCompression": false}"#).settings.compression == nil)
        let both = try parse(#"{"enableCompression": true, "compression": false}"#)
        #expect(both.settings.compression == nil)
        #expect(both.warnings.count == 1)

        let full = try #require(try parse("""
            {"compression": {"encodings": ["gzip", "br"], "minimumSize": 10, "level": 6, "precompressionLevel": 8,
             "mimeTypes": ["text/*"], "precompress": false, "sidecars": true}}
            """).settings.compression)
        #expect(full.configuration.encodings == [.gzip, .brotli])
        #expect(full.configuration.minimumSize == 10)
        #expect(full.configuration.level == 6)
        #expect(full.configuration.precompressionLevel == 8)
        #expect(full.configuration.mimeTypes == ["text/*"])
        #expect(!full.precompress)
        #expect(full.sidecars)

        #expect(error(#"{"compression": {"encodings": ["zstd"]}}"#)?.key == "compression.encodings")
        #expect(error(#"{"compression": {"level": 0}}"#)?.key == "compression.level")
        #expect(error(#"{"compression": 3}"#)?.key == "compression")
    }

    @Test func compressionIsRegisteredOnlyWhenEnabled() throws {
        let directory = try Directory()
        func count(_ json: String) throws -> (compression: Int, precompression: Bool) {
            var defaults = ServerSettings()
            defaults.root = directory.path
            let settings = try ConfigFile.parse(Data(json.utf8), defaults: defaults).settings
            var count = 0
            MiddlewareChainInspector.visit(try settings.makeHandler()) { element in
                if element is Compression { count += 1 }
            }
            return (count, settings.staticFilesConfiguration.compression != nil)
        }
        #expect(try count("{}") == (0, false))
        #expect(try count(#"{"compression": true}"#) == (1, true))
        #expect(try count(#"{"compression": {"precompress": false, "sidecars": false}}"#) == (1, false))
    }

    @Test func unusableRootOrPageNamesTheKey() throws {
        var settings = ServerSettings()
        settings.root = "/nonexistent/\(UUID().uuidString)"
        #expect(throws: ConfigFileError.self) { _ = try settings.makeHandler() }
        do { _ = try settings.makeHandler(); Issue.record("no error") } catch {
            #expect(error.key == "root")
            #expect(error.description.contains("cannot serve root"))
        }

        let directory = try Directory()
        settings.root = directory.path
        settings.errorPages = .files([404: "missing.html"])
        do { _ = try settings.makeHandler(); Issue.record("no error") } catch {
            #expect(error.key == "errorPages.404")
            #expect(error.description.contains("missing.html"))
        }
    }
}
