
import Foundation

/// What needs the person, answered in the demo (#684), as the engine answers it (`engine/src/needs.ts`, `main.ts`): an
/// answer of the item's kind takes it off Needs you (and an approval out of the inbox), and the agent that asked carries
/// on: an approved command runs, and the asking conversation is told. A second answer to the same item is refused with
/// the engine's words.
extension DemoScript {
    static let needs: [String: DemoAnswer] = [
        "needs.list": { request, world in
            let items = DemoNeeds.items(world)
            guard let project = request.string("projectId") else { return ["items": items] }
            return ["items": items.filter { $0["projectId"] as? String == project }]
        },
        "needs.answer": { request, world in
            let id = try request.requireString("id")
            guard let answer = request.params["answer"] as? [String: Any], let kind = answer["kind"] as? String else {
                throw DemoRefusal("answer must be an object with a kind")
            }
            try DemoNeeds.answer(id, kind: kind, answer: answer, world: world)
            return [:]
        },
        "inbox.decide": { request, world in
            let decision = try request.requireString("decision")
            guard ["once", "always", "rule", "deny"].contains(decision) else { throw DemoRefusal("Unknown decision: \(decision)") }
            try DemoNeeds.answer(try request.requireString("id"), kind: "approval", answer: ["kind": "approval", "decision": decision], world: world)
            return [:]
        },
        "inbox.answer": { request, world in
            let text = try request.requireString("text")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DemoRefusal("The answer is empty") }
            try DemoNeeds.answer(try request.requireString("id"), kind: "question", answer: ["kind": "question", "text": text], world: world)
            return [:]
        },
    ]
}

@MainActor
enum DemoNeeds {
    /// The engine's refusal of a second answer (`GONE` in `engine/src/needs.ts`).
    static let gone = "This is no longer waiting: it was answered or withdrawn."

    static func items(_ world: DemoWorld) -> [[String: Any]] {
        world.event("needs")?["items"] as? [[String: Any]] ?? []
    }

