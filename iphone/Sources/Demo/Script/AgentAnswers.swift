import Foundation

/// Agents in the demo (#684; the board's Agents page and an agent's page, #696, and the settings' model and summary size,
/// #697), answered as the engine answers them: `agentrequests.ts` (`agents.save`, `.duplicate`, `.delete`, `rules.add`,
/// `.remove`), `projectagents.ts` (`projects.addAgent`, `agents.restore`, `.updateFromTemplate`), `orchestrator.ts`
/// (`projects.setOrchestrator`) and `main.ts` (`conversation.create` for an agent, in `Script/LibraryAnswers.swift`).
/// Each checks what the engine checks, refuses in its words, and sends the `agents` event whole again. The demo has no
/// file system, so a folder is one the recording names: a project's, or an agent's.
extension DemoScript {
    static let agents: [String: DemoAnswer] = [
        "agents.save": { request, world in
            guard let given = request.params["agent"] as? [String: Any] else { throw DemoRefusal("Give the agent a name") }
            return ["id": try DemoAgents.save(given, world: world)]
        },
        // A copy of an agent's saved settings, "<name> copy", in the same project; neither its role nor its template.
        "agents.duplicate": { request, world in
            let source = try DemoAgents.agent(request.string("id"), world: world)
            var copy = source
            for key in ["id", "role", "template", "madeBy", "removedAt", "allowEverything", "variables", "updatedAt", "createdAt"] {
                copy.removeValue(forKey: key)
            }
            copy["name"] = "\(source["name"] as? String ?? "Agent") copy"
            let id = try DemoAgents.save(copy, world: world, project: source["projectId"] as? String, copying: source["commandRules"] as? [Any] ?? [])
            DemoAgents.copyMemorySwitch(from: source["id"] as? String ?? "", to: id, world: world)
            return ["id": id]
        },
        "agents.delete": { request, world in
            let id = request.string("id") ?? ""
            let agents = DemoAgents.all(world)
            guard let agent = agents.first(where: { $0["id"] as? String == id }) else { throw DemoRefusal("Unknown agent: \(id)") }
            if agent["projectId"] == nil, agents.filter({ $0["projectId"] == nil }).count == 1 { throw DemoRefusal("Keep at least one agent") }
            if agent["role"] as? String == "orchestrator" {
                throw DemoRefusal("\(agent["name"] as? String ?? id) is the project's orchestrator. Make another agent the orchestrator first.")
            }
            DemoAgents.change(world) { agents in
                agents = agents.filter { $0["id"] as? String != id }.map { other in
                    var other = other
                    if let delegates = other["delegates"] as? [String] { other["delegates"] = delegates.filter { $0 != id } }
                    return other
                }
            }
            return [:]
        },
        // An agent removed through a tool, put back; nothing to do for one not removed.
        "agents.restore": { request, world in
            let agent = DemoAgents.all(world).first { $0["id"] as? String == request.string("id") }
            guard let agent, let project = agent["projectId"] as? String else { throw DemoRefusal("Unknown agent: \(request.params["id"] ?? "undefined")") }
            try DemoAgents.project(project, world: world, changing: true)
            guard agent["removedAt"] != nil else { return [:] }
            DemoAgents.update(agent["id"] as? String ?? "", world: world) { $0.removeValue(forKey: "removedAt") }
            return [:]
        },
        "agents.updateFromTemplate": { request, world in
            if let apply = request.params["apply"], !DemoSettings.isBool(apply) { throw DemoRefusal("apply must be true or false") }
            let apply = request.params["apply"] as? Bool == true
            let copy = DemoAgents.all(world).first { $0["id"] as? String == request.string("id") }
            guard let copy, let project = copy["projectId"] as? String, copy["removedAt"] == nil else {
                throw DemoRefusal("Unknown agent: \(request.params["id"] ?? "undefined")")
            }
            try DemoAgents.project(project, world: world, changing: apply)
            guard let from = copy["template"] as? [String: Any], let templateID = from["id"] as? String else {
                throw DemoRefusal("\(copy["name"] as? String ?? "This agent") was not made from a template")
            }
            guard let template = DemoAgents.all(world).first(where: { $0["id"] as? String == templateID && $0["projectId"] == nil }) else {
                throw DemoRefusal("The template this agent was made from has been deleted")
            }
            let changes = DemoAgents.templateChanges(copy, template, world: world)
            guard apply else { return ["changes": changes, "applied": false] }
            var settings: [String: Any] = ["id": copy["id"] ?? "", "name": copy["name"] ?? ""]
            for change in changes where change["setting"] as? String != "memory" {
                if let setting = change["setting"] as? String { settings[setting] = change["template"] }
            }
            _ = try DemoAgents.save(settings, world: world, marks: [
                "template": ["id": templateID, "copiedAt": world.now, "templateUpdatedAt": template["updatedAt"] ?? template["createdAt"] ?? world.now],
            ])
            if changes.contains(where: { $0["setting"] as? String == "memory" }) {
                DemoAgents.copyMemorySwitch(from: templateID, to: copy["id"] as? String ?? "", world: world)
            }
            return ["changes": changes, "applied": true]
        },
        // `{ projectId, template? | agent? }`: a copy of a template in the project, or an agent made from settings.
        "projects.addAgent": { request, world in
            guard let projectID = request.string("projectId") else { throw DemoRefusal("Unknown project: \(request.params["projectId"] ?? "undefined")") }
            let project = try DemoAgents.project(projectID, world: world, changing: true)
            if request.params["template"] != nil, request.params["agent"] != nil {
                throw DemoRefusal("Give a template to copy, or the agent's settings, not both")
            }
            if let templateID = request.params["template"] {
                let agents = DemoAgents.all(world)
                guard let template = agents.first(where: { $0["id"] as? String == templateID as? String && $0["projectId"] == nil }) else {
                    throw DemoRefusal("Unknown agent: \(templateID)")
                }
                // Its delegates mapped to the project's copies of the templates they name.
                let copies = { (id: String) in
                    agents.filter { $0["projectId"] as? String == projectID && ($0["template"] as? [String: Any])?["id"] as? String == id }
                        .min { ($0["createdAt"] as? Double ?? 0) < ($1["createdAt"] as? Double ?? 0) }?["id"] as? String
                }
                var copy = template
                for key in ["id", "allowEverything", "variables", "madeBy", "removedAt", "updatedAt", "createdAt"] { copy.removeValue(forKey: key) }
                copy["cwd"] = project["folder"] ?? NSNull()
                copy["delegates"] = (template["delegates"] as? [String] ?? []).compactMap(copies)
                let id = try DemoAgents.save(copy, world: world, project: projectID, copying: template["commandRules"] as? [Any] ?? [], marks: [
                    "template": ["id": template["id"] ?? "", "copiedAt": world.now, "templateUpdatedAt": template["updatedAt"] ?? template["createdAt"] ?? world.now],
                ])
                DemoAgents.copyMemorySwitch(from: template["id"] as? String ?? "", to: id, world: world)
                return ["id": id]
            }
            guard var settings = request.params["agent"] as? [String: Any] else {
                throw DemoRefusal("agent must be the agent's settings, or give a template to copy")
            }
            settings.removeValue(forKey: "id")
            return ["id": try DemoAgents.save(settings, world: world, project: projectID)]
        },
        // Another agent of the project as its orchestrator, with a fresh conversation (6.5).
        "projects.setOrchestrator": { request, world in
            guard let id = request.string("id") else { throw DemoRefusal("id must be a project's id") }
            guard let agentID = request.string("agentId") else { throw DemoRefusal("agentId must be an agent's id") }
            return ["conversation": try DemoProjects.startFresh(id, agent: agentID, world: world)]
        },
        // An allowed command typed in an agent's settings: `{ agentId, folder, command }`.
        "rules.add": { request, world in
            let agentID = request.string("agentId") ?? ""
            guard DemoAgents.all(world).contains(where: { $0["id"] as? String == agentID }) else { throw DemoRefusal("Unknown agent: \(agentID)") }
            let folder = try request.requireString("folder")
            guard DemoAgents.isFolder(folder, world: world) else { throw DemoRefusal("Not a folder: \(folder)") }
            let words = try DemoAgents.words(try request.requireString("command"))
            let rule: [String: Any] = ["folder": folder, "words": words, "createdAt": world.now]
            DemoAgents.update(agentID, world: world) { agent in
                var rules = agent["commandRules"] as? [[String: Any]] ?? []
                if !rules.contains(where: { $0["folder"] as? String == folder && $0["words"] as? [String] == words }) { rules.append(rule) }
                agent["commandRules"] = rules
            }
            return ["rule": rule]
        },
        "rules.remove": { request, world in
            guard let words = request.params["words"] as? [String] else { throw DemoRefusal("words must be a list of words") }
            let agentID = try request.requireString("agentId")
            let folder = try request.requireString("folder")
            guard let agent = DemoAgents.all(world).first(where: { $0["id"] as? String == agentID }) else { throw DemoRefusal("Unknown agent: \(agentID)") }
            let rules = agent["commandRules"] as? [[String: Any]] ?? []
            let kept = rules.filter { !($0["folder"] as? String == folder && $0["words"] as? [String] == words) }
            if kept.count == rules.count { throw DemoRefusal("That allowed command is already gone") }
            DemoAgents.update(agentID, world: world) { $0["commandRules"] = kept }
            return [:]
        },
    ]
}

