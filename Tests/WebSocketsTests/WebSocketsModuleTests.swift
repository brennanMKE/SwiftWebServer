import Testing
import WebSockets

@Suite struct WebSocketsModuleTests {
    @Test func moduleIsLinked() {
        #expect(WebSocketsModule.name == "WebSockets")
    }

    @Test func dependenciesMatchRoadmapLayering() {
        #expect(WebSocketsModule.dependencies == ["HTTPCore", "Compression"])
    }
}
