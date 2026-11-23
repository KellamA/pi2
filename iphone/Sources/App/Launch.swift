import EngineKit
import Foundation

/// What the app connects to as it starts: the one place a transport is chosen.
///
/// - A paired Mac's channel comes with the rest of #680.
/// - The demo mode (#684) starts `DemoTransport` from here, as `start(session, demo: true)`: from Try it without a Mac,
///   and in a debug build with `PI2_TRANSPORT=demo`. The debug build's replay (`PI2_TRANSPORT=replay`) stays beside it.
@MainActor
enum Launch {
    /// The transport to start, if any, and how the connection bar is to describe it.
    static func start(_ session: AppSession, demo: Bool = false) {
        if demo {
            DemoMode.start(session)
            return
        }
        #if DEBUG
        if let launch = DebugLaunch.current {
            if launch.transport == "demo" {
                DemoMode.start(session)
            } else {
                launch.apply(to: session)
            }
            return
        }
        #endif
        // Nothing is paired yet in this build: the first screen, which offers the demo.
        session.connection = .notPaired
    }
}
