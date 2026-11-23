
import Foundation

/// The board's requests in the demo (#696: its Agents, Rules, Notes and Branches pages), answered as the engine answers
/// them (`engine/src/projectrules.ts`, `knowledge.ts`, `agentrequests.ts`, `worktrees.ts`): a project's rules added,
/// changed, moved and removed; its notes added, corrected, shared and deleted; an agent's memory switch; Allow everything
/// turned off, and refused on, as the engine refuses it from a phone (docs/iphone.md 4.2, question 5); and the branches
/// looked at again. Each change sends its event again whole. Saving an agent's settings, making and removing agents and
/// worktrees are not answered yet, and are refused as the demo refuses what it does not do.
extension DemoScript {
    static let board: [String: DemoAnswer] = [
        "projects.rules.add": { request, world in
            let project = try DemoBoard.project(request, world: world)
            let text = try DemoBoard.ruleText(request.params["text"])
            let binds = try DemoBoard.binds(request.params["binds"])
            let rules = DemoBoard.rules(project, world: world)
            if rules.count >= 50 { throw DemoRefusal("This project has 50 rules, the most it can have. Remove one first.") }
            let next = (rules.compactMap { ($0["id"] as? String).flatMap { Int($0.dropFirst()) } }.max() ?? 0) + 1
            let id = "r\(next)"
            DemoBoard.changeRules(project, world: world) { rules in
                rules.append(["id": id, "text": text, "binds": binds, "addedBy": ["kind": "person"], "createdAt": world.now, "updatedAt": world.now])
            }
            return ["id": id]
        },
        "projects.rules.edit": { request, world in
            let (project, id, _) = try DemoBoard.rule(request, world: world)
            let text = try request.params["text"].map(DemoBoard.ruleText)
            let binds = try request.params["binds"].map(DemoBoard.binds)
            DemoBoard.changeRules(project, world: world) { rules in
                guard let at = rules.firstIndex(where: { $0["id"] as? String == id }) else { return }
                if let text { rules[at]["text"] = text }
                if let binds { rules[at]["binds"] = binds }
                rules[at]["updatedAt"] = world.now
            }
            return [:]
        },
        "projects.rules.move": { request, world in
            let (project, _, at) = try DemoBoard.rule(request, world: world)
            let count = DemoBoard.rules(project, world: world).count
            guard let to = request.int("to"), to >= 0, to < count else { throw DemoRefusal("to must be a whole number from 0 to \(count - 1)") }
            DemoBoard.changeRules(project, world: world) { rules in
                let rule = rules.remove(at: at)
                rules.insert(rule, at: to)
            }
            return [:]
        },
        "projects.rules.remove": { request, world in
            let (project, _, at) = try DemoBoard.rule(request, world: world)
            DemoBoard.changeRules(project, world: world) { rules in rules.remove(at: at) }
            return [:]
        },
        // A project's notes: `{ projectId, text }`, `{ projectId, id, text?, audience? }`, `{ projectId, id }`.
        "memory.add": { request, world in
            let project = try DemoBoard.project(request, world: world)
            let text = try DemoBoard.noteText(request.params["text"])
            let notes = DemoBoard.notes(project, world: world)
            if notes.count >= 60 { throw DemoRefusal("There are already 60 notes, the most there can be. Delete one first") }
            let id = "n\((notes.compactMap { ($0["id"] as? String).flatMap { Int($0.dropFirst()) } }.max() ?? 0) + 1)"
            DemoBoard.changeNotes(project, world: world) { notes in
                notes.append(["id": id, "text": text, "conversation": NSNull(), "agentId": NSNull(), "createdAt": world.now, "audience": NSNull()])
            }
            return ["id": id]
        },
        "memory.edit": { request, world in
            let project = try DemoBoard.project(request, world: world)
            let id = request.string("id") ?? ""
            let text = request.params["text"] == nil && request.params["audience"] != nil ? nil : try DemoBoard.noteText(request.params["text"])
            guard DemoBoard.notes(project, world: world).contains(where: { $0["id"] as? String == id }) else { throw DemoRefusal("That note is gone") }
            if let audience = request.params["audience"], !(audience is NSNull) {
                // A note can be kept for one of the project's agents alone; the board only ever shares one.
                guard let agent = audience as? String, DemoBoard.agents(world).contains(where: { $0["id"] as? String == agent && $0["projectId"] as? String == project }) else {
                    throw DemoRefusal("audience must be one of the project's agents, or null")
                }
            }
            DemoBoard.changeNotes(project, world: world) { notes in
                guard let at = notes.firstIndex(where: { $0["id"] as? String == id }) else { return }
                if let text { notes[at]["text"] = text }
                if let audience = request.params["audience"] { notes[at]["audience"] = audience }
            }
            return [:]
        },
        "memory.delete": { request, world in
            let project = try DemoBoard.project(request, world: world)
            let id = request.string("id")
            DemoBoard.changeNotes(project, world: world) { notes in notes.removeAll { $0["id"] as? String == id } }
            return [:]
        },
        // An agent's memory switch: `{ agentId, enabled }`.
        "memory.setEnabled": { request, world in
            let agent = try DemoBoard.agent(request.string("agentId"), world: world)
            guard let enabled = request.params["enabled"] as? Bool, CFGetTypeID(request.params["enabled"] as CFTypeRef) == CFBooleanGetTypeID() else {
                throw DemoRefusal("enabled must be true or false")
            }
            world.change("memory") { event in
                var agents = event["agents"] as? [String: Any] ?? [:]
                var record = agents[agent] as? [String: Any] ?? ["notes": [Any]()]
                record["enabled"] = enabled
                agents[agent] = record
                event["agents"] = agents
            }
            return [:]
        },
        // `{ id, on }`: off as the engine does it; on is the Mac's alone, refused as the engine refuses it from a device.
        "agents.allowEverything": { request, world in
            let id = try DemoBoard.agent(request.string("id"), world: world)
            guard let on = request.params["on"] as? Bool, CFGetTypeID(request.params["on"] as CFTypeRef) == CFBooleanGetTypeID() else {
                throw DemoRefusal("on must be true or false")
            }
            if on { throw DemoRefusal("This can be done only on the Mac, in the pi² app.") }
            world.change("agents") { event in
                event["agents"] = (event["agents"] as? [[String: Any]] ?? []).map { agent in
                    guard agent["id"] as? String == id else { return agent }
                    var agent = agent
                    agent.removeValue(forKey: "allowEverything")
                    return agent
                }
            }
            return [:]
        },
        // The demo's conversations work in no git repository, so looking again finds what it found: nothing.
        "branches.refresh": { _, _ in [:] },
    ]
}

