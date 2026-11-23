
import Foundation

/// The conversations' screens' requests in the demo (#698: other conversations, chats, the Archive, background commands),
/// answered as the engine answers them (`engine/src/main.ts`, `settingsrequests.ts`, `background.ts`, `projects.ts`,
/// `carryover.ts`): a conversation renamed or deleted, archiving on its own set, an archived project restored, and the
/// refusals the engine gives for what the demo's world has none of (no background command, no deleted project). Each
/// change sends the event it changes again whole.
///
/// Not answered yet: `projects.folders`, which the engine does not have until #698's second part, and `projects.create`,
/// which makes a project, its orchestrator and its conversation in one step; both are refused as the demo refuses what it
/// does not do, and the New project screen says so.
extension DemoScript {
    static let conversationsScreens: [String: DemoAnswer] = [
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

@MainActor
enum DemoConversations {
    /// The conversation a request names, in the list or the Archive, or the engine's refusal.
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
