
import Foundation
import Observation

/// Going into the demo mode and out of it (docs/iphone.md 9.4). Starting it connects the session to a `DemoTransport` on
/// the recording, with the connection bar saying **Demo**; leaving it lets the transport go with everything it changed,
/// takes away the demo's notifications, and goes back to the first screen. The demo writes nothing to disk, so there is
/// nothing else to delete.
@MainActor
@Observable
final class DemoMode {
    static let shared = DemoMode()

    /// The demo's transport while the demo is on.
    private(set) var transport: DemoTransport?
    /// A screen a notification's button asked for, which the Demo bar opens and clears.
    var asked: Route?

    /// Starts the demo on `session`: `Launch.start(session, demo: true)` and Try it without a Mac.
    static func start(_ session: AppSession) {
        guard let transport = DemoTransport.recorded() else {
            session.note("The demo's recording (demo-session.jsonl) is not in this build's bundle.")
            session.connection = .notPaired
            return
        }
        shared.transport?.close()
        shared.transport = transport
        session.macName = DemoTransport.macName
        DemoNotifications.shared.install()
        session.start(transport, as: .demo)
    }

    /// Leaves the demo: forgets what it showed and changed, and goes back to the first screen.
    static func leave(_ session: AppSession) {
        shared.transport?.close()
        shared.transport = nil
        shared.asked = nil
        session.engine.forgetConversations()
        session.macName = nil
        session.connection = .notPaired
        Task { await DemoNotifications.shared.clear() }
    }
}
