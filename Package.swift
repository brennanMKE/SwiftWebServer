// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let package = Package(
    name: "SwiftWebServer",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "SwiftWebServerCore",
            targets: ["SwiftWebServerCore"]),
        .executable(
            name: "SwiftWebServer",
            targets: ["SwiftWebServer"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftWebServerCore",
            dependencies: []),
        .executableTarget(
            name: "SwiftWebServer",
            dependencies: ["SwiftWebServerCore"]),
        .executableTarget(
            name: "SwiftWebSocketsTestSuite",
            dependencies: ["SwiftWebServerCore"])
    ]
)
