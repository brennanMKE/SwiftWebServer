// swift-tools-version: 6.4
// Target layout follows docs/ROADMAP.md §5.1. Every target is pre-declared so that
// milestone work can proceed in parallel without editing this file.

import PackageDescription

let modernSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

/// Legacy code is deleted at the M4 cut-over, so it is left as-is rather than
/// migrated to `modernSwiftSettings`.
let legacySwiftSettings: [SwiftSetting] = []

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
    Library("HTTP1", dependencies: ["HTTPCore"]),
    Library("HTTPServer", dependencies: ["HTTPCore", "HTTP1"]),
    Library("NetworkTransport", dependencies: ["HTTPCore"]),
    // Header compression shared by HPACK and QPACK
    Library("HeaderCompression"),
    Library("HPACK", dependencies: ["HeaderCompression", "HTTPCore"]),
    Library("QPACK", dependencies: ["HeaderCompression", "HTTPCore"]),
    // Optional protocols
    Library("HTTP2", dependencies: ["HPACK", "HTTPCore"]),
    Library("HTTP3", dependencies: ["QPACK", "HTTPCore"]),
    Library("WebSockets", dependencies: ["HTTPCore"]),
    // Optional components
    Library("StaticFiles", dependencies: ["HTTPCore"]),
    Library("Compression", dependencies: ["HTTPCore"]),
    Library("VirtualHosts", dependencies: ["HTTPCore"]),
    Library("Auth", dependencies: ["HTTPCore"]),
    Library("AccessLog", dependencies: ["HTTPCore"]),
    Library("Router", dependencies: ["HTTPCore"]),
    Library("ConfigFile", dependencies: ["HTTPCore"]),
    // Test support
    Library("HTTPTestSupport", dependencies: ["HTTPCore", "HTTP1"]),
    // The shipped server until M4 cut-over
    Library("Legacy", swiftSettings: legacySwiftSettings),
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
        dependencies: ["Legacy"],
        swiftSettings: legacySwiftSettings),
    .executableTarget(
        name: "SWSBench",
        dependencies: ["HTTPCore", "HTTP1", "HTTPServer", "NetworkTransport", "HeaderCompression", "HTTP3"],
        path: "Sources/sws-bench",
        swiftSettings: modernSwiftSettings),
    .testTarget(
        name: "IntegrationTests",
        dependencies: ["HTTPCore", "HTTP1", "HTTPServer", "NetworkTransport", "HTTPTestSupport"],
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
