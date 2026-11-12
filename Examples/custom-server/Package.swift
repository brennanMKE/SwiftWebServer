// swift-tools-version: 6.2
// A custom server built from SwiftWebServer's library products: static files, a Router API,
// a WebSocket echo, compression and an access log, over HTTP/1.1. See
// docs/guide/choosing-components.md. In your own package, replace the path dependency with
// .package(url: "https://github.com/brennanMKE/SwiftWebServer.git", branch: "main").
import PackageDescription

let package = Package(
    name: "MySite",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "SwiftWebServer", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MySite",
            dependencies: [
                .product(name: "HTTPCore", package: "SwiftWebServer"),
                .product(name: "HTTP1", package: "SwiftWebServer"),
                .product(name: "HTTPServer", package: "SwiftWebServer"),
                .product(name: "NetworkTransport", package: "SwiftWebServer"),
                .product(name: "StaticFiles", package: "SwiftWebServer"),
                .product(name: "Router", package: "SwiftWebServer"),
                .product(name: "WebSockets", package: "SwiftWebServer"),
                .product(name: "Compression", package: "SwiftWebServer"),
                .product(name: "AccessLog", package: "SwiftWebServer"),
            ]),
    ]
)
