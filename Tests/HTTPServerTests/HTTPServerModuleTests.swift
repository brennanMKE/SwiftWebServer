import Testing
import HTTPServer

@Suite struct HTTPServerModuleTests {
    @Test func moduleIsLinked() {
        #expect(HTTPServerModule.name == "HTTPServer")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HTTPServerModule.dependencies == ["HTTPCore", "HTTP1"])
    }
}
