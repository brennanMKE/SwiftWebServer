import Testing
import HTTPCore

@Suite struct HTTPCoreModuleTests {
    @Test func moduleIsLinked() {
        #expect(HTTPCoreModule.name == "HTTPCore")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HTTPCoreModule.dependencies == [])
    }
}
