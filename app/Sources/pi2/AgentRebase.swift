import Foundation
import PiModels

/// An agent's page keeps the person's edits when the agent is saved elsewhere meanwhile (#299): the page shows the agent
/// as it is now with the fields the person changed on top, and Save sends only those, so it never puts back the values
/// the page started from over newer ones.
enum AgentRebase {
    /// The agent as JSON, with the keys it is decoded from.
    static func json(_ agent: AgentProfile) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(agent),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }

    /// The top-level settings the form changed from `base`, compared as they would be stored, so a setting the engine
    /// only fills in or tidies does not count.
    static func edited(_ draft: AgentProfile, from base: AgentProfile) -> Set<String> {
        let mine = json(draft.asSaved), theirs = json(base.asSaved)
        return Set(mine.keys).union(theirs.keys).filter { !same(mine[$0], theirs[$0]) }
    }

    /// `latest` with every value the form changed from `base` put on top, setting by setting (inside computer use, the
    /// browser and the schedule too), so a change saved elsewhere to anything the person did not touch shows.
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
                // A list of names (built-in tools, delegates, MCP servers, apps) is a set: what the person added and
                // removed, applied to the list as it is now, so a switch changed elsewhere in the same list shows too.
                let removed = Set(theirs).subtracting(mine)
                object[key] = now.filter { !removed.contains($0) } + mine.filter { !theirs.contains($0) && !now.contains($0) }
            } else {
                object[key] = draft[key]
            }
        }
    }
}
