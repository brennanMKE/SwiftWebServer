// swift-tools-version: 6.0
// Standalone spike package for issue #0071. Not part of the SwiftWebServer product.
import PackageDescription

let package = Package(
    name: "QUICSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AllocCounter"),
        .target(name: "QUICSpikeKit", dependencies: ["AllocCounter"]),
        .executableTarget(name: "quic-server", dependencies: ["QUICSpikeKit"]),
        .executableTarget(name: "quic-client", dependencies: ["QUICSpikeKit"]),
    ]
)
