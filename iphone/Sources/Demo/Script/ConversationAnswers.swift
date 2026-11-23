

import Foundation

/// A conversation in the demo (#684): opening and closing one, and writing to it. A message gets the scripted demo
/// model's answer, written out a few words at a time as the engine streams one, with the conversation working meanwhile
/// (its row, its project's spinner and the activity), and a message sent while it works waits its turn in the queue, as
/// on a Mac, until it is taken back. Stop ends a run where it is, the demo's own answers and the runs the recording holds
/// alike; Continue resumes a stopped one. The answer is the demo model's own (`engine/src/providers.ts`), with its last
/// sentence saying where a real answer would come from on a phone.
extension DemoScript {
    static let conversations: [String: DemoAnswer] = [
        "conversation.open": { request, world in
            try world.open(try request.requireInt("id"))
            return [:]
        },
        "conversation.close": { request, world in
            world.close(try request.requireInt("id"))
            return [:]
        },
        // Which conversations are on screen only keeps a model loaded on the Mac: nothing to do here.
        "conversations.shown": { _, _ in [:] },
        // The recording holds each conversation whole, so nothing is older (`conversationevents.ts`).
        "conversation.older": { request, world in
            guard world.opened.contains(try request.requireInt("id")) else { throw DemoRefusal("That conversation is not open") }
            return ["more": false]
        },
        "submit": { request, world in
            let id = try DemoRuns.carryingOn(request, world: world)
            let attachments = try DemoAttachments.checked(request.params["attachments"])
            // Attachments can be the whole message.
            let text = attachments.isEmpty || request.params["text"] != nil ? try request.requireString("text") : ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { throw DemoRefusal("The message is empty") }
            let submission = world.newSubmissionID()
            let mode = request.string("mode") == "steer" ? "steer" : "queue"
            DemoReplies.take(DemoReplies.Message(submission: submission, text: text, mode: mode, attachments: attachments), in: id, world: world)
            DemoLibrary.touch(id, title: text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? attachments.first?["name"] as? String, world: world)
            return ["submissionId": submission]
        },
        "abort": { request, world in
            let id = try request.requireInt("id")
            guard world.conversations[id] != nil else { throw DemoRefusal("Unknown conversation: \(id)") }
            DemoRuns.stop(id, world: world)
            return [:]
        },
        // A message waiting its turn is taken back before the model reads it; the one being answered is stopped.
        "withdraw": { request, world in
            DemoReplies.withdraw(try request.requireInt("submissionId"), world: world)
            return [:]
        },
        "continue": { request, world in
            let id = try DemoRuns.carryingOn(request, world: world)
            DemoReplies.carryOn(id, world: world)
            return [:]
        },
        // One of an entry's pictures: those sent with a message in the demo (the recording holds none).
        "conversation.image": { request, world in
            let id = try request.requireInt("id")
            guard world.conversations[id] != nil else { throw DemoRefusal("Unknown conversation: \(id)") }
            guard let entry = request.int("entryId") else { throw DemoRefusal("entryId must be a number") }
            let pictures = DemoAttachments.pictures(of: entry, world: world)
            let index = request.int("index") ?? 0
            guard pictures.indices.contains(index) else { throw DemoRefusal("That entry has no such picture") }
            return pictures[index]
        },
    ]
}

/// The pictures and files a message carries, checked as the engine checks them (`validateAttachments`), and the pictures
/// kept by entry for `conversation.image`.
@MainActor
enum DemoAttachments {
    private static let picturesKey = "DemoAttachments.pictures"
    static let most = 10
    static let types = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func checked(_ input: Any?) throws -> [[String: Any]] {
        guard let input, !(input is NSNull) else { return [] }
        guard let list = input as? [[String: Any]] else { throw DemoRefusal("attachments must be a list") }
        if list.count > most {
            throw DemoRefusal("A message can carry at most \(most) attachments; this one has \(list.count). Remove some and send again.")
        }
        return try list.map { raw in
            switch raw["kind"] as? String {
            case "image":
                let name = raw["name"] as? String ?? "Picture"
                let type = raw["mimeType"] as? String ?? ""
                guard types.contains(type) else {
                    throw DemoRefusal("“\(name)” is \(type.isEmpty ? "of an unknown type" : type), which cannot be sent as a picture. Use PNG, JPEG, GIF or WebP.")
                }
                guard let data = raw["data"] as? String, !data.isEmpty, Data(base64Encoded: data) != nil else {
                    throw DemoRefusal("“\(name)” did not arrive whole. Attach it again.")
                }
                return ["kind": "image", "name": name, "mimeType": type, "data": data]
            case "text":
                let name = raw["name"] as? String ?? "Text"
                guard let text = raw["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DemoRefusal("“\(name)” has no text in it. Remove it and send again.")
                }
                return ["kind": "text", "name": name, "text": text]
            default:
                throw DemoRefusal("An attachment must be a picture or a text file")
            }
        }
    }

