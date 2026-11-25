
import Foundation

/// A project's work in the demo (#694), as the engine answers it for a list pi² keeps (`engine/src/work.ts`): `work.list`,
/// filing with `work.create`, and the person's actions of the state table with `work.act` (release, resume, close,
/// reopen, note, edit, classify), each checked as `checkWorkTransition` checks it and made as `workTransition` makes it,
/// then the `work` event sent whole. `projects.watch`, which the Work screens send while they show, is answered with the
/// project's other requests (`Script/ProjectAnswers.swift`).
///
/// Giving work to an agent (`assign`) starts the agent in a new sub-chat of the orchestrator's conversation, and the demo's
/// world cannot make a conversation yet, so it refuses that one plainly rather than claim the work with no agent on it.
/// A project whose work is on GitHub (Demo site) has its items in the `github` event's listing instead, where these
/// change them as the engine's GitHub backend would after GitHub answered; its other `github.*` requests are
/// `Script/GitHubAnswers.swift`'s.
extension DemoScript {
    static let work: [String: DemoAnswer] = [
        "work.list": { request, world in
            let project = try DemoWork.project(request, world: world)
            var items = DemoWork.items(project, world: world)
            if let states = request.params["states"] {
                guard let wanted = states as? [String], wanted.allSatisfy(DemoWork.states.contains) else {
                    throw DemoRefusal("states must be a list of work states: \(DemoWork.states.joined(separator: ", "))")
                }
                items = items.filter { wanted.contains($0["state"] as? String ?? "") }
            }
            return ["items": items, "readAt": DemoGitHub.listing(project, world: world)?["readAt"] ?? NSNull()]
        },
        "work.create": { request, world in
            let project = try DemoWork.project(request, world: world, writing: true)
            let title = try DemoWork.title(request.params["title"])
            let text = try DemoWork.text(request.params["text"]) ?? ""
            var modelClass: Any = NSNull()
            if let given = request.params["class"], !(given is NSNull) {
                guard let named = given as? String, ["local", "cloud"].contains(named) else { throw DemoRefusal("class must be local, cloud, or null") }
                modelClass = named
            }
            let items = DemoWork.items(project, world: world)
            // On GitHub, issues and pull requests are numbered in one sequence.
            let pulls = DemoGitHub.listing(project, world: world)?["pulls"] as? [[String: Any]] ?? []
            let id = ((items.compactMap { ($0["id"] as? NSNumber)?.intValue } + pulls.compactMap { ($0["number"] as? NSNumber)?.intValue }).max() ?? 0) + 1
            let now = world.now
            var item: [String: Any] = [
                "id": id, "title": title, "text": text, "state": "open", "class": modelClass, "takenBy": NSNull(), "notes": [Any](),
                "result": NSNull(), "filedBy": ["kind": "person"], "createdAt": now, "updatedAt": now, "closedAt": NSNull(),
            ]
            if DemoGitHub.listing(project, world: world) != nil {
                item["url"] = "https://github.com/\(DemoGitHub.repository(project, world: world))/issues/\(id)"
            }
            DemoWork.save(project, items + [item], world: world)
            return ["id": id]
        },
        "work.act": { request, world in
            let project = try DemoWork.project(request, world: world, writing: true)
            guard let action = request.string("action"), DemoWork.actions.contains(action) else {
                throw DemoRefusal("Unknown work action: \(request.params["action"].map { "\($0)" } ?? "undefined")")
            }
            if action == "file" { throw DemoRefusal("Use work.create to file work.") }
            guard let id = request.int("id"), id >= 1 else { throw DemoRefusal("id must be a work item's positive whole number") }
            var items = DemoWork.items(project, world: world)
            guard let index = items.firstIndex(where: { ($0["id"] as? NSNumber)?.intValue == id }) else {
                throw DemoRefusal("Unknown work item: #\(id)")
            }
            let item = try DemoWork.transition(items[index], action: action, params: request.params, world: world)
            if !NSDictionary(dictionary: item).isEqual(to: items[index]) {
                items[index] = item
                DemoWork.save(project, items, world: world)
            }
            return ["item": item]
        },
    ]
}

@MainActor
enum DemoWork {
    static let states = ["open", "in_progress", "waiting", "blocked", "done", "dropped"]
    static let actions = ["file", "take", "assign", "release", "wait", "block", "resume", "finish", "close", "reopen", "note", "edit", "classify"]
    private static let held = ["in_progress", "waiting", "blocked"]
    private static let closed = ["done", "dropped"]

    /// The state table's rows the person may use (`table` in `engine/src/work.ts`): the states each starts from, and the
    /// state it leaves (nil for the same, "as" for the one `as` names).
    private static let rows: [String: (from: [String], to: String?)] = [
        "assign": (["open"], "in_progress"),
        "release": (held, "open"),
        "resume": (["waiting", "blocked"], "in_progress"),
        "close": (["open"] + held, "as"),
        "reopen": (closed, "open"),
        "note": (states, nil),
        "edit": (states, nil),
        "classify": (states, nil),
    ]

