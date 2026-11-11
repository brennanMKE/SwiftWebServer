import Testing
import Router

@Suite struct RouterModuleTests {
    @Test func moduleIsLinked() {
        #expect(RouterModule.name == "Router")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(RouterModule.dependencies == ["HTTPCore"])
    }
}
