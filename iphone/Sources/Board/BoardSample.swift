
#if DEBUG
import Foundation
import PiModels
import SwiftUI

/// Sample values a debug build lays over what the engine sent, so that the board's states the recorded session has no
/// example of (branches and worktrees, a proposed rule, an agent that allows everything, one removed, one whose template
/// changed) can be drawn and pictured in the simulator (docs/iphone-app.md, "Drawing a screen and picturing it"). Asked
/// for with `PI2_BOARD_SAMPLE=1`, and said at the top of every page that shows them. They are plainly sample data, fed to
/// the views as values: nothing answers for the engine, and every request still goes to it, so against the recording
/// each is refused. None of it is compiled into a release build.
enum BoardSample {
    static let asked = ProcessInfo.processInfo.environment["PI2_BOARD_SAMPLE"] != nil

    static func overlay(_ data: inout BoardData) {
        guard asked else { return }
        data.sample = "the branches, a proposed rule, a note an agent wrote, and some agents' marks"
        for project in data.projects {
            overlay(&data, project: project)
        }
    }

    private static func overlay(_ data: inout BoardData, project: ProjectRow) {
        let folder = project.folder ?? "/sample/\(project.name)"
        let repo = (folder as NSString).lastPathComponent
        let conversations = data.conversations.filter { $0.projectId == project.id && $0.chat != true }
        // The orchestrator's in the main checkout, its sub-chats in it too, and each other agent's in a worktree of its own.
        var states = ["changes", "ahead", "merged", "conflict"].makeIterator()
        for conversation in conversations {
            if conversation.orchestrator != nil {
                data.branches[conversation.id] = status(repo: repo, root: folder, branch: "main", state: "clean", upstream: "origin/main")
            } else if conversation.parent != nil {
                data.branches[conversation.id] = status(repo: repo, root: folder, branch: "main", state: "clean", upstream: "origin/main")
            } else if let state = states.next() {
                let branch = "pi2/\(conversation.id)-\(conversation.title.lowercased().split(separator: " ").prefix(3).joined(separator: "-"))"
                data.branches[conversation.id] = status(repo: repo, root: folder + "-worktrees/\(conversation.id)", branch: branch, state: state,
                                                        worktree: true, managed: true, changes: state == "changes" ? 3 : 0,
                                                        conflicts: state == "conflict" ? 1 : 0, operation: state == "conflict" ? "rebase" : nil,
                                                        unmerged: state == "merged" ? 0 : 2, added: 128, removed: 14)
            }
        }
        if let left = try? decode(LeftBehindWorktree.self, [
            "id": 9000 + data.leftBehind.count, "title": "Try the other layout", "reason": "deleted",
            "status": json(status(repo: repo, root: folder + "-worktrees/old", branch: "pi2/try-the-other-layout", state: "ahead", worktree: true,
                                  managed: true, unmerged: 1, added: 40, removed: 2)),
        ]) {
            data.leftBehind.append(left)
        }

        let agents = data.projectAgents(project)
        if let need = try? decode(NeedItem.self, [
            "id": "sample-rule-\(project.id)", "projectId": project.id, "kind": "rule", "conversationId": project.conversation ?? 0,
            "rootConversationId": project.conversation ?? 0, "title": "", "rootTitle": "", "agentId": agents.first?.id ?? project.orchestratorId,
            "agentName": agents.first?.name ?? "Orchestrator", "blocking": false, "createdAt": Date.now.timeIntervalSince1970 * 1000,
            "text": "Run the tests before asking for a review.", "binds": "everyone", "why": "Two reviews this week came back for a failing test.",
        ]) {
            data.ruleNeeds[project.id, default: []].insert(need, at: 0)
        }

        // An agent that allows everything, one whose template changed, one made by the orchestrator, one removed.
        func change(_ id: String?, _ edit: (inout AgentProfile) -> Void) {
            guard let id, let index = data.allAgents.firstIndex(where: { $0.id == id }) else { return }
            edit(&data.allAgents[index])
        }
        let template = data.templates.first
        change(agents.first?.id) { $0.allowEverything = true }
        if agents.count > 1, let template {
            change(agents[1].id) { agent in
                agent.template = try? decode(TemplateMark.self, ["id": template.id, "copiedAt": 0, "templateUpdatedAt": -1])
                agent.variables = try? decode([AgentVariable].self, [["name": "GH_TOKEN", "set": true], ["name": "NPM_TOKEN", "set": false]])
            }
        }
        if agents.count > 2 {
            change(agents[2].id) { $0.madeBy = try? decode(MadeByMark.self, ["agentId": project.orchestratorId, "conversationId": project.conversation ?? 0]) }
        }
        if agents.count > 3 {
            change(agents[3].id) { $0.removedAt = Date.now.timeIntervalSince1970 * 1000 - 3_600_000 }
        }

        // A note an agent wrote, beside the person's.
        if case .object(var memory)? = data.memory, case .object(var projects)? = memory["projects"],
           case .object(var notes)? = projects[project.id], case .array(var list)? = notes["notes"] {
            list.append(.object([
                "id": .string("sample-note"), "text": .string("The preview build needs the sample fonts installed first."),
                "agentId": .string(agents.first?.id ?? project.orchestratorId), "createdAt": .number(Date.now.timeIntervalSince1970 * 1000), "audience": .null,
            ]))
            notes["notes"] = .array(list)
            projects[project.id] = .object(notes)
            memory["projects"] = .object(projects)
            data.memory = .object(memory)
        }
    }