    /// Answers item `id` with an answer of `kind`, as `needs.answer` does through the engine's `claim`.
    static func answer(_ id: String, kind: String, answer: [String: Any], world: DemoWorld) throws {
        guard let need = items(world).first(where: { $0["id"] as? String == id }) else { throw DemoRefusal(gone) }
        let named = need["kind"] as? String ?? ""
        guard named == kind else { throw DemoRefusal("That is an answer to \(Self.named(kind)), and this is \(Self.named(named)).") }
        try check(answer, of: need)

        world.change("needs") { event in
            event["items"] = (event["items"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != id }
        }
        if (world.event("inbox")?["items"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id }) {
            world.change("inbox") { event in
                event["items"] = (event["items"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != id }
            }
        }
        carryOn(need, answer: answer, world: world)
    }

    /// The engine's checks of an answer's own fields (`checkAnswer`), for the kinds the demo holds.
    private static func check(_ answer: [String: Any], of need: [String: Any]) throws {
        switch answer["kind"] as? String {
        case "approval":
            let allowed = need["answers"] as? [String] ?? ["once", "always", "rule", "deny"]
            guard let decision = answer["decision"] as? String, allowed.contains(decision) else {
                throw DemoRefusal("decision must be one of \(allowed.joined(separator: ", "))")
            }
        case "question":
            guard let text = answer["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DemoRefusal("The answer is empty")
            }
        case "decision":
            let choices = (need["choices"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            if let choice = answer["choice"] as? String {
                guard choices.contains(choice) else { throw DemoRefusal("Unknown choice: \(choice)") }
            } else if (answer["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw DemoRefusal("A decision is answered with one of its choices, or in words")
            }
        case "reach":
            guard answer["allow"] is Bool else { throw DemoRefusal("allow must be true or false") }
        case "rule":
            guard answer["accept"] is Bool else { throw DemoRefusal("accept must be true or false") }
        case "limit":
            guard answer["start"] is Bool else { throw DemoRefusal("start must be true or false") }
        default:
            throw DemoRefusal("Unknown kind of answer: \(answer["kind"] ?? "")")
        }
    }

    private static func named(_ kind: String) -> String {
        switch kind {
        case "approval": "a request for approval"
        case "question": "a question"
        case "decision": "a decision"
        case "reach": "a request for more reach"
        case "rule": "a proposed rule"
        case "limit": "a start held back by a limit"
        default: kind
        }
    }

    /// What follows an answer: the agent that asked is told, and carries on.
    private static func carryOn(_ need: [String: Any], answer: [String: Any], world: DemoWorld) {
        guard let conversation = (need["conversationId"] as? NSNumber)?.intValue else { return }
        switch answer["kind"] as? String {
        case "approval":
            let allowed = answer["decision"] as? String != "deny"
            ranCommand(of: need, in: conversation, allowed: allowed, world: world)
        case "reach":
            if answer["allow"] as? Bool == true { allowReach(need, world: world) }
            told(conversation, answer["allow"] as? Bool == true ? "The person allowed it." : "The person refused it.", world: world)
        case "rule":
            if answer["accept"] as? Bool == true { addRule(need, text: answer["text"] as? String, binds: answer["binds"] as? String, world: world) }
            told(conversation, answer["accept"] as? Bool == true ? "The person accepted the rule." : "The person refused the rule.", world: world)
        case "decision":
            let choice = (need["choices"] as? [[String: Any]] ?? []).first { $0["id"] as? String == answer["choice"] as? String }
            told(conversation, "The person chose: \(choice?["label"] as? String ?? answer["text"] as? String ?? "")", world: world)
        case "question":
            told(conversation, "The person answered: \(answer["text"] as? String ?? "")", world: world)
        default:
            told(conversation, "The person answered.", world: world)
        }
    }

    /// The command an approval held runs (or is refused), its result is the tool's entry, and the agent finishes.
    private static func ranCommand(of need: [String: Any], in id: Int, allowed: Bool, world: DemoWorld) {
        let callID = (world.conversations[id]?.state["tools"] as? [[String: Any]])?.first?["callId"] as? String
        let tool = need["tool"] as? String ?? "bash"
        world.after(0.4) { world in
            let result: [String: Any] = [
                "id": world.newItemID(), "kind": "tool", "callId": callID ?? NSNull(), "name": tool,
                "text": allowed ? "(no output)" : "The person denied this.", "isError": !allowed, "images": 0,
            ]
            world.append([result], to: id) { $0["tools"] = [Any]() }
            world.after(0.6) { world in
                let text = allowed ? "Done. The tool returned: (no output)" : "Done. The tool returned: The person denied this."
                let entry: [String: Any] = [
                    "id": world.newItemID(), "kind": "assistant", "text": text, "thinking": "", "toolCalls": [Any](), "stop": "stop",
                    "error": NSNull(), "model": "demo-1",
                ]
                world.append([entry], to: id) { state in
                    state["busy"] = false
                    state["partial"] = NSNull()
                }
                DemoReplies.working(id, false, world: world)
            }
        }
    }

    /// The asking conversation is told the answer, as a message the demo model answers.
    private static func told(_ id: Int, _ text: String, world: DemoWorld) {
        world.after(0.4) { world in
            let entry: [String: Any] = [
                "id": world.newItemID(), "kind": "assistant", "text": "Thank you. \(text) Carrying on.", "thinking": "", "toolCalls": [Any](),
                "stop": "stop", "error": NSNull(), "model": "demo-1",
            ]
            world.append([entry], to: id)
        }
    }

    /// An allowed reach request makes its change. The demo's is to a project's settings (`project.change`, whose fields
    /// are named by their path in them, such as `withoutAsking.merge`); a change to anything else is left as it is.
    private static func allowReach(_ need: [String: Any], world: DemoWorld) {
        guard let projectID = need["projectId"] as? String,
              let op = (need["change"] as? [String: Any])?["op"] as? [String: Any], op["kind"] as? String == "project.change",
              let fields = op["fields"] as? [[String: Any]] else { return }
        world.change("projects") { event in
            event["projects"] = (event["projects"] as? [[String: Any]] ?? []).map { project in
                guard project["id"] as? String == projectID else { return project }
                var project = project
                var settings = project["settings"] as? [String: Any] ?? [:]
                for field in fields {
                    guard let path = (field["name"] as? String)?.split(separator: ".").map(String.init), path.count == 2,
                          var group = settings[path[0]] as? [String: Any], let value = field["after"] else { continue }
                    group[path[1]] = value
                    settings[path[0]] = group
                }
                project["settings"] = settings
                return project
            }
        }
    }

    /// An accepted rule joins its project's rules, as the person's own.
    private static func addRule(_ need: [String: Any], text: String?, binds: String?, world: DemoWorld) {
        guard let projectID = need["projectId"] as? String else { return }
        world.change("projectRules") { event in
            var projects = event["projects"] as? [String: Any] ?? [:]
            var rules = projects[projectID] as? [[String: Any]] ?? []
            let number = rules.compactMap { ($0["id"] as? String)?.dropFirst() }.compactMap { Int($0) }.max() ?? 0
            rules.append([
                "id": "r\(number + 1)", "text": text ?? need["text"] as? String ?? "", "binds": binds ?? need["binds"] as? String ?? "everyone",
                "addedBy": ["kind": "person"], "createdAt": world.now, "updatedAt": world.now,
            ])
            projects[projectID] = rules
            event["projects"] = projects
        }
    }
}
