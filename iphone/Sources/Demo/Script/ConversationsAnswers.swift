
import Foundation

/// The conversations' screens' requests in the demo (#698: other conversations, chats, the Archive, background commands),
/// answered as the engine answers them (`engine/src/main.ts`, `settingsrequests.ts`, `background.ts`, `projects.ts`,
/// `carryover.ts`): a conversation renamed or deleted, archiving on its own set, an archived project restored, and the
/// refusals the engine gives for what the demo's world has none of (no background command, no deleted project). Each
/// change sends the event it changes again whole.
///
/// And a new project (`engine/src/folders.ts`, `projects.ts`): the folders the Mac offers, and a project made from one,
/// or with none, with its orchestrator and an empty conversation with it, as the engine makes them in one step.
extension DemoScript {
    static let conversationsScreens: [String: DemoAnswer] = [
        // `{}`: the folders already used with pi², as `offeredFolders` lists them.
        "projects.folders": { _, world in
            ["folders": DemoNewProject.folders(world)]
        },
        // `{ id, path }`: a file the conversation's agent linked to. The demo's agents' answers link to no file, so the
        // engine's refusal for one not linked (`NOT_LINKED`, folders.ts).
        "files.preview": { request, world in
            _ = try DemoConversations.known(request, world: world)
            guard request.params["path"] is String else { throw DemoRefusal("That is not the path of a file on the Mac.") }
            throw DemoRefusal(DemoConversations.notLinked)
        },
        // `{ folder, name?, template? }`: from a phone, a folder only among those offered; answers `{ id, conversation }`.
        "projects.create": { request, world in
            try DemoNewProject.create(request, world: world)
        },
        // `{ id, title }`: the title, trimmed and at most 120 characters; the engine names it no more from its messages.
        "conversation.rename": { request, world in
            let id = try DemoConversations.known(request, world: world)
            guard let given = request.params["title"] as? String else { throw DemoRefusal("title must be text") }
            let title = String(given.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            DemoConversations.changeRow(id, world: world) { $0["title"] = title }
            world.changeState(of: id) { $0["title"] = title }
            return [:]
        },
        // `{ id }`: what it does is stopped, and it is shown nowhere again, its sub-chats with it.
        "conversation.delete": { request, world in
            let id = try DemoConversations.known(request, world: world)
            DemoConversations.delete(id, world: world)
            return [:]
        },
        // `{ days }`: a whole number of days from 1 to 3650, or null for never, sent in the `library` event.
        "settings.setAutoArchive": { request, world in
            let days = request.params["days"]
            if days == nil || days is NSNull {
                world.change("library") { $0["autoArchiveDays"] = NSNull() }
                return [:]
            }
            guard let number = days as? NSNumber, !(days is Bool), number.doubleValue == number.doubleValue.rounded(),
                  (1...3650).contains(number.intValue) else {
                throw DemoRefusal("Choose a whole number of days from 1 to 3650, or never")
            }
            world.change("library") { $0["autoArchiveDays"] = number.intValue }
            // The engine archives at once what the setting now catches; the demo's conversations are all in use.
            return [:]
        },
        // The demo's agents start no command in the background, so there is no output to read and none to stop.
        "background.output": { _, _ in
            throw DemoRefusal("pi² no longer has this command's output. While its engine runs, it keeps the output of the commands running and of the last 50 that ended.")
        },
        // A text file a conversation links to (`folders.ts`, `previewFile`). The recording's answers link to no file, and the
        // demo has no files to read, so it refuses as the engine refuses a path the conversation does not link to.
        "files.preview": { request, world in
            let id = request.int("id") ?? -1
            guard let conversation = world.conversations[id] else { throw DemoRefusal("Unknown conversation: \(request.params["id"] ?? "undefined")") }
            guard request.params["path"] is String else { throw DemoRefusal("That is not the path of a file on the Mac.") }
            guard (conversation.state["agent"] as? [String: Any])?["cwd"] is String else {
                throw DemoRefusal("This conversation has no folder, so none of its files is shown on the phone.")
            }
            throw DemoRefusal("The conversation does not link to that file. Only a file its agent's answers link to is shown on the phone.")
        },
        "background.stop": { _, _ in
            throw DemoRefusal("That command is no longer running")
        },
        // `{ id }`: back in the projects list.
        "projects.unarchive": { request, world in
            guard let id = request.string("id") else { throw DemoRefusal("id must be a project's id") }
            guard let project = DemoProjects.project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
            guard project["archivedAt"] is NSNumber else { return [:] }
            DemoProjects.change(id, world: world) { project in
                project["archivedAt"] = NSNull()
                project["updatedAt"] = world.now
            }
            return [:]
        },
        // `{ id, dryRun?, plan? }`: the demo deletes no project, so every conversation is refused as the engine refuses
        // one that is not of a deleted project.
        "projects.restoreConversation": { request, world in
            guard let id = request.int("id") else { throw DemoRefusal("id must be a conversation's id") }
            if let dryRun = request.params["dryRun"], !(dryRun is Bool) { throw DemoRefusal("dryRun must be true or false") }
            let row = DemoLibrary.row(id, world: world) ?? DemoLibrary.archivedRows(world).first { ($0["id"] as? NSNumber)?.intValue == id }
            guard let row else { throw DemoRefusal("Unknown conversation: \(id)") }
            if row["parent"] is NSNumber { throw DemoRefusal("A sub-chat is restored with the conversation it belongs to. Restore that one.") }
            let project = (row["projectId"] as? String).flatMap { DemoProjects.project($0, world: world) }
            guard project?["deletedAt"] is NSNumber else { throw DemoRefusal("This conversation is not of a deleted project.") }
            throw DemoRefusal("The demo does not do projects.restoreConversation: nothing was changed. On a Mac paired with this iPhone, pi² does it.")
        },
    ]
}

/// A new project in the demo (#698), as `projects.folders` and `projects.create` make it in the engine.
@MainActor
enum DemoNewProject {
    /// The engine's words for a folder it does not offer (`NOT_OFFERED` in folders.ts).
    static let notOffered = "That folder is not one your Mac offers for a new project. Choose one it offers, or make the project on the Mac."

