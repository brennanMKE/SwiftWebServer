import Testing
import HPACK

@Suite struct HPACKModuleTests {
    @Test func moduleIsLinked() {
        #expect(HPACKModule.name == "HPACK")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HPACKModule.dependencies == ["HeaderCompression", "HTTPCore"])
    }
}
