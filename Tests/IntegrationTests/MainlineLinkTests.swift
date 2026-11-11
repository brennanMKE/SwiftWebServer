import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Testing

/// End-to-end tests over real and in-memory transports land here from M2 on.
@Suite struct MainlineLinkTests {
    @Test func mainlineModulesLinkTogether() {
        let names = [
            HTTPCoreModule.name,
            HTTP1Module.name,
            HTTPServerModule.name,
            NetworkTransportModule.name,
            HTTPTestSupportModule.name,
        ]
        #expect(names == ["HTTPCore", "HTTP1", "HTTPServer", "NetworkTransport", "HTTPTestSupport"])
    }

    @Test func serverLayersOnCoreAndHTTP1() {
        #expect(HTTPServerModule.dependencies == [HTTPCoreModule.name, HTTP1Module.name])
        #expect(HTTPTestSupportModule.dependencies == [HTTPCoreModule.name, HTTP1Module.name])
    }
}
