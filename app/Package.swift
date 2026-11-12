// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pi2",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "pi2", path: "Sources/pi2")
    ]
)
