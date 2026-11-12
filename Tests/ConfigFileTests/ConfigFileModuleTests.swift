import Testing
import ConfigFile

@Suite struct ConfigFileModuleTests {
    @Test func moduleIsLinked() {
        #expect(ConfigFileModule.name == "ConfigFile")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(ConfigFileModule.dependencies == ["HTTPCore", "HTTP1", "HTTPServer", "StaticFiles", "Compression"])
    }
}
