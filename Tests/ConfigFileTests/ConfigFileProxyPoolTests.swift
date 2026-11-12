import Foundation
import Proxy
import Testing
@testable import ConfigFile

/// `pool` (#0120), `trustedProxies` and `rewriteCookiePath` (#0121) in the `proxy` key.
@Suite struct ConfigFileProxyPoolTests {
    func parse(_ json: String) throws(ConfigFileError) -> ConfigFile {
        try ConfigFile.parse(Data(json.utf8), source: "test.json", defaults: ServerSettings())
    }

    @Test func poolTrustAndCookiesBecomeTheMount() throws {
        let file = try parse("""
            {"proxy": {"path": "/api", "upstream": "http://127.0.0.1:9000", "stripPrefix": true,
                       "pool": {"maxConnections": 8, "maxIdle": 4, "queue": 32, "queueTimeout": 2.5, "idleTimeout": 30},
                       "trustedProxies": ["10.0.0.0/8", "::1", "192.168.1.7"], "rewriteCookiePath": true}}
            """)
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        let mount = try #require(file.settings.proxyMounts.first)
        #expect(mount.policy.pool == UpstreamPoolPolicy(maxConnections: 8, maxIdle: 4, maxQueue: 32,
                                                        queueTimeout: .milliseconds(2500), idleTimeout: .seconds(30)))
        #expect(mount.trustedProxies.map(\.description) == ["10.0.0.0/8", "::1", "192.168.1.7"])
        #expect(mount.rewriteCookiePath)
    }

    @Test func defaultsAndOff() throws {
        let file = try parse("""
            {"proxy": {"path": "/api", "upstream": "http://127.0.0.1:9000", "pool": {"maxConnections": 0, "idleTimeout": 0}}}
            """)
        let mount = try #require(file.settings.proxyMounts.first)
        #expect(mount.policy.pool.maxConnections == nil)
        #expect(mount.policy.pool.idleTimeout == nil)
        #expect(mount.policy.pool.maxIdle == UpstreamPoolPolicy().maxIdle)
        #expect(mount.trustedProxies.isEmpty)
        #expect(!mount.rewriteCookiePath)
    }

    @Test func errorsNameTheKey() {
        for (json, key) in [
            (#"{"proxy": {"upstream": "http://127.0.0.1:1", "trustedProxies": ["10.0.0.0/33"]}}"#, "proxy.trustedProxies[0]"),
            (#"{"proxy": {"upstream": "http://127.0.0.1:1", "trustedProxies": ["example.com"]}}"#, "proxy.trustedProxies[0]"),
            (#"{"proxy": {"upstream": "http://127.0.0.1:1", "pool": {"maxConnections": -1}}}"#, "proxy.pool.maxConnections"),
            (#"{"proxy": {"upstream": "http://127.0.0.1:1", "pool": {"queueTimeout": 0}}}"#, "proxy.pool.queueTimeout"),
            (#"{"proxy": {"upstream": "http://127.0.0.1:1", "rewriteCookiePath": "yes"}}"#, "proxy.rewriteCookiePath"),
        ] {
            do {
                _ = try parse(json)
                Issue.record("accepted: \(json)")
            } catch {
                #expect(error.key == key, "\(json): \(error)")
            }
        }
    }
}
