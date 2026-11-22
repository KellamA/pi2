#if PI2_DEVELOPMENT
import Observation
import SwiftUI

/// What a development build was last asked to show: the `PI2_SHOW` value it was launched with, then each value a test
/// copy's `scripts/test-copy show` names while it runs (#768). The pages that open at a section read it here, and only
/// here, so a section asked for at launch and one asked for later are taken the same way: an agent's page
/// (`AgentSection`), the Allow everything confirmation (`#everything`) and Settings' tabs (`SettingsLaunch`).
///
/// Each request counts up `count`, which those pages watch, so a section asked for on the page already shown scrolls
/// to it again. A page takes a section once per request: coming back to it later opens it at the top, as usual.
@MainActor
@Observable
final class ShowAsked {
    static let shared = ShowAsked()

    /// The value last asked for, as `PI2_SHOW` names a page.
    private(set) var value: String? = ProcessInfo.processInfo.environment["PI2_SHOW"]
    /// How many requests have come since launch: 0 for the launch's own value.
    private(set) var count = 0

    /// A request of the running copy's `show`, before the page it names is chosen.
    func ask(_ value: String) {
        self.value = value
        count += 1
    }

    /// True the first time it is asked for the request now standing, whose number `taken` keeps: for something done
    /// once per request, such as scrolling to a section or opening a sheet.
    func take(_ taken: inout Int) -> Bool {
        guard taken != count else { return false }
        taken = count
        return true
    }
}

extension AgentSection {
    /// The agent and section a value asks for, or nil when it does not name one: "agent:<id>#<section>".
    static func asked(in value: String?) -> (agent: String, section: AgentSection)? {
        guard let value, value.hasPrefix("agent:"), let hash = value.firstIndex(of: "#"),
              let section = AgentSection(rawValue: String(value[value.index(after: hash)...])) else { return nil }
        return (String(value[value.index(value.startIndex, offsetBy: "agent:".count)..<hash]), section)
    }

    /// Why a running copy's `show` refuses a value: a section after "agent:<id>#" that an agent's page does not have.
    static func refusal(_ value: String) -> String? {
        guard value.hasPrefix("agent:"), let hash = value.firstIndex(of: "#") else { return nil }
        let name = String(value[value.index(after: hash)...])
        guard AgentSection(rawValue: name) == nil else { return nil }
        return "an agent's page has no section #\(name); use " + allCases.map { "#\($0.rawValue)" }.joined(separator: ", ")
    }

    /// The request whose section the page last took.
    @MainActor private static var taken = -1

    /// The section asked for this agent's page by the request now standing, once.
    @MainActor static func take(for agentID: String) -> AgentSection? {
        let shared = ShowAsked.shared
        guard let asked = asked(in: shared.value), asked.agent == agentID, shared.take(&taken) else { return nil }
        return asked.section
    }
}
#endif
