// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pi2",
    // iOS for the targets the iPhone app shares with the Mac app (docs/iphone.md section 8): PiModels and EngineKit so far.
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        // Updates for release builds. build.sh copies the framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Seeing and working other apps' windows. Its own module so the app and the developer probe share one copy.
        .target(name: "ComputerKit", path: "Sources/ComputerKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // pi²'s own browser: loading pages, reading them and acting in them. Its own module for the same reason.
        .target(name: "BrowserKit", path: "Sources/BrowserKit", swiftSettings: [.swiftLanguageMode(.v5), .define("PI2_DEVELOPMENT", .when(configuration: .debug))]),
        // How a project hub divides its room into panes (#657). Its own module so pi2-layout-check can check it.
        .target(name: "PaneKit", path: "Sources/PaneKit"),
        // What Return does in a field that sends a message. Its own module so pi2-compose-check can check it.
        .target(name: "ComposeKit", path: "Sources/ComposeKit"),
        // The login item decisions, without the app's launchd calls, so pi2-login-item-check can run them safely.
        .target(name: "LoginItemKit", path: "Sources/LoginItemKit"),
        // Colours and controls shared by the app and the indicator pill.
        .target(name: "PiStyle", path: "Sources/PiStyle"),
        // Window sizing and diagnostics shared by the app and pi2-window-check (#400, #436, #542).
        .target(name: "WindowKit", dependencies: ["PiStyle"], path: "Sources/WindowKit"),
        // The rows of the app's pop-up menus, and an agent's avatar drawn as a picture for one (#597). Its own module so
        // pi2-window-check can read what AppKit makes of them.
        .target(name: "MenuKit", path: "Sources/MenuKit"),
        // What a file linked in a conversation is once its path is made whole, and what a click and its menu do (#451).
        // Its own module so pi2-file-link-check can check it.
        .target(name: "FileLinkKit", path: "Sources/FileLinkKit"),
        // The conversation page's web view, and the page loaded ahead for the next pane (#441). Its own module so
        // pi2-transcript-check can check them. PI2_DEVELOPMENT as for the app: the web inspector and drawing when hidden.
        .target(name: "TranscriptKit", path: "Sources/TranscriptKit", swiftSettings: [.define("PI2_DEVELOPMENT", .when(configuration: .debug))]),
        // Whether the process at the other end of a connection to the engine's socket is the app (#504). Its own module
        // so pi2-peer-check can check it.
        .target(name: "PeerKit", path: "Sources/PeerKit"),
        // The engine's requests, events and state as Swift types, shared by the Mac app and the iPhone app (docs/iphone.md
        // section 8, #669). Foundation and Observation alone, so that it builds for iOS too.
        .target(name: "PiModels", path: "Sources/PiModels"),
        // The engine's client without AppKit: requests and answers, the engine's events read into the models, open
        // conversations and messages on their way, shared by the Mac app and the iPhone app (docs/iphone.md section 8,
        // #670). Foundation, Observation, Network and CryptoKit alone, so that it builds for iOS too.
        .target(name: "EngineKit", dependencies: ["PiModels"], path: "Sources/EngineKit"),
        .executableTarget(
            name: "pi2",
            dependencies: ["ComputerKit", "BrowserKit", "PaneKit", "ComposeKit", "LoginItemKit", "PiStyle", "WindowKit", "MenuKit", "FileLinkKit", "TranscriptKit", "PiModels", "EngineKit", .product(name: "Sparkle", package: "Sparkle")],
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
        // Checks how ComputerKit reaches SwiftUI controls by accessibility (#367, #453), against stand-in views in
        // windows of its own that never come on screen, read in-process: it needs no Accessibility permission.
        .executableTarget(name: "pi2-computer-check", dependencies: ["ComputerKit"], path: "Sources/pi2-computer-check", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks BrowserKit against pages it serves itself on this Mac. Loads no real website and keeps no profile.
        .executableTarget(name: "pi2-browser-probe", dependencies: ["BrowserKit"], path: "Sources/pi2-browser-probe", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks PaneKit's operations on the pane tree. Meant to be built with optimisation (`swift build -c release`),
        // as the app is released: a debug build does not show what #134 was.
        .executableTarget(name: "pi2-layout-check", dependencies: ["PaneKit"], path: "Sources/pi2-layout-check", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks ComposeKit's Return key: the decision, then a real SwiftUI field in an off-screen window of its own.
        .executableTarget(name: "pi2-compose-check", dependencies: ["ComposeKit"], path: "Sources/pi2-compose-check"),
        // Checks WindowKit: a window's smallest size stays fixed whatever its SwiftUI content holds, in off-screen
        // windows of its own. And MenuKit: what each pop-up menu's rows come out as in a native menu, never shown.
        .executableTarget(name: "pi2-window-check", dependencies: ["WindowKit", "MenuKit", "PiStyle"], path: "Sources/pi2-window-check"),
        .executableTarget(name: "pi2-login-item-check", dependencies: ["LoginItemKit"], path: "Sources/pi2-login-item-check"),
        // Checks FileLinkKit against files it makes in a temporary folder of its own. Shows nothing in Finder.
        .executableTarget(name: "pi2-file-link-check", dependencies: ["FileLinkKit"], path: "Sources/pi2-file-link-check"),
        // Checks TranscriptKit: pages loaded ahead and handed over, in off-screen windows of its own (#441).
        .executableTarget(name: "pi2-transcript-check", dependencies: ["TranscriptKit"], path: "Sources/pi2-transcript-check"),
        // The engine's helper that answers whether a connection is the app's (#504). build.sh copies it into the app as
        // Contents/MacOS/pi2-peer, where the engine finds it.
        .executableTarget(name: "pi2-peer", dependencies: ["PeerKit"], path: "Sources/pi2-peer"),
        // Checks PeerKit and pi2-peer on connections of its own, from itself and from /usr/bin/nc.
        .executableTarget(name: "pi2-peer-check", dependencies: ["PeerKit"], path: "Sources/pi2-peer-check"),
        // Checks that the client reads the engine as it did before its models moved into PiModels (#669): a recorded
        // session replayed through the models, and what the views read compared with what they read before.
        .executableTarget(name: "pi2-client-check", dependencies: ["PiModels"], path: "Sources/pi2-client-check", exclude: ["Fixture"]),
    ]
)