    /// A branch's state as the engine's tracker sends it.
    static func status(repo: String, root: String, branch: String?, state: String, worktree: Bool = false, managed: Bool = false,
                       upstream: String? = nil, changes: Int = 0, conflicts: Int = 0, operation: String? = nil, unmerged: Int? = nil,
                       added: Int? = nil, removed: Int? = nil) -> BranchStatus {
        var object: [String: Any] = [
            "repo": repo, "root": root, "worktree": worktree, "managed": managed, "ahead": state == "ahead" ? 2 : 0, "behind": 0,
            "changes": changes, "conflicts": conflicts, "state": state, "head": "4f2c9e1",
        ]
        if let branch { object["branch"] = branch }
        if let upstream { object["upstream"] = upstream }
        if let operation { object["operation"] = operation }
        if managed { object["base"] = "main" }
        if let unmerged { object["unmerged"] = unmerged }
        if let added { object["added"] = added }
        if let removed { object["removed"] = removed }
        // Every value above decodes, so this cannot fail.
        return try! decode(BranchStatus.self, object)
    }

    private static func json(_ value: some Encodable) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:]
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// What a debug build's environment asks the board's pages to do once they show, so that a state reached by a tap can be
/// pictured in the simulator without one. Each sends the real request, through the same client, and shows what the
/// engine answers: against the recorded session, its refusal. None of it is compiled into a release build.
///
/// - `PI2_BOARD_ACT`: `switch:<name>` asks to turn on one of the orchestrator's switches (the confirmation); `add-agent`
///   makes an agent; `add-rule:<text>`, `edit-rule`; `add-note:<text>`, `edit-note`; `remove-worktree` asks to remove
///   the first worktree pi² made (the confirmation); `save:<description>` changes an agent's description and saves it;
///   `everything-off` turns Allow everything off.
/// - `PI2_BOARD_SCROLL=<section>`: scrolls an agent's page to a `BoardAgentSection`, such as `everything` or `commands`.
@MainActor
enum BoardDebugAct {
    static let act = ProcessInfo.processInfo.environment["PI2_BOARD_ACT"]
    static let scroll = ProcessInfo.processInfo.environment["PI2_BOARD_SCROLL"]
    private static var done: Set<String> = []

    /// Whether `name` was asked for and not done yet, with what follows `name:`; marks it done.
    private static func take(_ name: String) -> String?? {
        guard let act, act == name || act.hasPrefix(name + ":"), !done.contains(name) else { return nil }
        done.insert(name)
        return act.hasPrefix(name + ":") ? .some(String(act.dropFirst(name.count + 1))) : .some(nil)
    }

    /// Long enough for the engine's lists to be drawn; a picture aid, not a test.
    private static func settle() async { try? await Task.sleep(for: .seconds(1.5)) }

    static func agents(_ page: BoardAgentsPage) async {
        guard act != nil else { return }
        await settle()
        if let name = take("switch") { page.debugAsk(name ?? "") }
        if take("add-agent") != nil { page.debugAdd() }
    }

    static func agent(_ form: BoardAgentForm, _ scroller: ScrollViewProxy) async {
        guard act != nil || scroll != nil else { return }
        await settle()
        if let words = take("save") { form.debugSave(words ?? "Changed from the phone") }
        if take("everything-off") != nil { form.debugEverythingOff() }
        if let scroll, let section = BoardAgentSection(rawValue: scroll) {
            try? await Task.sleep(for: .seconds(1))
            withAnimation { scroller.scrollTo(section, anchor: .top) }
        }
    }

    static func rules(_ page: BoardRulesPage, rules: [ProjectRule]) async {
        guard act != nil else { return }
        await settle()
        if let text = take("add-rule") { page.debugAdd(text ?? "Say what you checked.") }
        if take("edit-rule") != nil, let first = rules.first { page.debugEdit(first) }
    }

    static func notes(_ page: BoardNotesPage, notes: [BoardNote]) async {
        guard act != nil else { return }
        await settle()
        if let text = take("add-note") { page.debugAdd(text ?? "Friday's walkthrough is at ten.") }
        if take("edit-note") != nil, let first = notes.first { page.debugEdit(first) }
    }

    static func branches(_ page: BoardBranchesPage, data: BoardData) async {
        guard act != nil else { return }
        await settle()
        if take("remove-worktree") != nil, let row = data.branchGroups(page.project.id).flatMap(\.rows).first(where: { $0.status.managed }) {
            page.debugRemove(row.conversation.id, status: row.status)
        }
    }
}
#endif
