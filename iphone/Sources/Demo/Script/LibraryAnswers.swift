

import Foundation

/// The demo's list of conversations (#684, for the projects list #685 and the conversation #687), answered as the
/// engine answers it (`engine/src/main.ts`, `appevents.ts`, `conversationevents.ts`): a chat is made, pinned and archived,
/// an archived conversation restored, and the conversations searched. Each change sends the `library` event again whole.
extension DemoScript {
    static let library: [String: DemoAnswer] = [
        "conversation.create": { request, world in
            if let chat = request.params["chat"], !(chat is NSNull), !(chat is Bool) { throw DemoRefusal("chat must be true or false") }
            // An agent's conversation is made by a project's screens through their own requests; the phone's New Chat
            // makes a chat with pi²'s assistant.
            guard request.params["chat"] as? Bool == true else {
                throw DemoRefusal("The demo does not do conversation.create for an agent: nothing was changed. On a Mac paired with this iPhone, pi² does it.")
            }
            if request.params["agentId"] != nil { throw DemoRefusal("A chat has no agent: leave agentId out") }
            return ["id": DemoLibrary.makeChat(world)]
        },
        "conversation.pin": { request, world in
            let id = try request.requireInt("id")
            guard let row = DemoLibrary.row(id, world: world) else { throw DemoRefusal("Unknown conversation: \(id)") }
            guard let pinned = request.params["pinned"] as? Bool else { throw DemoRefusal("pinned must be true or false") }
            if row["parent"] is NSNumber {
                throw DemoRefusal("A sub-chat cannot be pinned on its own; pin the conversation it belongs to")
            }
            DemoLibrary.changeRow(id, world: world) { $0["pinned"] = pinned }
            return [:]
        },
        "conversation.archive": { request, world in
            guard let id = request.int("id") else { throw DemoRefusal("Unknown conversation: \(request.params["id"] ?? "")") }
            guard DemoLibrary.row(id, world: world) != nil || DemoLibrary.isArchived(id, world: world) else {
                throw DemoRefusal("Unknown conversation: \(id)")
            }
            DemoLibrary.archive(id, world: world)
            return [:]
        },
        "conversation.unarchive": { request, world in
            let id = try request.requireInt("id")
            guard world.conversations[id] != nil else { throw DemoRefusal("Unknown conversation: \(id)") }
            DemoLibrary.unarchive(id, world: world)
            return [:]
        },
        "search": { request, world in
            ["results": DemoLibrary.search(try request.requireString("query"), world: world)]
        },
    ]
}

@MainActor
enum DemoLibrary {
    /// The rows archiving took out of the sidebar, by conversation, to put back as they were on restoring.
    private static let putAwayKey = "DemoLibrary.putAway"

    static func rows(_ world: DemoWorld) -> [[String: Any]] {
        world.event("library")?["conversations"] as? [[String: Any]] ?? []
    }

    static func archivedRows(_ world: DemoWorld) -> [[String: Any]] {
        world.event("library")?["archived"] as? [[String: Any]] ?? []
    }

    static func row(_ id: Int, world: DemoWorld) -> [String: Any]? {
        rows(world).first { ($0["id"] as? NSNumber)?.intValue == id }
    }

    static func isArchived(_ id: Int, world: DemoWorld) -> Bool {
        archivedRows(world).contains { ($0["id"] as? NSNumber)?.intValue == id }
    }

    static func changeRow(_ id: Int, world: DemoWorld, _ body: @escaping (inout [String: Any]) -> Void) {
        world.change("library") { library in
            library["conversations"] = (library["conversations"] as? [[String: Any]] ?? []).map { row in
                guard (row["id"] as? NSNumber)?.intValue == id else { return row }
                var row = row
                body(&row)
                return row
            }
        }
    }

    /// A message was sent: the row goes to the top, and takes its title from the message if it had none.
    static func touch(_ id: Int, title: String?, world: DemoWorld) {
        guard row(id, world: world) != nil else { return }
        changeRow(id, world: world) { row in
            row["updatedAt"] = world.now
            if (row["title"] as? String ?? "").isEmpty, let title { row["title"] = String(title.prefix(60)) }
        }
        sortRows(world)
        if (world.conversations[id]?.state["title"] as? String ?? "").isEmpty, let title {
            world.changeState(of: id) { $0["title"] = String(title.prefix(60)) }
        }
    }

