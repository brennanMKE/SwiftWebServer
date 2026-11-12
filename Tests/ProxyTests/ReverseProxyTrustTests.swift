import HTTPCore
@testable import Proxy
import Testing

// #0121: trusted proxies, byte-level mount matching, Expect, cookie paths.

private func trusting(_ ranges: [String], _ forwarded: ProxyMount.ForwardedHeaders = .xForwarded) -> ProxyMount {
    var mount = ProxyMount(path: "/api", upstreams: [upstream], forwardedHeaders: forwarded)
    mount.trustedProxies = ranges.map { IPAddressRange($0)! }
    return mount
}

@Suite struct IPAddressRangeTests {
    @Test func parsesAndMatches() throws {
        let v4 = try #require(IPAddressRange("10.0.0.0/8"))
        #expect(v4.contains("10.200.3.4"))
        #expect(v4.contains("::ffff:10.1.2.3"))
        #expect(!v4.contains("11.0.0.1"))
        #expect(!v4.contains("not-an-ip"))
        let host = try #require(IPAddressRange("192.168.1.7"))
        #expect(host.contains("192.168.1.7") && !host.contains("192.168.1.8"))
        let v6 = try #require(IPAddressRange("fd00::/8"))
        #expect(v6.contains("fd12:3456::1") && v6.contains("[fd00::1]") && !v6.contains("fe80::1"))
        #expect(try #require(IPAddressRange("::1")).contains("::1"))
        #expect(try #require(IPAddressRange("0.0.0.0/0")).contains("8.8.8.8"))
        for bad in ["", "10.0.0.0/33", "::1/129", "10.0.0.0/", "10.0.0.0/x", "example.com", "10.0.0.0/8/8", "1.2.3"] {
            #expect(IPAddressRange(bad) == nil, "\(bad)")
        }
    }
}

@Suite struct ReverseProxyTrustedProxyTests {
    let incoming: [(String, String)] = [
        ("Host", "example.com"), ("X-Forwarded-For", "1.1.1.1"), ("X-Forwarded-For", "2.2.2.2"),
        ("X-Forwarded-Proto", "http"), ("X-Forwarded-Host", "orig.example"), ("X-Forwarded-Prefix", "/evil"),
        ("Forwarded", "for=1.1.1.1;proto=http"),
    ]

    @Test func trustedPeerChainIsExtended() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [trusting(["203.0.113.0/24"], .both)], client: client)
        _ = try await send(proxy, "/api/x", headers: incoming)
        let h = try #require(client.last).headers
        #expect(header(h, "X-Forwarded-For") == ["1.1.1.1, 2.2.2.2, 203.0.113.7"])
        #expect(header(h, "X-Forwarded-Proto") == ["http"])
        #expect(header(h, "X-Forwarded-Host") == ["orig.example"])
        #expect(header(h, "X-Forwarded-Prefix") == ["/api"])
        #expect(header(h, "Forwarded") == ["for=1.1.1.1;proto=http, for=203.0.113.7;proto=https;host=\"example.com\""])
    }

    @Test func trustedPeerWithoutIncomingFieldsGetsOurs() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [trusting(["203.0.113.7"])], client: client)
        _ = try await send(proxy, "/api/x")
        let h = try #require(client.last).headers
        #expect(header(h, "X-Forwarded-For") == ["203.0.113.7"])
        #expect(header(h, "X-Forwarded-Proto") == ["https"])
        #expect(header(h, "X-Forwarded-Host") == ["example.com"])
    }

    @Test func untrustedPeerFieldsAreReplaced() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [trusting(["10.0.0.0/8", "::1"], .both)], client: client)
        _ = try await send(proxy, "/api/x", headers: incoming)
        let h = try #require(client.last).headers
        #expect(header(h, "X-Forwarded-For") == ["203.0.113.7"])
        #expect(header(h, "X-Forwarded-Proto") == ["https"])
        #expect(header(h, "X-Forwarded-Host") == ["example.com"])
        #expect(header(h, "X-Forwarded-Prefix") == ["/api"])
        #expect(header(h, "Forwarded") == ["for=203.0.113.7;proto=https;host=\"example.com\""])
    }

    @Test func expectIsNotForwarded() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream])], client: client)
        _ = try await send(proxy, "/api/x", headers: [("Host", "example.com"), ("Expect", "100-continue"), ("X-Keep", "1")])
        let h = try #require(client.last).headers
        #expect(header(h, "Expect").isEmpty)
        #expect(header(h, "X-Keep") == ["1"])
    }

    @Test func connectionNamedFieldsAreRemovedInAnyCase() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/api", upstreams: [upstream])], client: client)
        _ = try await send(proxy, "/api/x", headers: [
            ("Host", "example.com"), ("Connection", "x-one,  X-TWO , cookie"), ("x-one", "1"), ("X-Two", "2"),
            ("Cookie", "a=b"), ("X-Three", "3"),
        ])
        let h = try #require(client.last).headers
        #expect(header(h, "x-one").isEmpty && header(h, "x-two").isEmpty && header(h, "cookie").isEmpty)
        #expect(header(h, "x-three") == ["3"])
    }
}

