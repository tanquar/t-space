// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FrameDesktop",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FrameDesktop",
            path: "Sources/FrameDesktop"
        )
    ]
)
