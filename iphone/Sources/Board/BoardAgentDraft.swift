
import Foundation
import PiModels

/// What an agent's page keeps of the person's edits until Save (the Mac's `AgentRebase`, app/Sources/pi2): which
/// settings they changed, measured from the agent as the page last caught up with it, compared as `agents.save` would
/// store them; and what Save then sends, those settings alone, so that it never puts back a value saved elsewhere
/// meanwhile.
enum BoardAgentDraft {
    /// The agent as JSON, with the keys it is decoded from.
    static func json(_ agent: AgentProfile) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(agent),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }

    /// The top-level settings `draft` changed from `base`, so that a setting the engine only fills in or tidies does
    /// not count.
    static func edited(_ draft: AgentProfile, from base: AgentProfile) -> Set<String> {
        let mine = json(draft.asSaved), theirs = json(base.asSaved)
        return Set(mine.keys).union(theirs.keys).filter { !same(mine[$0], theirs[$0]) }
    }

    /// `latest` with every value the person changed from `base` put on top, setting by setting, so that a change saved
    /// elsewhere to anything they did not touch shows on the page (the Mac's `AgentRebase.rebase`).
    static func rebase(_ draft: AgentProfile, from base: AgentProfile, onto latest: AgentProfile) -> AgentProfile {
        var object = json(latest)
        merge(into: &object, json(draft), json(base))
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let agent = try? JSONDecoder().decode(AgentProfile.self, from: data) else { return draft }
        return agent
    }

    private static func merge(into object: inout [String: Any], _ draft: [String: Any], _ base: [String: Any]) {
        for key in Set(draft.keys).union(base.keys) where !same(draft[key], base[key]) {
            if let mine = draft[key] as? [String: Any], let theirs = base[key] as? [String: Any], var now = object[key] as? [String: Any] {
                merge(into: &now, mine, theirs)
                object[key] = now
            } else if let mine = draft[key] as? [String], let theirs = base[key] as? [String], let now = object[key] as? [String] {
                // A list of names (built-in tools, delegates, MCP servers) is a set: what the person added and removed,
                // applied to the list as it is now.
                let removed = Set(theirs).subtracting(mine)
                object[key] = now.filter { !removed.contains($0) } + mine.filter { !theirs.contains($0) && !now.contains($0) }
            } else {
                object[key] = draft[key]
            }
        }
    }

    /// What `agents.save` is sent: the edited settings of the payload the Mac sends, with the id and the name.
    static func payload(_ draft: AgentProfile, edited: Set<String>) -> [String: Any] {
        var agent = draft.payload.filter { edited.contains($0.key) }
        agent["id"] = draft.id
        agent["name"] = draft.name
        return agent
    }

    /// A name no agent among `taken` has yet, "New Agent", then "New Agent 2" and on, as the Mac makes one.
    static func uniqueName(among taken: [AgentProfile]) -> String {
        var name = "New Agent"
        var n = 2
        while taken.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            name = "New Agent \(n)"
            n += 1
        }
        return name
    }
}
