import Testing
import Auth

@Suite struct AuthModuleTests {
    @Test func moduleIsLinked() {
        #expect(AuthModule.name == "Auth")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(AuthModule.dependencies == ["HTTPCore"])
    }
}
