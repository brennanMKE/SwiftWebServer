import Testing
import HeaderCompression

@Suite struct HeaderCompressionModuleTests {
    @Test func moduleIsLinked() {
        #expect(HeaderCompressionModule.name == "HeaderCompression")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(HeaderCompressionModule.dependencies == [])
    }
}
