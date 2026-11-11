import Testing
import AccessLog

@Suite struct AccessLogModuleTests {
    @Test func moduleIsLinked() {
        #expect(AccessLogModule.name == "AccessLog")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(AccessLogModule.dependencies == ["HTTPCore"])
    }
}
