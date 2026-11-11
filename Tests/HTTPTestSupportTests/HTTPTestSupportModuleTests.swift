import Testing
import HTTPTestSupport

@Suite struct HTTPTestSupportModuleTests {
    @Test func moduleIsLinked() {
        #expect(HTTPTestSupportModule.name == "HTTPTestSupport")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HTTPTestSupportModule.dependencies == ["HTTPCore", "HTTP1"])
    }
}
