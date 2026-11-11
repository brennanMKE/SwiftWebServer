import Testing
import HTTP2

@Suite struct HTTP2ModuleTests {
    @Test func moduleIsLinked() {
        #expect(HTTP2Module.name == "HTTP2")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HTTP2Module.dependencies == ["HPACK", "HTTPCore"])
    }
}
