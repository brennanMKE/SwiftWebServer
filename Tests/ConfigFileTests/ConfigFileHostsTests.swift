import Foundation
import HTTPCore
import Testing
@testable import ConfigFile

/// The `hosts` key (#0092).
@Suite struct ConfigFileHostsTests {
    typealias Directory = ConfigFileTests.Directory

    func parse(_ json: String, base: String = ".") throws(ConfigFileError) -> ConfigFile {
        var defaults = ServerSettings()
        defaults.baseDirectory = base
        return try ConfigFile.parse(Data(json.utf8), source: "test.json", defaults: defaults)
    }

    func error(_ json: String) -> ConfigFileError? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return error
        }
    }

    @Test func parsesHosts() throws {
        let file = try parse("""
            {"hosts": [{"names": ["a.test", "*.a.test"], "root": "sites/a"},
                       {"name": "b.test", "root": "/srv/b"},
                       {"default": true, "root": "Public"}]}
            """)
        #expect(file.warnings.isEmpty)
        #expect(file.settings.hosts == [
            .init(names: ["a.test", "*.a.test"], root: "sites/a"),
            .init(names: ["b.test"], root: "/srv/b"),
            .init(names: [], root: "Public", isDefault: true),
        ])
    }

    @Test(arguments: [
        #"{"hosts": {}}"#,
        #"{"hosts": [{"names": ["a.test"]}]}"#,
        #"{"hosts": [{"root": "x"}]}"#,
        #"{"hosts": [{"names": ["a.test:80"], "root": "x"}]}"#,
        #"{"hosts": [{"names": ["a.test"], "root": "x"}, {"names": ["A.test"], "root": "y"}]}"#,
        #"{"hosts": [{"default": true, "root": "x"}, {"default": true, "root": "y"}]}"#,
        #"{"hosts": [{"names": [1], "root": "x"}]}"#,
    ])
    func badHostsNameTheKey(json: String) {
        #expect(error(json)?.key?.hasPrefix("hosts") == true, "\(json)")
    }

    @Test(.timeLimit(.minutes(1))) func servesEachHostFromItsRoot() async throws {
        let directory = try Directory()
        try directory.write("a\n", to: "sites/a/only-a.txt")
        try directory.write("b\n", to: "sites/b/only-b.txt")
        try directory.write("d\n", to: "Public/only-d.txt")
        let file = try parse("""
            {"root": "does-not-exist",
             "hosts": [{"names": ["a.test"], "root": "sites/a"}, {"names": ["*.b.test"], "root": "sites/b"}]}
            """, base: directory.path)
        let handler = try file.settings.makeHandler()
        #expect(try await Self.status(handler, "a.test", "/only-a.txt") == 200)
        #expect(try await Self.status(handler, "a.test", "/only-b.txt") == 404)
        #expect(try await Self.status(handler, "www.B.test:8080", "/only-b.txt") == 200)
        #expect(try await Self.status(handler, "c.test", "/only-a.txt") == 421)

        let withDefault = try parse("""
            {"hosts": [{"names": ["a.test"], "root": "sites/a"}, {"default": true, "root": "Public"}]}
            """, base: directory.path)
        let fallback = try withDefault.settings.makeHandler()
        #expect(try await Self.status(fallback, "a.test", "/only-a.txt") == 200)
        #expect(try await Self.status(fallback, "c.test", "/only-d.txt") == 200)
        #expect(try await Self.status(fallback, "c.test", "/only-a.txt") == 404)
    }

    /// #0124: `hosts[].proxy` mounts apply to their site only, and the server-level mounts
    /// still apply inside every site. Upstreams are a closed loopback port, so a proxied path
    /// answers 502 and a path that falls through to the files answers 200 or 404.
    @Test(.timeLimit(.minutes(1))) func perHostProxyMounts() async throws {
        let directory = try Directory()
        try directory.write("a\n", to: "sites/a/only-a.txt")
        try directory.write("b\n", to: "sites/b/only-b.txt")
        let file = try parse("""
            {"proxy": [{"path": "/shared", "upstream": "http://127.0.0.1:1", "retries": 0}],
             "hosts": [{"names": ["a.test"], "root": "sites/a",
                        "proxy": [{"path": "/api", "upstream": "http://127.0.0.1:1/base", "retries": 0}]},
                       {"names": ["b.test"], "root": "sites/b"}]}
            """, base: directory.path)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        let site = try #require(file.settings.hosts.first)
        #expect(site.proxy.count == 1)
        #expect(site.proxy.first?.mount.upstreams.first?.basePath == "/base")
        let handler = try file.settings.makeHandler()
        #expect(try await Self.status(handler, "a.test", "/api/items") == 502)
        #expect(try await Self.status(handler, "b.test", "/api/items") == 404)
        #expect(try await Self.status(handler, "a.test", "/shared/x") == 502)
        #expect(try await Self.status(handler, "b.test", "/shared/x") == 502)
        #expect(try await Self.status(handler, "a.test", "/only-a.txt") == 200)
        #expect(try await Self.status(handler, "b.test", "/only-b.txt") == 200)
    }

    @Test(arguments: [
        (#"{"hosts": [{"names": ["a.test"], "root": "x", "proxy": [{"path": "/api"}]}]}"#, "hosts[0].proxy[0]"),
        (#"{"hosts": [{"names": ["a.test"], "root": "x", "proxy": [{"upstream": "ftp://x"}]}]}"#, "hosts[0].proxy[0].upstream"),
        (#"{"hosts": [{"names": ["a.test"], "root": "x", "proxy": 3}]}"#, "hosts[0].proxy"),
    ])
    func badHostProxyNamesTheKey(json: String, key: String) {
        #expect(error(json)?.key == key, "\(json): \(String(describing: error(json)))")
    }

    static func status(_ handler: some HTTPHandler, _ host: String, _ path: String) async throws -> Int {
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 2)
        func add(_ text: String) -> ByteView {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(text.utf8))
            return ByteView(offset: start, length: text.utf8.count)
        }
        let pathView = add(path)
        let name = add("host")
        storage.appendField(nameView: name, hash: ASCII.fnv1aLowercased("host"), valueView: add(host))
        let request = HTTPRequest(method: .get, path: pathView, headers: storage.fieldsView)
        return Int(try await handler.handle(request, context: RequestContext()).status.code)
    }

    @Test func unusableHostRootNamesTheKey() throws {
        let file = try parse(#"{"hosts": [{"names": ["a.test"], "root": "/nonexistent/x"}]}"#)
        #expect(throws: ConfigFileError.self) { _ = try file.settings.makeHandler() }
        do {
            _ = try file.settings.makeHandler()
        } catch {
            #expect(error.key == "hosts[0].root")
        }
    }
}
