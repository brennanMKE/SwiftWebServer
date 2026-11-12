import Testing
import StaticFiles

@Suite struct StaticFilesModuleTests {
    @Test func moduleIsLinked() {
        #expect(StaticFilesModule.name == "StaticFiles")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(StaticFilesModule.dependencies == ["HTTPCore", "Compression"])
    }
}