    private static func sortRows(_ world: DemoWorld) {
        world.change("library") { library in
            library["conversations"] = (library["conversations"] as? [[String: Any]] ?? []).sorted {
                ($0["updatedAt"] as? NSNumber)?.doubleValue ?? 0 > ($1["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            }
        }
    }

    /// A new conversation's row, as the library event lists one.
    static func newRow(_ id: Int, title: String, agentId: String?, parent: Int?, projectId: String?, chat: Bool, orchestrator: String? = nil,
                       freshFrom: Int? = nil, now: Double) -> [String: Any] {
        [
            "id": id, "title": title, "createdAt": now, "updatedAt": now, "busy": false, "agentId": agentId ?? NSNull(),
            "parent": parent ?? NSNull(), "chat": chat, "pinned": false, "continuedFrom": NSNull(), "continuedIn": [Any](),
            "allowEverything": false, "projectId": projectId ?? NSNull(), "runsAs": agentId ?? NSNull(),
            "orchestrator": orchestrator ?? NSNull(), "freshFrom": freshFrom ?? NSNull(),
        ]
    }

    /// A new conversation's state, as the engine sends an idle one with nothing in it yet.
    static func newState(title: String, chat: Bool, agent: [String: Any], project: [String: Any]?) -> [String: Any] {
        [
            "busy": false, "turns": 0, "partial": NSNull(), "retry": NSNull(), "tools": [Any](), "failure": NSNull(),
            "usage": ["cost": 0, "tokens": 0], "context": ["used": 0, "window": 128_000], "lastRequestInputTokens": 0,
            "compacting": false, "compactionError": NSNull(), "compactionErrorId": NSNull(), "title": title, "chat": chat,
            "web": NSNull(), "archived": false, "queued": [Any](), "agent": agent, "versions": NSNull(), "limitWait": NSNull(),
            "plan": NSNull(), "projectInstructions": NSNull(), "projectInstructionFiles": [Any](), "setup": NSNull(),
            "messageWaits": NSNull(), "local": NSNull(), "projectChanges": [Any](), "project": project ?? NSNull(),
        ]
    }

    /// Adds a conversation, first in the sidebar.
    static func add(_ row: [String: Any], state: [String: Any], world: DemoWorld) {
        guard let id = (row["id"] as? NSNumber)?.intValue else { return }
        world.make(id, state: state)
        world.change("library") { library in
            library["conversations"] = [row] + (library["conversations"] as? [[String: Any]] ?? [])
        }
    }

    /// A chat with pi²'s assistant, on the demo model, empty: what New Chat makes (`createChat`).
    static func makeChat(_ world: DemoWorld) -> Int {
        let id = world.newItemID()
        let agent: [String: Any] = [
            "model": ["provider": "demo", "modelId": "demo-1"], "thinkingLevel": NSNull(), "cwd": NSNull(), "access": "none",
            "agentId": NSNull(), "parent": NSNull(),
        ]
        add(newRow(id, title: "", agentId: nil, parent: nil, projectId: nil, chat: true, now: world.now),
            state: newState(title: "", chat: true, agent: agent, project: nil), world: world)
        return id
    }

    /// Archives a top-level conversation (`archiveConversation`): stops what it and its sub-chats are doing, and moves it
    /// out of the sidebar into the Archive, its sub-chats with it.
    static func archive(_ id: Int, world: DemoWorld) {
        guard let row = row(id, world: world) else { return }
        let parent = (row["parent"] as? NSNumber)?.intValue
        let gone = rows(world).filter {
            let rowID = ($0["id"] as? NSNumber)?.intValue
            return rowID == id || (parent == nil && ($0["parent"] as? NSNumber)?.intValue == id)
        }
        for each in gone {
            if let each = (each["id"] as? NSNumber)?.intValue { DemoRuns.stop(each, world: world) }
        }
        var putAway = world.kept[putAwayKey] as? [Int: [[String: Any]]] ?? [:]
        // The rows as they are now, after stopping.
        let ids = Set(gone.compactMap { ($0["id"] as? NSNumber)?.intValue })
        putAway[id] = rows(world).filter { ids.contains(($0["id"] as? NSNumber)?.intValue ?? -1) }
        world.kept[putAwayKey] = putAway
        let archived: [String: Any] = [
            "id": id, "title": row["title"] ?? "", "createdAt": row["createdAt"] ?? world.now, "updatedAt": row["updatedAt"] ?? world.now,
            "archivedAt": world.now, "agentId": row["agentId"] ?? NSNull(), "subChats": ids.count - 1,
            "parent": row["parent"] ?? NSNull(),
            "parentTitle": parent.flatMap { self.row($0, world: world)?["title"] } ?? NSNull(),
            "chat": row["chat"] ?? false, "pinned": row["pinned"] ?? false, "projectId": row["projectId"] ?? NSNull(),
        ]
        world.change("library") { library in
            library["conversations"] = (library["conversations"] as? [[String: Any]] ?? []).filter { !ids.contains(($0["id"] as? NSNumber)?.intValue ?? -1) }
            library["archived"] = [archived] + (library["archived"] as? [[String: Any]] ?? [])
        }
        for each in ids { world.changeState(of: each) { $0["archived"] = true } }
    }

    /// Restores an archived conversation and its sub-chats to the sidebar; one that is not archived is left as it is.
    static func unarchive(_ id: Int, world: DemoWorld) {
        guard isArchived(id, world: world) else { return }
        var putAway = world.kept[putAwayKey] as? [Int: [[String: Any]]] ?? [:]
        let back = putAway.removeValue(forKey: id) ?? []
        world.kept[putAwayKey] = putAway
        world.change("library") { library in
            library["archived"] = (library["archived"] as? [[String: Any]] ?? []).filter { ($0["id"] as? NSNumber)?.intValue != id }
            library["conversations"] = back + (library["conversations"] as? [[String: Any]] ?? [])
        }
        sortRows(world)
        for row in back {
            if let each = (row["id"] as? NSNumber)?.intValue { world.changeState(of: each) { $0["archived"] = false } }
        }
    }

    /// The person's and the agents' words that hold `query`, newest conversation first, 40 at most (`search`).
    static func search(_ query: String, world: DemoWorld) -> [[String: Any]] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        let tops = (rows(world) + archivedRows(world)).filter { !($0["parent"] is NSNumber) }
            .sorted { ($0["updatedAt"] as? NSNumber)?.doubleValue ?? 0 > ($1["updatedAt"] as? NSNumber)?.doubleValue ?? 0 }
        var results: [[String: Any]] = []
        for top in tops {
            guard let id = (top["id"] as? NSNumber)?.intValue, let items = world.conversations[id]?.items else { continue }
            for item in items.reversed() {
                guard let role = item["kind"] as? String, role == "user" || role == "assistant", let body = item["text"] as? String,
                      let range = body.lowercased().range(of: needle) else { continue }
                let at = body.lowercased().distance(from: body.lowercased().startIndex, to: range.lowerBound)
                let start = max(0, at - 40)
                let end = min(body.count, at + needle.count + 80)
                let characters = Array(body)
                let snippet = (start > 0 ? "…" : "") + String(characters[start..<end]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    + (end < body.count ? "…" : "")
                results.append([
                    "conversationId": id, "title": top["title"] ?? "", "entryId": item["id"] ?? 0, "role": role, "snippet": snippet,
                    "archived": isArchived(id, world: world), "chat": top["chat"] as? Bool ?? false,
                ])
                if results.count >= 40 { return results }
            }
        }
        return results
    }
}

/// A start a project's limit held back, made when the person chooses Start anyway on its card: the sub-chat the card
/// holds (its agent, task and title, under the orchestrator's conversation), working on the task with the demo model's
/// answer, and a report for the orchestrator that shows under what finished once it is done.
@MainActor
enum DemoStarts {
    static func start(_ need: [String: Any], world: DemoWorld) {
        guard let start = need["start"] as? [String: Any], let agentID = start["agentId"] as? String,
              let task = start["task"] as? String, let project = need["projectId"] as? String else { return }
        let parent = (start["parent"] as? NSNumber)?.intValue ?? (need["conversationId"] as? NSNumber)?.intValue
        let title = start["title"] as? String ?? "\(start["agentName"] as? String ?? "Agent"): \(task.prefix(40))"
        let id = world.newItemID()
        let cwd = parent.flatMap { (world.conversations[$0]?.state["agent"] as? [String: Any])?["cwd"] } ?? NSNull()
        let agent: [String: Any] = [
            "model": ["provider": "demo", "modelId": "demo-1"], "thinkingLevel": NSNull(), "cwd": cwd, "access": "ask",
            "agentId": agentID, "parent": parent ?? NSNull(),
        ]
        DemoLibrary.add(
            DemoLibrary.newRow(id, title: title, agentId: agentID, parent: parent, projectId: project, chat: false, now: world.now),
            state: DemoLibrary.newState(title: title, chat: false, agent: agent, project: ["id": project, "orchestrator": NSNull()]),
            world: world
        )
        let submission = world.newSubmissionID()
        world.change("reports") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            var reports = projects[project] as? [[String: Any]] ?? []
            reports.append([
                "submissionId": submission, "conversationId": id, "agentId": agentID, "title": title, "batch": NSNull(),
                "work": start["work"] ?? NSNull(), "ended": NSNull(), "delivered": NSNull(),
            ])
            projects[project] = reports
            event["projects"] = projects
        }
        DemoReplies.take(DemoReplies.Message(submission: submission, text: task, mode: "queue"), in: id, world: world)
    }
}