@MainActor
enum DemoBoard {
    /// The project a request names in `projectId`, refused as the engine refuses one deleted or archived.
    static func project(_ request: DemoRequest, world: DemoWorld) throws -> String {
        guard let id = request.string("projectId") else { throw DemoRefusal("projectId must be a project's id") }
        guard let project = DemoProjects.project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
        if project["archivedAt"] is NSNumber { throw DemoRefusal("This project is archived. Restore it first.") }
        return id
    }

    static func agents(_ world: DemoWorld) -> [[String: Any]] {
        world.event("agents")?["agents"] as? [[String: Any]] ?? []
    }

    static func agent(_ id: String?, world: DemoWorld) throws -> String {
        guard let id else { throw DemoRefusal("id must be an agent's id") }
        guard agents(world).contains(where: { $0["id"] as? String == id }) else { throw DemoRefusal("Unknown agent: \(id)") }
        return id
    }

    static func ruleText(_ value: Any) throws -> String {
        guard let given = value as? String else { throw DemoRefusal("text must be a string") }
        let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count > 1_000 { throw DemoRefusal("A rule must be 1 to 1,000 characters long") }
        return text
    }

    static func binds(_ value: Any?) throws -> String {
        guard let binds = value as? String, binds == "orchestrator" || binds == "everyone" else {
            throw DemoRefusal("binds must be \"orchestrator\" or \"everyone\"")
        }
        return binds
    }

    static func noteText(_ value: Any?) throws -> String {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw DemoRefusal("Write the note first") }
        if text.count > 400 { throw DemoRefusal("A note can be 400 characters at most; this one is \(text.count)") }
        return text
    }

    static func rules(_ project: String, world: DemoWorld) -> [[String: Any]] {
        (world.event("projectRules")?["projects"] as? [String: Any])?[project] as? [[String: Any]] ?? []
    }

    /// The project, the rule a request names in `id`, and its place, or the engine's refusal.
    static func rule(_ request: DemoRequest, world: DemoWorld) throws -> (String, String, Int) {
        let project = try project(request, world: world)
        guard let id = request.string("id") else { throw DemoRefusal("id must be a rule's id") }
        guard let at = rules(project, world: world).firstIndex(where: { $0["id"] as? String == id }) else { throw DemoRefusal("Unknown rule: \(id)") }
        return (project, id, at)
    }

    /// Changes a project's rules and sends `projectRules` whole; a project with none is left out of it, as the engine does.
    static func changeRules(_ project: String, world: DemoWorld, _ body: (inout [[String: Any]]) -> Void) {
        world.change("projectRules") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            var rules = projects[project] as? [[String: Any]] ?? []
            body(&rules)
            projects[project] = rules.isEmpty ? nil : rules
            event["projects"] = projects
        }
    }

    static func notes(_ project: String, world: DemoWorld) -> [[String: Any]] {
        ((world.event("memory")?["projects"] as? [String: Any])?[project] as? [String: Any])?["notes"] as? [[String: Any]] ?? []
    }

    static func changeNotes(_ project: String, world: DemoWorld, _ body: (inout [[String: Any]]) -> Void) {
        world.change("memory") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            var record = projects[project] as? [String: Any] ?? [:]
            var notes = record["notes"] as? [[String: Any]] ?? []
            body(&notes)
            record["notes"] = notes
            projects[project] = record
            event["projects"] = projects
        }
    }
}
