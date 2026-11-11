import Testing
import QPACK

@Suite struct QPACKModuleTests {
    @Test func moduleIsLinked() {
        #expect(QPACKModule.name == "QPACK")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(QPACKModule.dependencies == ["HeaderCompression", "HTTPCore"])
    }
}