    /// What the user entry records of them (`userEntryData`): each one's name, kind and size.
    static func notes(_ attachments: [[String: Any]]) -> [[String: Any]] {
        attachments.map { attachment in
            let size = attachment["kind"] as? String == "image"
                ? Data(base64Encoded: attachment["data"] as? String ?? "")?.count ?? 0
                : (attachment["text"] as? String ?? "").utf8.count
            return ["name": attachment["name"] ?? "", "kind": attachment["kind"] ?? "", "size": size]
        }
    }

    static func keep(_ attachments: [[String: Any]], for entry: Int, world: DemoWorld) {
        let pictures = attachments.filter { $0["kind"] as? String == "image" }
            .map { ["type": "image", "data": $0["data"] ?? "", "mimeType": $0["mimeType"] ?? ""] as [String: Any] }
        guard !pictures.isEmpty else { return }
        var kept = world.kept[picturesKey] as? [Int: [[String: Any]]] ?? [:]
        kept[entry] = pictures
        world.kept[picturesKey] = kept
    }

    static func pictures(of entry: Int, world: DemoWorld) -> [[String: Any]] {
        (world.kept[picturesKey] as? [Int: [[String: Any]]])?[entry] ?? []
    }
}

/// The runs of the demo's conversations: ending one, as Stop does, whether the demo is writing its answer or the
/// recording holds it working (an agent running a command, or waiting on an approval).
@MainActor
enum DemoRuns {
    /// The conversation a request to write to it names, refused as the engine refuses one that is put away.
    static func carryingOn(_ request: DemoRequest, world: DemoWorld) throws -> Int {
        let id = try request.requireInt("id")
        guard world.conversations[id] != nil else { throw DemoRefusal("Unknown conversation: \(id)") }
        let root = DemoLibrary.row(id, world: world)?["parent"] as? NSNumber
        if DemoLibrary.isArchived(id, world: world) || root.map({ DemoLibrary.isArchived($0.intValue, world: world) }) == true {
            throw DemoRefusal("This conversation is archived. Restore it to carry on.")
        }
        if let project = DemoLibrary.row(id, world: world)?["projectId"] as? String, DemoProjects.project(project, world: world)?["archivedAt"] is NSNumber {
            throw DemoRefusal("This project is archived. Restore it first.")
        }
        return id
    }

    /// Stops the conversation's run where it is, keeping what it wrote: its answer so far, or the command it ran. What it
    /// waited for under Needs you is withdrawn, its report says it was stopped, and what was queued is sent after it.
    static func stop(_ id: Int, world: DemoWorld) {
        if DemoReplies.stopWriting(id, world: world) { return }
        guard world.conversations[id]?.state["busy"] as? Bool == true else { return }
        world.changeState(of: id) { state in
            state["busy"] = false
            state["partial"] = NSNull()
            state["tools"] = [Any]()
            state["messageWaits"] = NSNull()
            state["failure"] = ["reason": "aborted", "detail": NSNull()]
        }
        DemoNeeds.withdraw(of: id, world: world)
        ended(id, outcome: "stopped", world: world)
        DemoReplies.next(after: id, world: world)
    }

    /// A run of `id` ended: it no longer shows as working, and the report of a sub-chat the orchestrator handed it says
    /// how it ended ("answered", "failed" or "stopped"), under what finished today.
    static func ended(_ id: Int, outcome: String, world: DemoWorld) {
        DemoReplies.working(id, false, world: world)
        guard let reports = world.event("reports")?["projects"] as? [String: Any],
              reports.values.contains(where: { ($0 as? [[String: Any]] ?? []).contains { open($0, of: id) } }) else { return }
        world.change("reports") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            for (project, list) in projects {
                projects[project] = (list as? [[String: Any]] ?? []).map { report in
                    guard open(report, of: id) else { return report }
                    var report = report
                    report["ended"] = ["at": world.now, "outcome": outcome]
                    return report
                }
            }
            event["projects"] = projects
        }
    }

    /// A report still waiting for its run to end.
    private static func open(_ report: [String: Any], of id: Int) -> Bool {
        (report["conversationId"] as? NSNumber)?.intValue == id && (report["ended"] == nil || report["ended"] is NSNull)
    }
}

/// The scripted demo model's answers, written out over time, and the messages waiting their turn, by conversation.
@MainActor
enum DemoReplies {
    struct Message {
        let submission: Int
        let text: String
        let mode: String
        var attachments: [[String: Any]] = []
        /// A run resumed with Continue: no new message, an answer to the last one.
        var resumed = false
    }

    /// What one conversation's answer has written so far, and the step that writes more.
    private struct Writing {
        var submission: Int
        var text: String
        var step: Int
    }

