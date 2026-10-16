// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RyouToolbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RyouToolbox", path: "Sources/RyouToolbox")
    ]
)
