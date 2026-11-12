// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pi2",
    platforms: [.macOS(.v15)],
    targets: [
        // Seeing and working other apps' windows. Its own module so the app and the developer probe share one copy.
        .target(name: "ComputerKit", path: "Sources/ComputerKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "pi2", dependencies: ["ComputerKit"], path: "Sources/pi2"),
        // A command-line way to try ComputerKit while developing. Never copied into the app: a flag on the app itself
        // would let any program borrow the app's Accessibility permission.
        .executableTarget(name: "pi2-probe", dependencies: ["ComputerKit"], path: "Sources/pi2-probe", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
