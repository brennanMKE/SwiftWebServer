import Testing
import HTTP1

@Suite struct HTTP1ModuleTests {
    @Test func moduleIsLinked() {
        #expect(HTTP1Module.name == "HTTP1")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HTTP1Module.dependencies == ["HTTPCore"])
    }
}
