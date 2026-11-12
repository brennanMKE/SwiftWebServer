import Testing
import Proxy

@Suite struct ProxySkeletonTests {
    @Test func mountDefaults() {
        let mount = ProxyMount(path: "/api", upstreams: [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000))])
        #expect(mount.stripPrefix == false)
        #expect(mount.forwardedHeaders == .xForwarded)
    }
}
