
import Foundation

/// A conversation in the demo (#684): opening and closing one, and writing to it. A message gets the scripted demo
/// model's answer, written out a few words at a time as the engine streams one, with the conversation working meanwhile
/// (its row, its project's spinner and the activity), and a message sent while it works waits its turn in the queue, as
/// on a Mac. The answer is the demo model's own (`engine/src/providers.ts`), with its last sentence saying where a real
/// answer would come from on a phone.
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
        // The recording holds each conversation whole, so nothing is older.
        "conversation.older": { _, _ in ["more": false] },
        "submit": { request, world in
            let id = try request.requireInt("id")
            guard world.conversations[id] != nil else { throw DemoRefusal("Unknown conversation: \(id)") }
            let text = request.string("text") ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DemoRefusal("The message is empty") }
            if world.conversations[id]?.state["archived"] as? Bool == true {
                throw DemoRefusal("This conversation is archived: unarchive it to carry on.")
            }
            let submission = world.newSubmissionID()
            DemoReplies.take(DemoReplies.Message(submission: submission, text: text, mode: request.string("mode") ?? "queue"), in: id, world: world)
            return ["submissionId": submission]
        },
        "abort": { request, world in
            let id = try request.requireInt("id")
            guard world.conversations[id] != nil else { throw DemoRefusal("Unknown conversation: \(id)") }
            DemoReplies.stop(id, world: world)
            return [:]
        },
    ]
}

/// The scripted demo model's answers, written out over time, and the messages waiting their turn, by conversation.
@MainActor
enum DemoReplies {
    struct Message {
        let submission: Int
        let text: String
        let mode: String
    }

    /// What one conversation's answer has written so far, and the step that writes more.
    private struct Writing {
        var text: String
        var step: Int
    }

    private static let queueKey = "DemoReplies.queue"
    private static let writingKey = "DemoReplies.writing"

    /// How long the demo model waits before it starts, and between two pieces of its answer, in seconds.
    static let start = 0.5
    static let beat = 0.06

    /// The scripted demo model's answer to `text`, as `engine/src/providers.ts` writes it, ending for a phone.
    static func answer(to text: String) -> String {
        "You said: \"\(text)\". I am the demo model, a scripted stand-in with no intelligence behind it. "
            + "In the demo nothing reaches a Mac: once this iPhone is paired, the orchestrator answers here with its own model."
    }

    /// Takes a message: answered now if the conversation is idle, else queued until its answer is written.
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

    /// Stops the answer being written, keeping what it wrote, as Stop does; what was queued is sent after it.
    static func stop(_ id: Int, world: DemoWorld) {
        var writing = world.kept[writingKey] as? [Int: Writing] ?? [:]
        guard let current = writing.removeValue(forKey: id) else { return }
        world.kept[writingKey] = writing
        world.cancel(current.step)
        finish(id, text: current.text, stop: "aborted", world: world)
    }

    private static func queued(_ messages: [Message]) -> [[String: Any]] {
        messages.map { ["id": $0.submission, "mode": $0.mode == "steer" ? "steer" : "followUp", "text": $0.text] }
    }

    private static func answer(_ message: Message, in id: Int, world: DemoWorld) {
        let user: [String: Any] = ["id": world.newItemID(), "kind": "user", "text": message.text, "attachments": [Any](), "images": 0]
        world.append([user], to: id) { state in
            state["busy"] = true
            state["partial"] = NSNull()
            state["failure"] = NSNull()
        }
        working(id, true, world: world)
        let whole = answer(to: message.text)
        var writing = world.kept[writingKey] as? [Int: Writing] ?? [:]
        writing[id] = Writing(text: "", step: world.after(start) { world in write(whole, in: id, world: world) })
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

    /// Ends the answer with an entry, the conversation idle, and its project's last words; then the next queued message.
    private static func finish(_ id: Int, text: String, stop: String, world: DemoWorld) {
        let entry: [String: Any] = [
            "id": world.newItemID(), "kind": "assistant", "text": text, "thinking": "", "toolCalls": [Any](), "stop": stop,
            "error": NSNull(), "model": "demo-1",
        ]
        var queue = world.kept[queueKey] as? [Int: [Message]] ?? [:]
        let next = queue[id]?.first
        if next != nil { queue[id]?.removeFirst() }
        if queue[id]?.isEmpty == true { queue[id] = nil }
        world.kept[queueKey] = queue
        world.append([entry], to: id) { state in
            state["busy"] = false
            state["partial"] = NSNull()
            state["queued"] = queued(queue[id] ?? [])
        }
        working(id, false, world: world)
        lastWords(text, of: id, world: world)
        if let next { answer(next, in: id, world: world) }
    }

    /// Marks a conversation working or not where the client reads it: its row in the library, and the activity.
    static func working(_ id: Int, _ busy: Bool, world: DemoWorld) {
        var row: [String: Any]?
        world.change("library") { library in
            guard var rows = library["conversations"] as? [[String: Any]],
                  let index = rows.firstIndex(where: { ($0["id"] as? NSNumber)?.intValue == id }) else { return }
            rows[index]["busy"] = busy
            if busy { rows[index]["updatedAt"] = world.now }
            row = rows[index]
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
