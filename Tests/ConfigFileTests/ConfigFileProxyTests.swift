import Foundation
import Proxy
import Testing
@testable import ConfigFile

/// The `proxy` key (#0124): parsing and validation only.
@Suite struct ConfigFileProxyTests {
    func parse(_ json: String) throws(ConfigFileError) -> ConfigFile {
        try ConfigFile.parse(Data(json.utf8), source: "test.json", defaults: ServerSettings())
    }

    func expectError(_ json: String, key: String, contains text: String? = nil) {
        do {
            _ = try parse(json)
            Issue.record("accepted: \(json)")
        } catch {
            #expect(error.key == key, "\(json): \(error)")
            if let text { #expect(error.description.contains(text), "\(error)") }
        }
    }

    @Test func shippedProxyExampleParses() throws {
        let path = ConfigFileTests.packageRoot.appending(path: "Root/http-config.proxy.json").path
        let file = try ConfigFile.load(path: path)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        #expect(file.settings.proxy.count == 1)
        let mount = try #require(file.settings.proxyMounts.first)
        #expect(mount.path == "/api")
        #expect(mount.hosts.isEmpty)
        #expect(mount.upstreams == [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000))])
        #expect(!mount.stripPrefix)
        #expect(!mount.preserveHost)
        #expect(mount.forwardedHeaders == .xForwarded)
        #expect(mount.rewriteLocation)
        #expect(!mount.websocket)
        #expect(file.settings.proxy[0].timeouts == .init(connect: .seconds(2), response: .seconds(30), idle: .seconds(60)))
    }

    @Test func parsesEveryField() throws {
        let file = try parse("""
            {"proxy": [{"path": "/app", "hosts": ["a.test", "b.test"],
                        "upstreams": ["http://localhost:8000/base/", "unix:/tmp/app.sock", "http://[::1]:9001"],
                        "stripPrefix": true, "preserveHost": true, "forwardedHeaders": "both",
                        "rewriteLocation": false, "websocket": true, "timeouts": {"connect": 0.5}},
                       {"host": "c.test", "upstream": "http://127.0.0.1:9000", "forwardedHeaders": "none"},
                       {"upstream": "unix:/run/x.sock", "forwardedHeaders": "forwarded"}]}
            """)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        let first = file.settings.proxyMounts[0]
        #expect(first.path == "/app")
        #expect(first.hosts == ["a.test", "b.test"])
        #expect(first.upstreams == [
            UpstreamTarget(address: .tcp(host: "localhost", port: 8000), basePath: "/base"),
            UpstreamTarget(address: .unix(path: "/tmp/app.sock")),
            UpstreamTarget(address: .tcp(host: "::1", port: 9001)),
        ])
        #expect(first.stripPrefix && first.preserveHost && first.websocket && !first.rewriteLocation)
        #expect(first.forwardedHeaders == .both)
        #expect(file.settings.proxy[0].timeouts == .init(connect: .milliseconds(500)))
        let second = file.settings.proxyMounts[1]
        #expect(second.path == "/")
        #expect(second.hosts == ["c.test"])
        #expect(second.forwardedHeaders == ProxyMount.ForwardedHeaders.none)
        #expect(file.settings.proxyMounts[2].forwardedHeaders == .forwarded)
        #expect(file.settings.proxyMounts[2].upstreams == [UpstreamTarget(address: .unix(path: "/run/x.sock"))])
    }

    @Test func timeoutsRetriesAndHealthBecomeThePolicy() throws {
        let file = try parse("""
            {"proxy": [{"upstreams": ["http://127.0.0.1:9000", "http://127.0.0.1:9001"],
                        "timeouts": {"connect": 1, "response": 2, "idle": 3, "total": 4}, "retries": 2,
                        "health": {"failures": 5, "cooldown": 6, "path": "/health", "interval": 7}},
                       {"upstream": "http://127.0.0.1:9000", "path": "/b", "timeouts": {"response": 9}}]}
            """)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        let policy = file.settings.proxyMounts[0].policy
        #expect(policy.timeouts == UpstreamTimeouts(connect: .seconds(1), response: .seconds(2), idle: .seconds(3), total: .seconds(4)))
        #expect(policy.retries == 2)
        #expect(policy.health == UpstreamHealthPolicy(maxFailures: 5, cooldown: .seconds(6), checkPath: "/health", checkInterval: .seconds(7)))
        // Unset limits keep the defaults.
        let defaults = UpstreamTimeouts()
        let second = file.settings.proxyMounts[1].policy
        #expect(second.timeouts == UpstreamTimeouts(connect: defaults.connect, response: .seconds(9), idle: defaults.idle, total: nil))
        #expect(second.retries == 1)
        #expect(second.health == UpstreamHealthPolicy())
        expectError(#"{"proxy": [{"upstream": "http://h:1", "retries": -1}]}"#, key: "proxy[0].retries")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "health": {"path": "health"}}]}"#, key: "proxy[0].health.path")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "health": {"interval": 0}}]}"#, key: "proxy[0].health.interval")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "health": {"failures": 1.5}}]}"#, key: "proxy[0].health.failures")
    }

    @Test func singleObjectIsAccepted() throws {
        let file = try parse(#"{"proxy": {"upstream": "http://127.0.0.1:9000"}}"#)
        #expect(file.settings.proxyMounts.map(\.path) == ["/"])
    }

    @Test func unknownMountKeysWarn() throws {
        let file = try parse(#"{"proxy": [{"upstream": "http://127.0.0.1:9000", "bogus": 1, "timeouts": {"later": 1}}]}"#)
        #expect(file.warnings.count == 2, "\(file.warnings)")
        #expect(!file.warnings.contains { $0.contains("unknown key \"proxy\"") })
    }

    @Test func errorsNameTheKey() {
        expectError(#"{"proxy": [{"path": "/x"}]}"#, key: "proxy[0]", contains: "needs \"upstream\" or \"upstreams\"")
        expectError(#"{"proxy": [{"path": "api", "upstream": "http://h:1"}]}"#, key: "proxy[0].path", contains: "must start with \"/\"")
        expectError(#"{"proxy": [{"path": 1, "upstream": "http://h:1"}]}"#, key: "proxy[0].path")
        expectError(#"{"proxy": [{"upstream": "ftp://h:1"}]}"#, key: "proxy[0].upstream",
                    contains: "\"proxy[0].upstream\" must be http://host:port or unix:/path")
        expectError(#"{"proxy": [{"upstream": "https://h:1"}]}"#, key: "proxy[0].upstream", contains: "https")
        expectError(#"{"proxy": [{"upstream": "http://h"}]}"#, key: "proxy[0].upstream")
        expectError(#"{"proxy": [{"upstream": "http://h:0"}]}"#, key: "proxy[0].upstream")
        expectError(#"{"proxy": [{"upstream": "http://h:70000"}]}"#, key: "proxy[0].upstream")
        expectError(#"{"proxy": [{"upstream": "http://:80"}]}"#, key: "proxy[0].upstream")
        expectError(#"{"proxy": [{"upstream": "unix:relative.sock"}]}"#, key: "proxy[0].upstream")
        expectError(#"{"proxy": [{"upstreams": []}]}"#, key: "proxy[0].upstreams")
        expectError(#"{"proxy": [{"upstreams": ["http://h:1", "x"]}]}"#, key: "proxy[0].upstreams[1]")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "upstreams": ["http://h:2"]}]}"#, key: "proxy[0]")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "host": "a", "hosts": ["b"]}]}"#, key: "proxy[0]")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "host": ""}]}"#, key: "proxy[0].host")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "hosts": "a"}]}"#, key: "proxy[0].hosts")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "stripPrefix": "yes"}]}"#, key: "proxy[0].stripPrefix")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "preserveHost": 1}]}"#, key: "proxy[0].preserveHost")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "rewriteLocation": "no"}]}"#, key: "proxy[0].rewriteLocation")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "websocket": "no"}]}"#, key: "proxy[0].websocket")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "forwardedHeaders": "xff"}]}"#, key: "proxy[0].forwardedHeaders",
                    contains: "x-forwarded")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "timeouts": 5}]}"#, key: "proxy[0].timeouts")
        expectError(#"{"proxy": [{"upstream": "http://h:1", "timeouts": {"connect": -1}}]}"#, key: "proxy[0].timeouts.connect")
        expectError(#"{"proxy": "http://h:1"}"#, key: "proxy")
        expectError(#"{"proxy": [5]}"#, key: "proxy[0]")
    }

    @Test func duplicatePathsAreRejected() throws {
        expectError(#"{"proxy": [{"path": "/api", "upstream": "http://h:1"}, {"path": "/api", "upstream": "http://h:2"}]}"#,
                    key: "proxy[1].path", contains: "proxy[0]")
        expectError(#"{"proxy": [{"upstream": "http://h:1"}, {"upstream": "http://h:2"}]}"#, key: "proxy[1].path")
        expectError(#"{"proxy": [{"path": "/a", "hosts": ["X.test"], "upstream": "http://h:1"}, {"path": "/a", "host": "x.test", "upstream": "http://h:2"}]}"#,
                    key: "proxy[1].path")
        // Same path on disjoint hosts or next to an any-host mount, or different paths, is fine.
        let file = try parse(#"{"proxy": [{"path": "/a", "upstream": "http://h:4"}, {"path": "/a", "host": "x.test", "upstream": "http://h:1"}, {"path": "/a", "host": "y.test", "upstream": "http://h:2"}, {"path": "/b", "upstream": "http://h:3"}]}"#)
        #expect(file.settings.proxy.count == 4)
    }
}
