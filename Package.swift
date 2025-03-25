// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let package = Package(
    name: "SwiftWebServer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "webserver", // ← this sets the binary name
            targets: ["SwiftWebServer"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "SwiftWebServer"),
    ]
)
