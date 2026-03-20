// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jetty",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "Jetty",
            path: "Sources/Jetty",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        )
    ]
)
