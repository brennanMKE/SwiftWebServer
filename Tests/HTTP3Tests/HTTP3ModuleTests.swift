import Testing
import HTTP3

@Suite struct HTTP3ModuleTests {
    @Test func moduleIsLinked() {
        #expect(HTTP3Module.name == "HTTP3")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HTTP3Module.dependencies == ["QPACK", "HTTPCore"])
    }
}
