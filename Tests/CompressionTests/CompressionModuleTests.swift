import Testing
import Compression

@Suite struct CompressionModuleTests {
    @Test func moduleIsLinked() {
        #expect(CompressionModule.name == "Compression")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(CompressionModule.dependencies == ["HTTPCore"])
    }
}