@MainActor
enum DemoAgents {
    static let accessLevels = ["none", "ask", "full"]
    /// The settings Update from template compares, in its order (`TEMPLATE_SETTINGS`), with each one's value when unset.
    static let templateSettings: [(String, Any)] = [
        ("description", ""), ("color", "violet"), ("model", NSNull()), ("thinkingLevel", NSNull()), ("instructions", ""),
        ("access", "none"), ("worktree", false), ("setup", ""), ("maxTurns", NSNull()), ("codeMode", false), ("mcpServers", [Any]()),
        ("files", [Any]()), ("computer", ["enabled": false, "apps": [Any](), "ask": true, "testCopies": false]),
        ("browser", ["enabled": false, "ask": true]), ("schedule", ["enabled": false]), ("toolsOff", [Any]()), ("toolsOn", [Any]()),
        ("compactionTokens", NSNull()),
    ]

    static func all(_ world: DemoWorld) -> [[String: Any]] { DemoSettings.agents(world) }

    static func agent(_ id: String?, world: DemoWorld) throws -> [String: Any] {
        guard let agent = all(world).first(where: { $0["id"] as? String == id }) else { throw DemoRefusal("Unknown agent: \(id ?? "undefined")") }
        return agent
    }

    /// A project that exists and was not deleted; for a change, not archived either.
    @discardableResult
    static func project(_ id: String, world: DemoWorld, changing: Bool) throws -> [String: Any] {
        guard let project = DemoProjects.project(id, world: world), !(project["deletedAt"] is NSNumber) else { throw DemoRefusal("Unknown project: \(id)") }
        if changing, project["archivedAt"] is NSNumber { throw DemoRefusal(DemoSettings.archived) }
        return project
    }

