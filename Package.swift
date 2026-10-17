// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RyouToolbox",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.0")
    ],
    targets: [
        .executableTarget(
            name: "RyouToolbox",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/RyouToolbox"
        )
    ]
)