    private static let queueKey = "DemoReplies.queue"
    private static let writingKey = "DemoReplies.writing"

    /// How long the demo model waits before it starts, and between two pieces of its answer, in seconds.
    static let start = 0.5
    static let beat = 0.06

    /// The scripted demo model's answer to `text`, as `engine/src/providers.ts` writes it, ending for a phone.
    static func answer(to text: String, pictures: Int = 0, files: Int = 0) -> String {
        let came = [
            pictures == 0 ? nil : "\(pictures) picture\(pictures == 1 ? "" : "s")",
            files == 0 ? nil : "\(files) attached file\(files == 1 ? "" : "s")",
        ].compactMap { $0 }
        return "You said: \"\(text)\". " + (came.isEmpty ? "" : "With it came \(came.joined(separator: " and ")). ")
            + "I am the demo model, a scripted stand-in with no intelligence behind it. "
            + "In the demo nothing reaches a Mac: once this iPhone is paired, the orchestrator answers here with its own model."
    }

    /// Takes a message: answered now if the conversation is idle, else queued until its answer is written. A message to
    /// steer is queued the same way: the demo model reads it once the answer it is writing ends, as a model given a
    /// message mid-answer does between two of its steps.
    static func take(_ message: Message, in id: Int, world: DemoWorld) {
        if world.conversations[id]?.state["busy"] as? Bool == true {
            var queue = world.kept[queueKey] as? [Int: [Message]] ?? [:]
            queue[id, default: []].append(message)
            world.kept[queueKey] = queue
            world.changeState(of: id) { $0["queued"] = queued(queue[id] ?? []) }
            return
        }
        answer(message, in: id, world: world)
    }

    /// Takes back submission `submission`: out of its queue if it waits there, or stopped if it is being answered.
    static func withdraw(_ submission: Int, world: DemoWorld) {
        var queue = world.kept[queueKey] as? [Int: [Message]] ?? [:]
        if let id = queue.first(where: { $0.value.contains { $0.submission == submission } })?.key {
            queue[id]?.removeAll { $0.submission == submission }
            if queue[id]?.isEmpty == true { queue[id] = nil }
            world.kept[queueKey] = queue
            world.changeState(of: id) { $0["queued"] = queued(queue[id] ?? []) }
            return
        }
        let writing = world.kept[writingKey] as? [Int: Writing] ?? [:]
        if let id = writing.first(where: { $0.value.submission == submission })?.key { DemoRuns.stop(id, world: world) }
    }

    /// Continue: a run that stopped resumes, answering the last message again; one still working is left as it is.
    static func carryOn(_ id: Int, world: DemoWorld) {
        guard world.conversations[id]?.state["busy"] as? Bool != true else { return }
        let last = world.conversations[id]?.items.last { $0["kind"] as? String == "user" }?["text"] as? String ?? ""
        answer(Message(submission: world.newSubmissionID(), text: last, mode: "queue", resumed: true), in: id, world: world)
    }

    /// Stops the answer being written, keeping what it wrote, as Stop does; what was queued is sent after it. False when
    /// the demo is not writing one in `id`.
    static func stopWriting(_ id: Int, world: DemoWorld) -> Bool {
        var writing = world.kept[writingKey] as? [Int: Writing] ?? [:]
        guard let current = writing.removeValue(forKey: id) else { return false }
        world.kept[writingKey] = writing
        world.cancel(current.step)
        finish(id, text: current.text, stop: "aborted", world: world)
        return true
    }

    private static func queued(_ messages: [Message]) -> [[String: Any]] {
        messages.map { ["id": $0.submission, "mode": $0.mode == "steer" ? "steer" : "followUp", "text": $0.text] }
    }

    private static func answer(_ message: Message, in id: Int, world: DemoWorld) {
        var entries: [[String: Any]] = []
        if !message.resumed {
            let entry = world.newItemID()
            let images = message.attachments.filter { $0["kind"] as? String == "image" }.count
            entries.append(["id": entry, "kind": "user", "text": message.text, "attachments": DemoAttachments.notes(message.attachments), "images": images])
            DemoAttachments.keep(message.attachments, for: entry, world: world)
        }
        world.append(entries, to: id) { state in
            state["busy"] = true
            state["partial"] = NSNull()
            state["failure"] = NSNull()
        }
        working(id, true, world: world)
        let pictures = message.attachments.filter { $0["kind"] as? String == "image" }.count
        let whole = answer(to: message.text, pictures: pictures, files: message.attachments.count - pictures)
        var writing = world.kept[writingKey] as? [Int: Writing] ?? [:]
        writing[id] = Writing(submission: message.submission, text: "", step: world.after(start) { world in write(whole, in: id, world: world) })
        world.kept[writingKey] = writing
    }

