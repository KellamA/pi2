#if DEBUG
import EngineKit
import Foundation
import PiModels
import SwiftUI

/// What a debug build's environment asks the hub and the Dashboard to do once they show, so that a state reached by a tap
/// can be pictured in the simulator without one (docs/iphone-app.md, "Drawing a screen and picturing it"). Each sends the
/// real request, through the same client, and shows what the engine answers: against the recorded session, its refusal.
/// None of it is compiled into a release build.
///
/// - `PI2_HUB_ACT=wake`: turns the Now tab's switch for reports waking the orchestrator on. `stop`: stops the first
///   run listed, `stop:<agent>` that agent's run. `send:<text>`: sends `<text>` from the Dashboard's field. `tab:<tab>`:
///   goes to the hub's tab `chat`, `now`, `work` or `more` two seconds later, as a tap on the tab bar would. Each waits
///   until the phone reaches the Mac.
/// - `PI2_HUB_SCROLL=<row>`: scrolls the Now tab or the Dashboard's page to `wake` (the switch), `stop-problem` (what
///   Stop was answered), `finished` (Finished today) or `words` (the orchestrator's last words).
enum HubDebugAct {
    static let act = ProcessInfo.processInfo.environment["PI2_HUB_ACT"]
    static let scroll = ProcessInfo.processInfo.environment["PI2_HUB_SCROLL"]

    /// Done once a launch, by the first view that shows.
    @MainActor private static var done: Set<String> = []

    /// Whether `name` was asked for and not done yet; marks it done.
    @MainActor static func take(_ name: String) -> Bool {
        guard act == name || act?.hasPrefix(name + ":") == true, !done.contains(name) else { return false }
        done.insert(name)
        return true
    }

    /// Waits until the session reaches the Mac (or is the demo, or the recording), so that an act is not sent while the
    /// phone still shows what its store kept and is reaching for the Mac: tried against a copy (#688), every act was
    /// then answered with the store's "can't be reached" line, as a tap in that moment would be. Gives up after `seconds`
    /// and acts anyway, so that what is answered then still shows.
    @MainActor static func whenLive(_ session: AppSession, seconds: Double = 30) async {
        let end = Date(timeIntervalSinceNow: seconds)
        while !HubRequests.isLive(session), Date() < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The run `stop` stops: the one of the agent `stop:<name>` names, in any case, else the first listed.
    @MainActor static func stopTarget(in runs: [ActivityRun], engine: EngineSession<MessageField>) -> ActivityRun? {
        guard let name = argument("stop") else { return runs.first }
        return runs.first { engine.agent($0.runsAs ?? $0.agentId ?? "")?.name.lowercased() == name.lowercased() }
    }

    /// What follows `name:` in the act asked for.
    static func argument(_ name: String) -> String? {
        guard let act, act.hasPrefix(name + ":") else { return nil }
        return String(act.dropFirst(name.count + 1))
    }
}

/// Scrolls a list to the row `PI2_HUB_SCROLL` names, once what an act asked for has had a moment to be answered.
enum HubDebugScroll {
    @MainActor static func scroll(_ scroller: ScrollViewProxy) async {
        guard let target = HubDebugAct.scroll else { return }
        // Long enough for the engine's lists and an act's answer to be drawn; a picture aid, not a test.
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { scroller.scrollTo(target, anchor: .center) }
    }
}
#endif