    /// The project a request names, as the engine's `getProject` finds it.
    static func project(_ request: DemoRequest, world: DemoWorld, writing: Bool = false) throws -> String {
        guard let id = request.string("projectId") else { throw DemoRefusal("projectId must be a project's id") }
        let project = (world.event("projects")?["projects"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id }
        guard let project, project["deletedAt"] == nil || project["deletedAt"] is NSNull else { throw DemoRefusal("Unknown project: \(id)") }
        if writing, let archived = project["archivedAt"], !(archived is NSNull) {
            throw DemoRefusal("This project is archived. Unarchive it to change it.")
        }
        return id
    }

    static func items(_ project: String, world: DemoWorld) -> [[String: Any]] {
        if let listing = DemoGitHub.listing(project, world: world) { return listing["issues"] as? [[String: Any]] ?? [] }
        return (world.event("work")?["projects"] as? [String: Any])?[project] as? [[String: Any]] ?? []
    }

    /// Keeps the project's list and sends the `work` event whole, as the engine broadcasts it after a change; or, for a
    /// project whose work is on GitHub, the `github` event, as the engine does once it has read the change back.
    static func save(_ project: String, _ items: [[String: Any]], world: DemoWorld) {
        if DemoGitHub.listing(project, world: world) != nil {
            world.change("github") { event in
                var projects = event["projects"] as? [String: Any] ?? [:]
                var listing = projects[project] as? [String: Any] ?? [:]
                listing["issues"] = items.sorted { ($0["id"] as? NSNumber)?.intValue ?? 0 > ($1["id"] as? NSNumber)?.intValue ?? 0 }
                projects[project] = listing
                event["projects"] = projects
            }
            return
        }
        world.change("work") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            projects[project] = items
            event["projects"] = projects
        }
    }

    static func title(_ value: Any?) throws -> String {
        guard value == nil || value is String else { throw DemoRefusal("title must be text") }
        let title = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(title.count) else { throw DemoRefusal("title must be 1 to 200 characters") }
        return title
    }

    static func text(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String else { throw DemoRefusal("text must be text") }
        guard text.count <= 20_000 else { throw DemoRefusal("text must be at most 20,000 characters") }
        return text
    }

    /// One action of the person's on an item: checked as `checkWorkTransition` checks it, made as `workTransition` makes it.
    static func transition(_ before: [String: Any], action: String, params: [String: Any], world: DemoWorld) throws -> [String: Any] {
        let id = (before["id"] as? NSNumber)?.intValue ?? 0
        let state = before["state"] as? String ?? "open"
        guard let row = rows[action] else {
            throw DemoRefusal("The person cannot use \(action). Ask the agent holding the work, or use release or close.")
        }
        if action == "assign" {
            if let holder = before["takenBy"] as? [String: Any] {
                let name = agentName(holder["agentId"] as? String, world: world)
                throw DemoRefusal("#\(id) is taken by \(name), in sub-chat \((holder["conversationId"] as? NSNumber)?.intValue ?? 0)")
            }
        }
        guard row.from.contains(state) else {
            let next = closed.contains(state) ? " Reopen it first." : state == "open" ? " Take or assign it first." : " Check the work list and choose an action for that state."
            throw DemoRefusal("#\(id) is \(state).\(next)")
        }
        if action == "assign" {
            let agent = (params["agentId"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let known = (world.event("agents")?["agents"] as? [[String: Any]] ?? []).contains {
                $0["id"] as? String == agent && ($0["removedAt"] == nil || $0["removedAt"] is NSNull)
            }
            guard known else { throw DemoRefusal("Unknown agent: \(agent)") }
            throw DemoRefusal("The demo does not start agents, so #\(id) was not given to \(agentName(agent, world: world)): nothing was changed. On a Mac paired with this iPhone, \(agentName(agent, world: world)) starts on it in a sub-chat of the orchestrator's conversation.")
        }

        var item = before
        let text = params["text"]
        guard text == nil || text is String else { throw DemoRefusal("text must be text") }
        if action == "classify" {
            let given = params["class"]
            guard given == nil || given is NSNull || ["local", "cloud"].contains(given as? String ?? "") else {
                throw DemoRefusal("class must be local, cloud, or null")
            }
            item["class"] = given ?? NSNull()
        }
        if row.to == "as" {
            guard let closing = params["as"] as? String, closed.contains(closing) else { throw DemoRefusal("as must be done or dropped") }
            item["state"] = closing
        } else if let to = row.to {
            item["state"] = to
        }
        if ["release", "close", "reopen"].contains(action) {
            item["takenBy"] = NSNull()
            item.removeValue(forKey: "heldAtClose")
        }
        let now = world.now
        if action == "note" {
            guard let words = text as? String, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DemoRefusal("text must say what to note")
            }
            item["notes"] = (item["notes"] as? [Any] ?? []) + [["at": now, "by": ["kind": "person"], "text": words]]
        }
        if action == "edit" {
            if params["title"] != nil { item["title"] = try title(params["title"]) }
            if let words = try self.text(text) { item["text"] = words }
        }
        if action == "close" {
            item["closedAt"] = now
            item["result"] = item["state"] as? String == "done" ? (text ?? NSNull()) : NSNull()
        } else if action == "reopen" {
            item["closedAt"] = NSNull()
            item["result"] = NSNull()
        }
        if !NSDictionary(dictionary: item).isEqual(to: before) { item["updatedAt"] = now }
        return item
    }

    private static func agentName(_ id: String?, world: DemoWorld) -> String {
        let agent = (world.event("agents")?["agents"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id }
        return agent?["name"] as? String ?? id ?? "an agent"
    }
}