    static func change(_ world: DemoWorld, _ body: (inout [[String: Any]]) -> Void) {
        world.change("agents") { event in
            var agents = event["agents"] as? [[String: Any]] ?? []
            body(&agents)
            event["agents"] = agents
        }
    }

    static func update(_ id: String, world: DemoWorld, _ body: (inout [String: Any]) -> Void) {
        change(world) { agents in
            guard let at = agents.firstIndex(where: { $0["id"] as? String == id }) else { return }
            body(&agents[at])
        }
    }

    /// A folder the recording knows: a project's, an agent's, or a conversation's checkout.
    static func isFolder(_ path: String, world: DemoWorld) -> Bool {
        let known = DemoProjects.all(world).compactMap { $0["folder"] as? String } + all(world).compactMap { $0["cwd"] as? String }
            + repositories(world)
        return known.contains(path)
    }

    /// The checkouts the `branches` event names: folders in a git repository.
    static func repositories(_ world: DemoWorld) -> [String] {
        ((world.event("branches")?["conversations"] as? [String: Any] ?? [:]).values.compactMap { ($0 as? [String: Any])?["root"] as? String })
    }

    /// A command's words as `wordsOf` splits them, refused as `ruleRefusal` refuses one that is not plain words or does not
    /// start with a program (its lists of programs that always ask are the Mac's to apply: the demo runs no command).
    static func words(_ command: String) throws -> [String] {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { throw DemoRefusal("Write the command's first words, such as npm test.") }
        for word in words {
            if word.count > 100 { throw DemoRefusal("“\(word.prefix(40))…” is too long for a word in an allowed command.") }
            if word.range(of: "^[A-Za-z0-9_\\-./,:@%+=^]+$", options: .regularExpression) == nil {
                throw DemoRefusal("“\(word)” is not a plain word. Write the command as you would type it, without quotes, variables, wildcards, or symbols such as $ ; | & > < ( ) * ~.")
            }
        }
        let first = words[0]
        if first.range(of: "^[A-Za-z0-9_./][A-Za-z0-9_\\-./@+]*$", options: .regularExpression) == nil || first.hasSuffix("/") || first == "." || first == ".." {
            throw DemoRefusal("“\(first)” is not the name of a program. An allowed command starts with the program to run, such as npm or ./run-tests.")
        }
        return words
    }

