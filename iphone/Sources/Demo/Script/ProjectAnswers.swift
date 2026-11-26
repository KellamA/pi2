

import Foundation

/// A project's own requests in the demo (#684, for the projects list #685, the hub and the Dashboard #688), answered as
/// the engine answers them (`engine/src/projects.ts`, `orchestrator.ts`, `github.ts`): its switches and limits set, its
/// name changed, it archived, a fresh conversation with its orchestrator begun, and what the phone shows of it watched.
/// Each change sends the `projects` event again whole. A project's folder is the Mac's, so the demo does not change it.
extension DemoScript {
    static let projects: [String: DemoAnswer] = [
        // `{ id, folder?, settings? }`: the settings given, each checked; answers the settings now.
        "projects.set": { request, world in
            let id = try DemoProjects.live(request, world: world)
            if request.params["folder"] != nil {
                throw DemoRefusal("The demo does not change a project's folder: nothing was changed. On a Mac paired with this iPhone, pi² does it.")
            }
            guard let given = request.params["settings"] else { return ["settings": DemoProjects.project(id, world: world)?["settings"] ?? [:]] }
            let settings = try DemoProjects.changed(DemoProjects.project(id, world: world)?["settings"] as? [String: Any] ?? [:], given)
            DemoProjects.change(id, world: world) { project in
                project["settings"] = settings
                project["updatedAt"] = world.now
            }
            return ["settings": settings]
        },
        "projects.rename": { request, world in
            let id = try DemoProjects.live(request, world: world)
            guard let given = request.string("name"), !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DemoRefusal("Give the project a name")
            }
            let name = given.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.contains(where: { $0.isNewline }) { throw DemoRefusal("A project's name must be a single line") }
            if name.count > 80 { throw DemoRefusal("A project's name can be 80 characters at most; this one is \(name.count)") }
            if DemoProjects.all(world).contains(where: { $0["id"] as? String != id && !($0["deletedAt"] is NSNumber) && ($0["name"] as? String)?.lowercased() == name.lowercased() }) {
                throw DemoRefusal("There is already a project called \(name)")
            }
            DemoProjects.change(id, world: world) { project in
                project["name"] = name
                project["updatedAt"] = world.now
            }
            return [:]
        },
        // Out of the projects list; refused while anything of it works or waits (3.6).
        "projects.archive": { request, world in
            guard let id = request.string("id") else { throw DemoRefusal("id must be a project's id") }
            guard let project = DemoProjects.project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
            let working = (world.event("activity")?["runs"] as? [[String: Any]] ?? []).contains { $0["projectId"] as? String == id }
            let waiting = DemoNeeds.items(world).contains { $0["projectId"] as? String == id }
            if working || waiting { throw DemoRefusal("Stop the project's agents first.") }
            guard !(project["archivedAt"] is NSNumber) else { return [:] }
            DemoProjects.change(id, world: world) { project in
                project["archivedAt"] = world.now
                project["updatedAt"] = world.now
            }
            return [:]
        },
        // `{ id }`: a fresh conversation with the project's orchestrator (6.5); the one before is kept as an earlier one.
        "projects.startFresh": { request, world in
            guard let id = request.string("id") else { throw DemoRefusal("id must be a project's id") }
            return ["conversation": try DemoProjects.startFresh(id, world: world)]
        },
        // `{ projectId, tabs }`: what the phone shows of a project now. The engine reads the project's GitHub listing for
        // it; the demo's projects have no repository, so there is nothing to read, and the request is checked only.
        "projects.watch": { request, world in
            if request.params["projectId"] is NSNull || (request.params["tabs"] as? [Any])?.isEmpty == true { return [:] }
            guard let id = request.string("projectId"), let project = DemoProjects.project(id, world: world), !(project["deletedAt"] is NSNumber) else {
                throw DemoRefusal("Unknown project: \(request.params["projectId"] ?? "")")
            }
            guard let tabs = request.params["tabs"] as? [String], tabs.allSatisfy({ $0 == "now" || $0 == "work" }) else {
                throw DemoRefusal("tabs must be a list of now and work")
            }
            return [:]
        },
    ]
}

@MainActor
enum DemoProjects {
    static func all(_ world: DemoWorld) -> [[String: Any]] {
        world.event("projects")?["projects"] as? [[String: Any]] ?? []
    }

    static func project(_ id: String, world: DemoWorld) -> [String: Any]? {
        all(world).first { $0["id"] as? String == id }
    }

    /// The project a request names, refused as the engine refuses one deleted or archived.
    static func live(_ request: DemoRequest, world: DemoWorld) throws -> String {
        guard let id = request.string("id") else { throw DemoRefusal("id must be a project's id") }
        guard let project = project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
        if project["archivedAt"] is NSNumber { throw DemoRefusal("This project is archived. Restore it first.") }
        return id
    }

    static func change(_ id: String, world: DemoWorld, _ body: @escaping (inout [String: Any]) -> Void) {
        world.change("projects") { event in
            event["projects"] = (event["projects"] as? [[String: Any]] ?? []).map { project in
                guard project["id"] as? String == id else { return project }
                var project = project
                body(&project)
                return project
            }
        }
    }

    /// The switches of docs/projects.md 8.1, as `SWITCH_NAMES` lists them.
    static let switches = ["startAgents", "fileWork", "closeWork", "makeAgents", "addRules", "merge", "release", "passLimits"]

