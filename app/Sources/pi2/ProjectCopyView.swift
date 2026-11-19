import Foundation

#if PI2_DEVELOPMENT
/// The project selection handed to a development app. Keep selection separate from the view that will draw it (#470 on).
struct ProjectCopyView: Encodable, Equatable {
    enum Hub: String, Encodable { case both, conversationFolded = "conversation-folded", boardFolded = "board-folded" }
    enum Tab: String, Encodable { case now, work, agents, rules, notes, branches, settings }

    let show: String?
    let project: String?
    let tab: Tab?
    let agent: String?
    let hub: Hub?

    static let launch = try? ProjectCopyView(
        show: ProcessInfo.processInfo.environment["PI2_SHOW"], hub: ProcessInfo.processInfo.environment["PI2_HUB"]
    )

    static func reserves(_ value: String) -> Bool { value == "dashboard" || value.hasPrefix("project:") }

    enum Invalid: String, LocalizedError {
        case project = "Give a project name or id after project:."
        case tab = "Use #now, #work, #agents, #rules, #notes, #branches, #settings or #agent:<name>."
        case hub = "Use both, conversation-folded or board-folded for the hub."
        var errorDescription: String? { rawValue }
    }

    init(show value: String?, hub fold: String?) throws {
        show = value.flatMap { Self.reserves($0) ? $0 : nil }
        hub = fold.flatMap(Hub.init(rawValue:))
        if fold != nil, hub == nil { throw Invalid.hub }
        if let show, show.hasPrefix("project:") {
            let parts = show.dropFirst("project:".count).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.project }
            project = String(name)
            if parts.count == 1 {
                tab = nil
                agent = nil
            } else if parts[1].hasPrefix("agent:"), !parts[1].dropFirst("agent:".count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tab = nil
                agent = String(parts[1].dropFirst("agent:".count))
            } else if let chosen = Tab(rawValue: String(parts[1])) {
                tab = chosen
                agent = nil
            } else {
                throw Invalid.tab
            }
        } else {
            project = nil
            tab = nil
            agent = nil
        }
    }
}
#endif
