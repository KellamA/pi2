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
        // How the conversation area is divided into panes. Its own module so pi2-layout-check can check it.
        .target(name: "PaneKit", path: "Sources/PaneKit"),
        // What Return does in a field that sends a message. Its own module so pi2-compose-check can check it.
        .target(name: "ComposeKit", path: "Sources/ComposeKit"),
        // The login item decisions, without the app's launchd calls, so pi2-login-item-check can run them safely.
        .target(name: "LoginItemKit", path: "Sources/LoginItemKit"),
        .executableTarget(
            name: "pi2",
            dependencies: ["ComputerKit", "BrowserKit", "PaneKit", "ComposeKit", "LoginItemKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/pi2",
            // What only a development build has: PI2_SHOW, the window variables, PI2_DRAW_WHEN_HIDDEN and the web
            // inspector (docs/development.md). On in a debug build, and in an optimised development build, which
            // build.sh makes with `-Xswiftc -DPI2_DEVELOPMENT`; never in a release build.
            swiftSettings: [.define("PI2_DEVELOPMENT", .when(configuration: .debug))],
            // The app finds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // A command-line way to try ComputerKit while developing. Never copied into the app: a flag on the app itself
        // would let any program borrow the app's Accessibility permission.
        .executableTarget(name: "pi2-probe", dependencies: ["ComputerKit"], path: "Sources/pi2-probe", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks BrowserKit against pages it serves itself on this Mac. Loads no real website and keeps no profile.
        .executableTarget(name: "pi2-browser-probe", dependencies: ["BrowserKit"], path: "Sources/pi2-browser-probe", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks PaneKit's operations on the pane tree. Meant to be built with optimisation (`swift build -c release`),
        // as the app is released: a debug build does not show what #134 was.
        .executableTarget(name: "pi2-layout-check", dependencies: ["PaneKit"], path: "Sources/pi2-layout-check", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks ComposeKit's Return key: the decision, then a real SwiftUI field in an off-screen window of its own.
        .executableTarget(name: "pi2-compose-check", dependencies: ["ComposeKit"], path: "Sources/pi2-compose-check"),
        .executableTarget(name: "pi2-login-item-check", dependencies: ["LoginItemKit"], path: "Sources/pi2-login-item-check"),
    ]
)