    /// The settings with what `given` changes, each part checked as `changeProjectSettings` checks it.
    static func changed(_ settings: [String: Any], _ given: Any) throws -> [String: Any] {
        guard let given = given as? [String: Any] else { throw DemoRefusal("settings must be an object") }
        var next = settings
        for (key, value) in given {
            switch key {
            case "wakeOnReports":
                guard let on = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
                    throw DemoRefusal("wakeOnReports must be true or false")
                }
                next["wakeOnReports"] = on
            case "withoutAsking":
                guard let value = value as? [String: Any] else { throw DemoRefusal("withoutAsking must be an object of switches") }
                var group = next["withoutAsking"] as? [String: Any] ?? [:]
                for (name, on) in value {
                    guard switches.contains(name) else { throw DemoRefusal("Unknown switch: \(name)") }
                    guard let on = on as? Bool, CFGetTypeID(on as CFTypeRef) == CFBooleanGetTypeID() else { throw DemoRefusal("\(name) must be true or false") }
                    group[name] = on
                }
                next["withoutAsking"] = group
            case "limits":
                guard let value = value as? [String: Any] else { throw DemoRefusal("limits must be an object") }
                var limits = next["limits"] as? [String: Any] ?? [:]
                for (name, limit) in value {
                    let number = (limit as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
                    switch name {
                    case "planShare":
                        guard limit is NSNull || number.map({ $0.rounded() == $0 && $0 >= 1 && $0 <= 100 }) == true else {
                            throw DemoRefusal("planShare must be a whole number from 1 to 100, or null")
                        }
                    case "dailySpend":
                        guard limit is NSNull || number.map({ $0.isFinite && $0 > 0 }) == true else {
                            throw DemoRefusal("dailySpend must be an amount above zero, or null")
                        }
                    default:
                        throw DemoRefusal("Unknown limit: \(name)")
                    }
                    limits[name] = limit
                }
                next["limits"] = limits
            default:
                throw DemoRefusal("Unknown setting: \(key)")
            }
        }
        return next
    }

    /// A fresh conversation with project `id`'s orchestrator (`startFresh`), refused as the engine refuses it while the
    /// one before still has something under way; the one before becomes an earlier one.
    /// With `agent`, that agent of the project becomes its orchestrator in the same step (`projects.setOrchestrator`).
    static func startFresh(_ id: String, agent chosen: String? = nil, world: DemoWorld) throws -> Int {
        guard let project = project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
        if project["archivedAt"] is NSNumber { throw DemoRefusal("This project is archived. Restore it first.") }
        if let chosen {
            let found = DemoSettings.agents(world).first { $0["id"] as? String == chosen }
            guard let found, found["removedAt"] == nil else { throw DemoRefusal("Unknown agent: \(chosen)") }
            let name = found["name"] as? String ?? chosen
            if found["projectId"] as? String != id { throw DemoRefusal("\(name) is not an agent of this project") }
            if chosen == project["orchestratorId"] as? String {
                throw DemoRefusal("\(name) is the project's orchestrator already. To begin again with it, start a fresh conversation.")
            }
        }
        guard let agentID = chosen ?? project["orchestratorId"] as? String else { throw DemoRefusal("The project's orchestrator was deleted") }
        let before = (project["conversation"] as? NSNumber)?.intValue
        if let before {
            if (world.event("inbox")?["items"] as? [[String: Any]] ?? []).contains(where: { ($0["conversationId"] as? NSNumber)?.intValue == before }) {
                throw DemoRefusal("Answer what the orchestrator is waiting for first.")
            }
            if (world.conversations[before]?.state["queued"] as? [Any])?.isEmpty == false {
                throw DemoRefusal("Send or take back your queued message first.")
            }
            if world.conversations[before]?.state["busy"] as? Bool == true {
                throw DemoRefusal("The orchestrator is answering. Let it finish, or stop it, first.")
            }
        }
        let fresh = world.newItemID()
        let title = project["name"] as? String ?? ""
        var agent = before.flatMap { world.conversations[$0]?.state["agent"] as? [String: Any] } ?? [:]
        agent["agentId"] = agentID
        agent["parent"] = NSNull()
        if agent["model"] == nil { agent["model"] = ["provider": "demo", "modelId": "demo-1"] }
        if let before { DemoLibrary.changeRow(before, world: world) { $0["orchestrator"] = "earlier" } }
        DemoLibrary.add(
            DemoLibrary.newRow(fresh, title: title, agentId: agentID, parent: nil, projectId: id, chat: false, orchestrator: "current",
                               freshFrom: before, now: world.now),
            state: DemoLibrary.newState(title: title, chat: false, agent: agent, project: ["id": id, "orchestrator": "current"]),
            world: world
        )
        if let before { world.changeState(of: before) { $0["project"] = ["id": id, "orchestrator": "earlier"] } }
        if let chosen, let previous = project["orchestratorId"] as? String {
            DemoAgents.change(world) { agents in
                for at in agents.indices {
                    if agents[at]["id"] as? String == previous { agents[at].removeValue(forKey: "role"); agents[at]["updatedAt"] = world.now }
                    if agents[at]["id"] as? String == chosen { agents[at]["role"] = "orchestrator"; agents[at]["updatedAt"] = world.now }
                }
            }
        }
        change(id, world: world) { project in
            if let before { project["earlier"] = (project["earlier"] as? [Any] ?? []) + [before] }
            project["conversation"] = fresh
            if let chosen { project["orchestratorId"] = chosen }
            project["updatedAt"] = world.now
        }
        return fresh
    }
}
