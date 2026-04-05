// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "t-space",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "space",
            path: "Sources/space"
        )
    ]
)
