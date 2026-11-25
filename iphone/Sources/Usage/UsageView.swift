import EngineKit
import PiModels
import SwiftUI

/// Usage and limits on a page (docs/design/iphone.md, "Every screen and function of the Mac app": "Usage, limits, the plan
/// strip: another shape, a page"): what was spent today, this week and in all; each signed-in subscription's windows; the
/// daily budget; and the spend by project, model, agent and conversation, as the Mac's Usage window gives it
/// (app/Sources/pi2/UsageView.swift). Everything is read from the session's client; its two requests are the Mac's.
struct UsageView: View {
    init() {}

    @Environment(AppSession.self) private var session
    @Environment(\.placement) private var placement

    var body: some View {
        let engine = session.engine
        let reading = Self.reading(engine)
        Group {
            if reading.usage != nil {
                UsagePage(reading: reading, engine: engine, connection: session.connection)
            } else {
                // The engine sends its usage as it greets a connection, so until it has, the Mac has not answered yet.
                ProgressView("Waiting for your Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(placement == .screen ? "Usage" : "")
    }

    /// What the page draws: the engine's state, or in a debug build asked for it, plainly marked sample values.
    @MainActor
    private static func reading(_ engine: EngineSession<MessageField>) -> UsageReading {
        #if DEBUG
        if let sample = UsageSample.reading() { return sample }
        #endif
        return UsageReading(engine)
    }
}
