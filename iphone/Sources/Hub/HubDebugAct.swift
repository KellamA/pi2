#if DEBUG
import Foundation
import SwiftUI

/// What a debug build's environment asks the hub and the Dashboard to do once they show, so that a state reached by a tap
/// can be pictured in the simulator without one (docs/iphone-app.md, "Drawing a screen and picturing it"). Each sends the
/// real request, through the same client, and shows what the engine answers: against the recorded session, its refusal.
/// None of it is compiled into a release build.
///
/// - `PI2_HUB_ACT=wake`: turns the Now tab's switch for reports waking the orchestrator on. `stop`: stops the first
///   run listed. `send:<text>`: sends `<text>` from the Dashboard's field.
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
