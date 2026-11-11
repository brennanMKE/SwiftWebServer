import Testing
import NetworkTransport

@Suite struct NetworkTransportModuleTests {
    @Test func moduleIsLinked() {
        #expect(NetworkTransportModule.name == "NetworkTransport")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(NetworkTransportModule.dependencies == ["HTTPCore"])
    }
}
