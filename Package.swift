// swift-tools-version: 6.4
// Target layout follows docs/ROADMAP.md §5.1. Every target is pre-declared so that
// milestone work can proceed in parallel without editing this file.

import PackageDescription

let modernSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

/// A library target with a matching product and a `<Name>Tests` test target.
struct Library {
    let name: String
    let dependencies: [String]
    let testDependencies: [String]
    let swiftSettings: [SwiftSetting]

    init(
        _ name: String,
        dependencies: [String] = [],
        testDependencies: [String] = [],
        swiftSettings: [SwiftSetting] = modernSwiftSettings
    ) {
        self.name = name
        self.dependencies = dependencies
        self.testDependencies = testDependencies
        self.swiftSettings = swiftSettings
    }
}

let libraries: [Library] = [
    // Mainline
    Library("HTTPCore"),
    Library("HTTP1", dependencies: ["HTTPCore"], testDependencies: ["HTTPTestSupport"]),
    Library("HTTPServer", dependencies: ["HTTPCore", "HTTP1"]),
    Library("NetworkTransport", dependencies: ["HTTPCore"], testDependencies: ["HTTPTestSupport"]),
    // Header compression shared by HPACK and QPACK
    Library("HeaderCompression"),
    Library("HPACK", dependencies: ["HeaderCompression", "HTTPCore"]),
    Library("QPACK", dependencies: ["HeaderCompression", "HTTPCore"]),
    // Optional protocols
    Library("HTTP2", dependencies: ["HPACK", "HTTPCore"], testDependencies: ["HTTPTestSupport", "HTTPServer", "HTTP1", "NetworkTransport"]),
    Library("HTTP3", dependencies: ["QPACK", "HTTPCore"], testDependencies: ["HTTPTestSupport", "NetworkTransport"]),
    Library("WebSockets", dependencies: ["HTTPCore"], testDependencies: ["HTTPTestSupport", "HTTP1", "HTTPServer", "NetworkTransport"]),
    // Optional components
    Library("StaticFiles", dependencies: ["HTTPCore", "Compression"], testDependencies: ["HTTP1"]),
    Library("Compression", dependencies: ["HTTPCore"], testDependencies: ["HTTP1", "HTTPServer", "HTTPTestSupport", "NetworkTransport", "StaticFiles"]),
    Library("VirtualHosts", dependencies: ["HTTPCore"]),
    Library("Auth", dependencies: ["HTTPCore"]),
    Library("AccessLog", dependencies: ["HTTPCore"], testDependencies: ["HTTP1", "HTTPServer", "HTTPTestSupport"]),
    Library("Router", dependencies: ["HTTPCore"]),
    Library("ConfigFile", dependencies: ["HTTPCore", "HTTP1", "HTTPServer", "StaticFiles", "Compression"]),
    // Test support
    Library("HTTPTestSupport", dependencies: ["HTTPCore", "HTTP1"]),
]

func dependencies(_ names: [String]) -> [Target.Dependency] {
    names.map { .target(name: $0) }
}

var products: [Product] = libraries.map { .library(name: $0.name, targets: [$0.name]) }
products += [
    .executable(name: "SwiftWebServer", targets: ["SwiftWebServer"]),
    .executable(name: "sws-bench", targets: ["SWSBench"]),
]

var targets: [Target] = []
for library in libraries {
    targets.append(.target(
        name: library.name,
        dependencies: dependencies(library.dependencies),
        swiftSettings: library.swiftSettings))
    targets.append(.testTarget(
        name: "\(library.name)Tests",
        dependencies: dependencies([library.name] + library.testDependencies),
        swiftSettings: library.swiftSettings))
}

targets += [
    .executableTarget(
        name: "SwiftWebServer",
        dependencies: ["ConfigFile", "HTTPCore", "HTTP1", "HTTPServer", "NetworkTransport",
                       .target(name: "HTTP3", condition: .when(traits: ["HTTP3"]))],
        swiftSettings: modernSwiftSettings),
    .executableTarget(
        name: "SWSBench",
        dependencies: ["HTTPCore", "HTTP1", "HTTPServer", "NetworkTransport", "HeaderCompression", "HTTP2", "HTTP3", "QPACK", "HPACK", "StaticFiles", "ConfigFile", "AccessLog", "WebSockets", "Router", "Compression"],
        path: "Sources/sws-bench",
        swiftSettings: modernSwiftSettings),
    .testTarget(
        name: "SWSBenchTests",
        dependencies: ["SWSBench"],
        swiftSettings: modernSwiftSettings),
    .testTarget(
        name: "IntegrationTests",
        dependencies: ["HTTPCore", "HTTP1", "HTTPServer", "NetworkTransport", "HTTPTestSupport", "HTTP3"],
        swiftSettings: modernSwiftSettings),
]

let package = Package(
    name: "SwiftWebServer",
    platforms: [.macOS(.v15)],
    products: products,
    traits: [
        .trait(name: "HTTP2", description: "Include HTTP/2 (HPACK, HTTP2) in the server executable."),
        .trait(name: "HTTP3", description: "Include HTTP/3 (QPACK, HTTP3) in the server executable."),
        .trait(name: "WebSockets", description: "Include WebSockets in the server executable."),
        .default(enabledTraits: ["HTTP2", "HTTP3", "WebSockets"]),
    ],
    dependencies: [],
    targets: targets,
    swiftLanguageModes: [.v6]
)
