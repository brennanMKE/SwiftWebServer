import Testing
import VirtualHosts

@Suite struct VirtualHostsModuleTests {
    @Test func moduleIsLinked() {
        #expect(VirtualHostsModule.name == "VirtualHosts")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(VirtualHostsModule.dependencies == ["HTTPCore"])
    }
}
