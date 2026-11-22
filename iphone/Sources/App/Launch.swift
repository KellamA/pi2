import EngineKit
import Foundation

/// What the app connects to as it starts: the one place a transport is chosen.
///
/// - A paired Mac's channel comes with the rest of #680.
/// - The demo mode (#684) starts `DemoTransport` from here, as `start(session, demo: true)`, and takes the place of the
///   debug build's replay below, which it then makes unneeded: delete `ReplayTransport.swift` and its case here.
@MainActor
enum Launch {
    /// The transport to start, if any, and how the connection bar is to describe it.
    static func start(_ session: AppSession) {
        #if DEBUG
        if let launch = DebugLaunch.current {
            launch.apply(to: session)
            return
        }
        #endif
        // Nothing is paired yet in this build, and the demo mode is not built: the first screen.
        session.connection = .notPaired
    }
}