    /// Writes the next few words of `whole`, then the next after a beat, then the whole answer as an entry.
    private static func write(_ whole: String, in id: Int, world: DemoWorld) {
        var writing = world.kept[writingKey] as? [Int: Writing] ?? [:]
        guard var current = writing[id] else { return }
        let rest = whole.dropFirst(current.text.count)
        guard !rest.isEmpty else {
            writing[id] = nil
            world.kept[writingKey] = writing
            finish(id, text: whole, stop: "stop", world: world)
            return
        }
        // A few words a beat, as tokens come.
        var piece = ""
        for character in rest {
            piece.append(character)
            if character == " ", piece.count >= 12 { break }
        }
        current.text += piece
        let partial = current.text
        world.changeState(of: id) { $0["partial"] = ["text": partial, "thinking": "", "toolCalls": [Any]()] }
        current.step = world.after(beat) { world in write(whole, in: id, world: world) }
        writing[id] = current
        world.kept[writingKey] = writing
    }

    /// Ends the answer with an entry, the conversation idle (stopped, if it was), and its project's last words; then the
    /// next queued message.
    private static func finish(_ id: Int, text: String, stop: String, world: DemoWorld) {
        let entry: [String: Any] = [
            "id": world.newItemID(), "kind": "assistant", "text": text, "thinking": "", "toolCalls": [Any](), "stop": stop,
            "error": NSNull(), "model": "demo-1",
        ]
        world.append([entry], to: id) { state in
            state["busy"] = false
            state["partial"] = NSNull()
            state["failure"] = stop == "aborted" ? ["reason": "aborted", "detail": NSNull()] : NSNull()
        }
        DemoRuns.ended(id, outcome: stop == "aborted" ? "stopped" : "answered", world: world)
        lastWords(text, of: id, world: world)
        next(after: id, world: world)
    }

    /// Sends the first message queued in `id`, now that its run ended.
    static func next(after id: Int, world: DemoWorld) {
        var queue = world.kept[queueKey] as? [Int: [Message]] ?? [:]
        guard let next = queue[id]?.first else { return }
        queue[id]?.removeFirst()
        if queue[id]?.isEmpty == true { queue[id] = nil }
        world.kept[queueKey] = queue
        world.changeState(of: id) { $0["queued"] = queued(queue[id] ?? []) }
        answer(next, in: id, world: world)
    }

    /// Marks a conversation working or not where the client reads it: its row in the library (and its parent's, which
    /// shows as working while any of its sub-chats is), and the activity.
    static func working(_ id: Int, _ busy: Bool, world: DemoWorld) {
        var row: [String: Any]?
        world.change("library") { library in
            guard var rows = library["conversations"] as? [[String: Any]],
                  let index = rows.firstIndex(where: { ($0["id"] as? NSNumber)?.intValue == id }) else { return }
            rows[index]["busy"] = busy
            if busy { rows[index]["updatedAt"] = world.now }
            row = rows[index]
            if let parent = (rows[index]["parent"] as? NSNumber)?.intValue,
               let up = rows.firstIndex(where: { ($0["id"] as? NSNumber)?.intValue == parent }) {
                let children = rows.contains { ($0["parent"] as? NSNumber)?.intValue == parent && $0["busy"] as? Bool == true }
                rows[up]["busy"] = world.conversations[parent]?.state["busy"] as? Bool == true || children
            }
            library["conversations"] = rows
        }
        world.change("activity") { activity in
            var runs = (activity["runs"] as? [[String: Any]] ?? []).filter { ($0["conversationId"] as? NSNumber)?.intValue != id }
            if busy, let row {
                runs.append([
                    "conversationId": id, "parent": row["parent"] ?? NSNull(), "rootConversationId": row["parent"] ?? id,
                    "title": row["title"] ?? "", "agentId": row["agentId"] ?? NSNull(), "projectId": row["projectId"] ?? NSNull(),
                    "runsAs": row["runsAs"] ?? NSNull(), "chat": row["chat"] ?? false, "status": "working", "since": world.now,
                    "limit": NSNull(), "lastLine": NSNull(), "commands": [Any](),
                ])
            }
            activity["runs"] = runs
        }
    }

    /// An orchestrator's answer is its project's last words, which the projects list shows.
    private static func lastWords(_ text: String, of id: Int, world: DemoWorld) {
        guard let projects = world.event("projects")?["projects"] as? [[String: Any]],
              projects.contains(where: { ($0["conversation"] as? NSNumber)?.intValue == id }) else { return }
        world.change("projects") { event in
            event["projects"] = (event["projects"] as? [[String: Any]] ?? []).map { project in
                guard (project["conversation"] as? NSNumber)?.intValue == id else { return project }
                var project = project
                project["lastWords"] = ["text": text, "at": world.now]
                return project
            }
        }
    }
}