    private static func time(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    /// The folders the projects, the agents and the conversations of the world use, as `offeredFolders` lists them: free
    /// ones first, the one used last first, then the projects', at most 50, and none in the Mac's data folder. The
    /// recording's two folders are in its copy's data folder (`~/Library/Application Support/pi2-demo`), where
    /// `test-copy fill` makes them, so the demo's Mac offers none, as a real one would not.
    static func folders(_ world: DemoWorld) -> [[String: Any]] {
        var used: [String: Double] = [:]
        func use(_ path: Any?, _ at: Double) {
            guard let path = path as? String, path.hasPrefix("/"), path != "/", !inDataFolder(path) else { return }
            used[path] = max(used[path] ?? 0, at)
        }
        let projects = DemoProjects.all(world).filter { !($0["deletedAt"] is NSNumber) }
        for project in projects { use(project["folder"], time(project["updatedAt"])) }
        for agent in DemoSettings.agents(world) where !(agent["removedAt"] is NSNumber) {
            use(agent["cwd"], max(time(agent["updatedAt"]), time(agent["createdAt"])))
        }
        for row in DemoLibrary.rows(world) + DemoLibrary.archivedRows(world) where !(row["parent"] is NSNumber) && row["chat"] as? Bool != true {
            guard let id = (row["id"] as? NSNumber)?.intValue else { continue }
            use((world.conversations[id]?.state["agent"] as? [String: Any])?["cwd"], time(row["updatedAt"]))
        }
        let owner = Dictionary(projects.compactMap { project in (project["folder"] as? String).map { ($0, project) } }) { first, _ in first }
        let ordered = used.sorted { a, b in
            let (takenA, takenB) = (owner[a.key] != nil, owner[b.key] != nil)
            return takenA != takenB ? !takenA : a.value != b.value ? a.value > b.value : a.key < b.key
        }
        return ordered.prefix(50).map { path, _ in
            let url = URL(fileURLWithPath: path)
            var folder: [String: Any] = ["path": path, "name": url.lastPathComponent, "where": shown(url.deletingLastPathComponent().path)]
            if let project = owner[path] {
                folder["project"] = project["name"] ?? ""
                if let repository = project["repository"] as? [String: Any], let name = repository["name"] as? String, let of = repository["owner"] as? String {
                    folder["repository"] = "\(of)/\(name)"
                }
            }
            return folder
        }
    }

    /// Whether `path` is in a pi² data folder (`~/Library/Application Support/pi2`, or a copy's `pi2-<suffix>`), which
    /// the engine never offers.
    private static func inDataFolder(_ path: String) -> Bool {
        path.range(of: #"^/Users/[^/]+/Library/Application Support/pi2(-[a-z0-9-]+)?(/|$)"#, options: .regularExpression) != nil
    }

    /// A path with the Mac's home folder written `~`: the recording's Mac's home is `/Users/<name>`.
    private static func shown(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/Users/"), parts.count >= 2 else { return path }
        return (["~"] + parts.dropFirst(2)).joined(separator: "/")
    }

    /// `projects.create` from the phone: checked as the engine checks it, then the project, its orchestrator (a copy of
    /// the template, or pi²'s default orchestrator) and its empty conversation, each sent in its event.
    static func create(_ request: DemoRequest, world: DemoWorld) throws -> [String: Any] {
        guard let given = request.params["folder"] else { throw DemoRefusal("folder must be a folder's path, or null") }
        var folder: String?
        if !(given is NSNull) {
            guard let path = given as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw DemoRefusal("folder must be a folder's path, or null")
            }
            guard folders(world).contains(where: { $0["path"] as? String == path }) else { throw DemoRefusal(notOffered) }
            folder = path
        }
        var name: String?
        if let typed = request.params["name"], !(typed is NSNull) {
            guard let typed = typed as? String, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DemoRefusal("Give the project a name") }
            let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(where: { $0.isNewline }) { throw DemoRefusal("A project's name must be a single line") }
            if trimmed.count > 80 { throw DemoRefusal("A project's name can be 80 characters at most; this one is \(trimmed.count)") }
            name = trimmed
        }
        var template: [String: Any]?
        if let chosen = request.params["template"], !(chosen is NSNull) {
            template = DemoSettings.agents(world).first {
                $0["id"] as? String == chosen as? String && $0["projectId"] == nil && !($0["removedAt"] is NSNumber)
            }
            if template == nil { throw DemoRefusal("Unknown agent: \(chosen)") }
        }
        let live = DemoProjects.all(world).filter { !($0["deletedAt"] is NSNumber) }
        if let folder, let same = live.first(where: { $0["folder"] as? String == folder }) {
            throw DemoRefusal("There is already a project for this folder: \(same["name"] ?? "")\(same["archivedAt"] is NSNumber ? "; restore it instead" : "")")
        }
        let taken = { (candidate: String) in live.contains { ($0["name"] as? String)?.lowercased() == candidate.lowercased() } }
        if let name, taken(name) { throw DemoRefusal("There is already a project called \(name)") }
        var chosenName = name ?? ""
        if name == nil {
            let base = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No folder"
            var number = 1
            while chosenName.isEmpty || taken(chosenName) {
                let suffix = number == 1 ? "" : " \(number)"
                chosenName = String(base.prefix(80 - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
                number += 1
            }
        }

        let now = world.now
        let projectID = "p-\(UUID().uuidString.lowercased())"
        var agent: [String: Any]
        if let template {
            agent = template
            for key in ["allowEverything", "variables", "madeBy", "removedAt"] { agent[key] = nil }
            agent["template"] = ["id": template["id"] ?? "", "copiedAt": now, "templateUpdatedAt": template["updatedAt"] ?? template["createdAt"] ?? now]
        } else {
            // pi²'s default orchestrator, as the recording's projects have it.
            agent = DemoSettings.agents(world).first { $0["role"] as? String == "orchestrator" && $0["template"] == nil } ?? ["name": "Orchestrator", "access": "ask"]
            agent["template"] = nil
        }
        let agentName = agent["name"] as? String ?? "Orchestrator"
        let slug = agentName.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        agent["id"] = "\(slug.isEmpty ? "agent" : slug)-\(UUID().uuidString.lowercased())"
        agent["cwd"] = folder ?? NSNull()
        agent["delegates"] = [String]()
        agent["createdAt"] = now
        agent["updatedAt"] = now
        agent["projectId"] = projectID
        agent["role"] = "orchestrator"
        let agentID = agent["id"] as? String ?? ""
        world.change("agents") { event in event["agents"] = (event["agents"] as? [[String: Any]] ?? []) + [agent] }

        let conversation = world.newItemID()
        let state: [String: Any] = [
            "model": agent["model"] ?? ["provider": "demo", "modelId": "demo-1"], "thinkingLevel": agent["thinkingLevel"] ?? NSNull(),
            "cwd": folder ?? NSNull(), "access": agent["access"] ?? "ask", "agentId": agentID, "parent": NSNull(),
        ]
        DemoLibrary.add(
            DemoLibrary.newRow(conversation, title: "", agentId: agentID, parent: nil, projectId: projectID, chat: false, orchestrator: "current", now: now),
            state: DemoLibrary.newState(title: "", chat: false, agent: state, project: ["id": projectID, "orchestrator": "current"]),
            world: world
        )
        let project: [String: Any] = [
            "id": projectID, "name": chosenName, "folder": folder ?? NSNull(), "repository": NSNull(), "orchestratorId": agentID,
            "conversation": conversation, "earlier": [Int](),
            "settings": [
                "wakeOnReports": false,
                "withoutAsking": ["startAgents": true, "fileWork": true, "closeWork": true, "makeAgents": true, "addRules": true,
                                  "merge": false, "release": false, "passLimits": false],
                "limits": ["planShare": 90, "dailySpend": NSNull()],
            ],
            "createdAt": now, "updatedAt": now, "folderMissing": false, "ruleTokens": ["orchestrator": 0, "agents": 0], "lastWords": NSNull(),
        ]
        world.change("projects") { event in event["projects"] = (event["projects"] as? [[String: Any]] ?? []) + [project] }
        return ["id": projectID, "conversation": conversation]
    }
}

@MainActor
enum DemoConversations {
    /// The conversation a request names, in the list or the Archive, or the engine's refusal.
    /// The engine's words for a file the conversation does not link to (`NOT_LINKED`, `engine/src/folders.ts`).
    static let notLinked = "The conversation does not link to that file. Only a file its agent's answers link to is shown on the phone."

    static func known(_ request: DemoRequest, world: DemoWorld) throws -> Int {
        guard let id = request.int("id"), DemoLibrary.row(id, world: world) != nil || DemoLibrary.isArchived(id, world: world) else {
            throw DemoRefusal("Unknown conversation: \(request.params["id"] ?? "")")
        }
        return id
    }

    /// Changes a row wherever the `library` event lists it: in the list or in the Archive.
    static func changeRow(_ id: Int, world: DemoWorld, _ body: @escaping (inout [String: Any]) -> Void) {
        world.change("library") { library in
            for key in ["conversations", "archived"] {
                library[key] = (library[key] as? [[String: Any]] ?? []).map { row in
                    guard (row["id"] as? NSNumber)?.intValue == id else { return row }
                    var row = row
                    body(&row)
                    return row
                }
            }
        }
    }

    /// Stops what it and its sub-chats do, and takes them out of the list and the Archive (`conversation.delete`).
    static func delete(_ id: Int, world: DemoWorld) {
        let gone = Set(DemoLibrary.rows(world).filter {
            ($0["id"] as? NSNumber)?.intValue == id || ($0["parent"] as? NSNumber)?.intValue == id
        }.compactMap { ($0["id"] as? NSNumber)?.intValue }).union([id])
        for each in gone where DemoLibrary.row(each, world: world) != nil { DemoRuns.stop(each, world: world) }
        world.change("library") { library in
            for key in ["conversations", "archived"] {
                library[key] = (library[key] as? [[String: Any]] ?? []).filter { !gone.contains(($0["id"] as? NSNumber)?.intValue ?? -1) }
            }
        }
    }
}
