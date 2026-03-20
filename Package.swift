// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jetty",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Jetty",
            path: "Sources/Jetty",
            exclude: ["Resources/Info.plist"]
        )
    ]
)
