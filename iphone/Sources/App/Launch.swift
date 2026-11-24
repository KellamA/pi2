
import EngineKit
import Foundation

/// What the app connects to as it starts: the one place a transport is chosen (docs/iphone-app.md, "How the app
/// starts").
///
/// - A paired Mac: the lock screen, then, once Face ID opens a session, the channel (`PhoneLink`).
/// - Nothing paired: the first screen, with **Scan the code on your Mac** and **Try it without a Mac**.
/// - The demo mode (#684): `DemoTransport`, from Try it without a Mac (`start(session, demo: true)`), and in a debug
///   build with `PI2_TRANSPORT=demo`. A debug build's replay (`PI2_TRANSPORT=replay`) stays beside it, and
///   `PI2_TRANSPORT=remote` is the paired Mac's path chosen by name, as a build with no launch value takes it.
@MainActor
enum Launch {
    /// What the app opens on.
    enum Choice: Equatable, Sendable {
        /// The paired Mac, behind Face ID.
        case remote
        /// The first screen: no Mac is paired.
        case firstRun
        case demo
        /// A debug build's recorded session.
        case replay
        /// A debug build's stated connection with no transport (`PI2_CONNECTION` alone), for a picture of the bar.
        case stated
    }

    /// The start-up's decision: a launch value first (a debug build's only), else whether a Mac is paired.
    nonisolated static func choice(paired: Bool, transport: String? = nil, connection: String? = nil) -> Choice {
        switch transport {
        case "demo": .demo
        case "replay": .replay
        case nil where connection != nil: .stated
        default: paired ? .remote : .firstRun
        }
    }

    /// How the paths are made in this build. The simulator looks for no Mac with Bonjour: a test Mac listens on loopback
    /// and advertises nothing (docs/iphone.md 10), and a browse from the simulator would reach the Mac's own network.
    nonisolated static var routes: Routes {
        var routes = Routes()
        #if targetEnvironment(simulator)
        routes.homeFinder = nil
        #endif
        return routes
    }

    /// The app's start, in `Pi2App.init`, once the keyring and the store are made.
    static func start(_ link: PhoneLink) {
        let record = link.record
        #if DEBUG
        if DebugLaunch.isTestHost {
            // The unit tests run inside the app: it reaches for no Mac a test did not set up.
            link.session.connection = .notPaired
            return
        }
        let launch = DebugLaunch.current
        let choice = choice(paired: record != nil, transport: launch?.transport, connection: launch?.connection)
        if let transport = launch?.transport, !["demo", "replay", "remote"].contains(transport) {
            link.session.note("PI2_TRANSPORT=\(transport) is not a transport (demo, replay, remote): started as with none.")
        }
        #else
        let choice = choice(paired: record != nil)
        #endif
        switch choice {
        case .remote:
            if let record { link.startPaired(record) }
        case .firstRun:
            link.session.connection = .notPaired
        case .demo:
            DemoMode.start(link.session)
        case .replay, .stated:
            #if DEBUG
            DebugLaunch.current?.apply(to: link.session)
            #endif
        }
    }

    /// Starts a session with no Mac's link: Try it without a Mac (`demo: true`), and a session an intent makes for
    /// itself while the app registered none (`IntentSessions.current`). Without the demo it opens on the debug build's
    /// launch values, or on the first screen.
    static func start(_ session: AppSession, demo: Bool = false) {
        if demo {
            DemoMode.start(session)
            return
        }
        #if DEBUG
        if let launch = DebugLaunch.current, !DebugLaunch.isTestHost {
            switch choice(paired: false, transport: launch.transport, connection: launch.connection) {
            case .demo: DemoMode.start(session)
            case .replay, .stated: launch.apply(to: session)
            case .remote, .firstRun: session.connection = .notPaired
            }
            return
        }
        #endif
        session.connection = .notPaired
    }
}