@Suite struct ReverseProxyByteMatchingTests {
    @Test func normalizedDetection() {
        func normalized(_ s: String) -> Bool {
            Array(s.utf8).withUnsafeBufferPointer { ReverseProxyPath.isNormalized($0.span) }
        }
        for good in ["/", "/api", "/api/x", "/a//b", "/a/.b", "/a/..b", "/a/b.", "/a/.../b", "/a/b/"] {
            #expect(normalized(good), "\(good)")
            #expect(ReverseProxyPath.normalize(good) == good, "\(good)")
        }
        for bad in ["", "api", "/.", "/..", "/a/./b", "/a/../b", "/a/.", "/a/..", "/%61pi", "/caf\u{e9}"] {
            #expect(!normalized(bad), "\(bad)")
        }
    }

    @Test func fastAndSlowPathsAgree() async throws {
        let other = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9001))
        let mounts = [ProxyMount(path: "/api", upstreams: [upstream]), ProxyMount(path: "/api/v2/", upstreams: [other]),
                      ProxyMount(path: "/cgi-bin", hosts: ["App.Example"], upstreams: [other])]
        let proxy = ReverseProxy(mounts: mounts, client: FakeUpstreamClient())
        for path in ["/api", "/api/", "/apix", "/api/v2", "/api/v2x", "/api/v2/y", "/cgi-bin/a", "/", "/index.html"] {
            for host in ["app.example", "APP.example:8443", "other.example"] {
                let request = ProxyTestRequest(path, headers: [("Host", host)])
                let fast = request.request.withSpan(of: request.request.path) { proxy.lookup(path: $0, request: request.request) }
                let slow = proxy.match(path: path, host: host)
                switch fast {
                case .hit(let i): #expect(slow?.mount.prefix == proxy.mounts[i].prefix, "\(path) \(host)")
                case .miss: #expect(slow == nil, "\(path) \(host)")
                case .needsNormalizing: Issue.record("\(path) is normalized")
                }
            }
        }
    }

    @Test func hostMountsMatchAuthorityAndHostWithoutPort() async throws {
        let client = FakeUpstreamClient()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/cgi-bin", hosts: ["App.Example"], upstreams: [upstream])],
                                 client: client)
        _ = try await send(proxy, "/cgi-bin/x", headers: [("Host", "app.example:8443")])
        #expect(client.count == 1)
        _ = try await send(proxy, "/cgi-bin/x", headers: [("Host", "other.example")])
        #expect(client.count == 1)
        // Encoded paths take the slow path and still honor the host.
        _ = try await send(proxy, "/%63gi-bin/x", headers: [("Host", "APP.EXAMPLE")])
        #expect(client.count == 2)
        #expect(client.last?.target == "/cgi-bin/x")
        _ = try await send(proxy, "/%63gi-bin/x", headers: [("Host", "other.example")])
        #expect(client.count == 2)
    }
}

@Suite struct ReverseProxyCookiePathTests {
    func proxy(stripPrefix: Bool, base: String = "", rewrite: Bool = true, cookie: String) -> ReverseProxy {
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000), basePath: base)
        var mount = ProxyMount(path: "/api", upstreams: [target], stripPrefix: stripPrefix)
        mount.rewriteCookiePath = rewrite
        return ReverseProxy(mounts: [mount], client: FakeUpstreamClient {
            var h = HTTPFields()
            h.append(name: "Set-Cookie", value: cookie)
            h.append(name: "X-Other", value: "Path=/")
            return UpstreamResponse(status: .ok, headers: h, body: .empty)
        })
    }

    @Test func pathsMapIntoTheMount() async throws {
        func cookie(_ p: ReverseProxy) async throws -> [String] { header(try await send(p, "/api/x").headers, "Set-Cookie") }
        #expect(try await cookie(proxy(stripPrefix: true, cookie: "sid=1; Path=/; HttpOnly")) == ["sid=1; Path=/api; HttpOnly"])
        #expect(try await cookie(proxy(stripPrefix: true, cookie: "sid=1; path=/users")) == ["sid=1; Path=/api/users"])
        #expect(try await cookie(proxy(stripPrefix: true, base: "/app", cookie: "a=b; Path=/app/x")) == ["a=b; Path=/api/x"])
        // Outside the base path: left alone.
        #expect(try await cookie(proxy(stripPrefix: true, base: "/app", cookie: "a=b; Path=/other")) == ["a=b; Path=/other"])
        // Keep mode with a base path: the base is removed.
        #expect(try await cookie(proxy(stripPrefix: false, base: "/app", cookie: "a=b; Path=/app/api")) == ["a=b; Path=/api"])
        // No path difference, or the option off: unchanged.
        #expect(try await cookie(proxy(stripPrefix: false, cookie: "a=b; Path=/")) == ["a=b; Path=/"])
        #expect(try await cookie(proxy(stripPrefix: true, rewrite: false, cookie: "a=b; Path=/")) == ["a=b; Path=/"])
        #expect(try await cookie(proxy(stripPrefix: true, cookie: "a=b")) == ["a=b"])
        #expect(header(try await send(proxy(stripPrefix: true, cookie: "a=b"), "/api/x").headers, "X-Other") == ["Path=/"])
    }
}