    /// `saveAgent`: a new agent when `given` has no id (in `project`, or a template), else the agent with what `given`
    /// changes; checked as the engine checks it. Answers the agent's id.
    static func save(_ given: [String: Any], world: DemoWorld, project newIn: String? = nil, copying rules: [Any]? = nil,
                     marks: [String: Any] = [:]) throws -> String {
        var name = (given["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw DemoRefusal("Give the agent a name") }
        let agents = all(world)
        let givenID = given["id"] as? String
        let previous = givenID.flatMap { id in agents.first { $0["id"] as? String == id } }
        if givenID != nil, previous == nil { throw DemoRefusal("Unknown agent: \(givenID ?? "")") }
        let project = givenID == nil ? newIn : previous?["projectId"] as? String
        var input = given
        if let project {
            let folder = DemoProjects.project(project, world: world)?["folder"] ?? NSNull()
            if let cwd = input["cwd"], !(cwd is NSNull && folder is NSNull), cwd as? String != folder as? String {
                throw DemoRefusal("An agent of a project works in the project's folder")
            }
            input["cwd"] = folder
        }
        if let access = input["access"], !accessLevels.contains(access as? String ?? "") { throw DemoRefusal("Unknown access level: \(access)") }
        if project == nil, let cwd = input["cwd"] as? String, !isFolder(cwd, world: world) { throw DemoRefusal("Not a folder: \(cwd)") }
        if let worktree = input["worktree"], !DemoSettings.isBool(worktree) { throw DemoRefusal("worktree must be true or false") }
        if let setup = input["setup"], !(setup is String) { throw DemoRefusal("The set-up command must be text") }
        if let setup = input["setup"] as? String, setup.count > 4_000 {
            throw DemoRefusal("The set-up command is too long: keep it under 4,000 characters, or put it in a script")
        }
        if let turns = input["maxTurns"], !(turns is NSNull) {
            guard let number = turns as? NSNumber, !DemoSettings.isBool(turns), number.doubleValue == Double(number.intValue), number.intValue >= 1 else {
                throw DemoRefusal("The turn limit must be a whole number, 1 or more")
            }
        }
        if let model = input["model"] as? [String: Any], !DemoSettings.knownModel(model, in: world) {
            throw DemoRefusal("Unknown model: \(model["provider"] ?? "")/\(model["modelId"] ?? "")")
        }
        if let tokens = input["compactionTokens"], !(tokens is NSNull) {
            guard let value = (tokens as? NSNumber)?.intValue, !DemoSettings.isBool(tokens), value >= 0, (tokens as? NSNumber)?.doubleValue == Double(value) else {
                throw DemoRefusal("The size for summarizing must be a whole number of tokens, 0 or more, or unset.")
            }
        }
        let taken = { (name: String) in
            agents.contains { $0["id"] as? String != givenID && $0["projectId"] as? String == project && ($0["name"] as? String)?.lowercased() == name.lowercased() }
        }
        if taken(name) {
            guard rules != nil else { throw DemoRefusal("There is already an agent called \(name)") }
            let base = name
            var n = 2
            while taken(name) {
                name = "\(base) \(n)"
                n += 1
            }
        }
        var id = givenID ?? ""
        if givenID == nil {
            let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let stem = slug.isEmpty ? "agent" : slug
            id = rules == nil && project == nil ? stem : "\(stem)-\(UUID().uuidString.lowercased())"
            var n = 2
            while agents.contains(where: { $0["id"] as? String == id }) {
                id = "\(stem)-\(n)"
                n += 1
            }
        }
        var agent: [String: Any] = previous ?? [:]
        let keys = ["description", "color", "model", "thinkingLevel", "instructions", "access", "cwd", "worktree", "setup", "delegates",
                    "maxTurns", "codeMode", "mcpServers", "files", "computer", "browser", "schedule", "toolsOff", "toolsOn", "compactionTokens"]
        for (key, unset) in templateSettings + [("cwd", NSNull()), ("delegates", [Any]())] where agent[key] == nil { agent[key] = unset }
        for key in keys { if let value = input[key] { agent[key] = value } }
        for key in ["description", "setup"] { agent[key] = (agent[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        agent["delegates"] = (agent["delegates"] as? [String] ?? []).filter { $0 != id }
        if agent["worktree"] as? Bool == true, !repositories(world).contains(agent["cwd"] as? String ?? "") {
            throw DemoRefusal("To give each conversation its own worktree, choose a folder in a git repository for the agent")
        }
        agent["id"] = id
        agent["name"] = name
        agent["createdAt"] = previous?["createdAt"] ?? world.now
        agent["commandRules"] = rules ?? previous?["commandRules"] ?? [Any]()
        if previous == nil, let project { agent["projectId"] = project }
        for (key, value) in marks { agent[key] = value }
        agent["updatedAt"] = world.now
        change(world) { agents in
            if let at = agents.firstIndex(where: { $0["id"] as? String == id }) { agents[at] = agent } else { agents.append(agent) }
        }
        return id
    }

    /// What Update from template would change in `copy`, setting by setting (`templateChanges`), the memory switch last.
    static func templateChanges(_ copy: [String: Any], _ template: [String: Any], world: DemoWorld) -> [[String: Any]] {
        var changes: [[String: Any]] = []
        for (setting, unset) in templateSettings {
            let now = copy[setting] ?? unset
            let then = template[setting] ?? unset
            if !NSDictionary(dictionary: ["v": now]).isEqual(to: ["v": then]) { changes.append(["setting": setting, "now": now, "template": then]) }
        }
        let memory = { (id: Any?) in ((world.event("memory")?["agents"] as? [String: Any])?[id as? String ?? ""] as? [String: Any])?["enabled"] as? Bool == true }
        if memory(copy["id"]) != memory(template["id"]) {
            changes.append(["setting": "memory", "now": memory(copy["id"]), "template": memory(template["id"])])
        }
        return changes
    }

    /// The memory switch a copy takes from what it was copied from (`agentDuplicated` in `knowledge.ts`); not the notes.
    static func copyMemorySwitch(from source: String, to copy: String, world: DemoWorld) {
        world.change("memory") { event in
            var agents = event["agents"] as? [String: Any] ?? [:]
            let enabled = (agents[source] as? [String: Any])?["enabled"] as? Bool ?? false
            agents[copy] = ["enabled": enabled, "notes": [Any]()]
            event["agents"] = agents
        }
    }
}
