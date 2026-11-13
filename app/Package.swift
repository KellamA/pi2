// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pi2",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Updates for release builds. build.sh copies the framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Seeing and working other apps' windows. Its own module so the app and the developer probe share one copy.
        .target(name: "ComputerKit", path: "Sources/ComputerKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // pi²'s own browser: loading pages, reading them and acting in them. Its own module for the same reason.
        .target(name: "BrowserKit", path: "Sources/BrowserKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "pi2",
            dependencies: ["ComputerKit", "BrowserKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/pi2",
            // The app finds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // A command-line way to try ComputerKit while developing. Never copied into the app: a flag on the app itself
        // would let any program borrow the app's Accessibility permission.
        .executableTarget(name: "pi2-probe", dependencies: ["ComputerKit"], path: "Sources/pi2-probe", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks BrowserKit against pages it serves itself on this Mac. Loads no real website and keeps no profile.
        .executableTarget(name: "pi2-browser-probe", dependencies: ["BrowserKit"], path: "Sources/pi2-browser-probe", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
