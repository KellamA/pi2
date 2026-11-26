
#if DEBUG
import EngineKit
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
        change(agents.first?.id) { $0.allowEverything = true }
        if agents.count > 1, let template = data.templates.first(where: { $0.name == agents[1].name }) ?? data.templates.first {
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
/// - `PI2_BOARD_ACT`, on the Agents page: `switch:<name>` asks to turn on one of the orchestrator's switches (the
///   confirmation), `switch-on:<name>` and `switch-off:<name>` turn it as the confirmation's Turn On and the switch do;
///   `add-agent` makes an agent, `copy-template:<template>` copies one; `restore` restores the first agent removed;
///   `ask-orchestrator:<agent>` shows Make Orchestrator's confirmation, `make-orchestrator:<agent>` answers it;
///   `new-conversation:<agent>` starts a conversation with it.
///   On an agent's page: `save:<description>` changes its description and saves it; `everything-off` turns Allow
///   everything off, and `everything-on` sends what the page never offers, Allow everything on, to show the engine's
///   refusal; `memory:on` or `memory:off`; `allow-command:<words>`, `remove-command` (its first); `duplicate`;
///   `ask-delete` (the confirmation), `delete`; `update-template` opens Update from Template, `update-template:apply`
///   applies it once read; `new-conversation`.
///   On the templates: `new-template`.
///   On Rules: `add-rule:<text>`; `edit-rule` opens the first rule's sheet, `edit-rule:<text>` saves that text;
///   `bind-rule:<everyone|orchestrator>` rebinds the first; `move-rule` moves the last to the top; `ask-remove-rule`
///   (the confirmation), `remove-rule` removes the last; `accept-rule`, `refuse-rule` answer the first proposal,
///   `amend-rule` opens its sheet and `amend-rule:<text>` accepts it with that text.
///   On Notes: `add-note:<text>`; `edit-note` opens the newest note's sheet, `edit-note:<text>` saves that text;
///   `share-note` shares the first note for one agent; `delete-note` deletes the newest.
///   On Branches: `refresh`; `new-worktree[:<conversation>]` asks for a worktree's branch (with the engine's
///   suggestion), `create-worktree[:<conversation>]` makes it on the suggestion; `remove-worktree` asks to remove the
///   first worktree pi² made, or else the first left behind (the confirmation), `remove-worktree:keep`, `:branch` or `:discard` answers it.
/// - `PI2_BOARD_SCROLL=<section>`: scrolls an agent's page to a `BoardAgentSection`, such as `everything` or `commands`,
///   or the Branches page to `left-behind` or `legend`.
@MainActor
enum BoardDebugAct {
    static let act = ProcessInfo.processInfo.environment["PI2_BOARD_ACT"]
    static let scroll = ProcessInfo.processInfo.environment["PI2_BOARD_SCROLL"]
    private static var done: Set<String> = []
    /// Set by `update-template:apply`, for the sheet to apply what it read.
    static var applyTemplate = false

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
        if let name = take("switch-on") { page.debugSet(name ?? "", on: true) }
        if let name = take("switch-off") { page.debugSet(name ?? "", on: false) }
        if take("add-agent") != nil { page.debugAdd() }
        if let name = take("copy-template") { page.debugCopy(name ?? "") }
        if take("restore") != nil { page.debugRestore() }
        if let name = take("ask-orchestrator") { page.debugAskOrchestrator(name ?? "") }
        if let name = take("make-orchestrator") { page.debugMakeOrchestrator(name ?? "") }
        if let name = take("new-conversation"), let name { page.debugNewConversation(name) }
    }

    static func templates(_ view: BoardTemplatesView, _ data: BoardData) async {
        guard act != nil else { return }
        await settle()
        if take("new-template") != nil { view.debugNew(data) }
    }

    static func agent(_ form: BoardAgentForm, _ scroller: ScrollViewProxy) async {
        guard act != nil || scroll != nil else { return }
        await settle()
        if let words = take("save") { form.debugSave(words ?? "Changed from the phone") }
        if take("everything-off") != nil { form.debugEverythingOff() }
        if take("everything-on") != nil { form.debugEverythingOn() }
        if let on = take("memory") { form.debugMemory(on: on != "off") }
        if let words = take("allow-command") { form.debugAllow(words ?? "npm test") }
        if take("remove-command") != nil { form.debugRemoveCommand() }
        if take("duplicate") != nil { form.debugDuplicate() }
        if take("ask-delete") != nil { form.debugAskDelete() }
        if take("delete") != nil { form.debugDelete() }
        if let how = take("update-template") {
            applyTemplate = how == "apply"
            form.debugUpdate()
        }
        if take("new-conversation") != nil { form.debugNewConversation() }
        if let scroll, let section = BoardAgentSection(rawValue: scroll) {
            try? await Task.sleep(for: .seconds(1))
            withAnimation { scroller.scrollTo(section, anchor: .top) }
        }
    }

    static func rules(_ page: BoardRulesPage, rules: [ProjectRule]) async {
        guard act != nil else { return }
        await settle()
        if let text = take("add-rule") { page.debugAdd(text ?? "Say what you checked.") }
        if let text = take("edit-rule"), let first = rules.first {
            if let text { page.debugChange(first, text: text, binds: first.binds) } else { page.debugEdit(first) }
        }
        if let binds = take("bind-rule"), let first = rules.first {
            page.debugChange(first, text: first.text, binds: ProjectRule.Binds(rawValue: binds ?? "") ?? .orchestrator)
        }
        if take("move-rule") != nil { page.debugMoveLastToTop(rules) }
        if take("ask-remove-rule") != nil, let last = rules.last { page.debugAskRemove(last) }
        if take("remove-rule") != nil, let last = rules.last { page.remove(last) }
    }

    static func proposal(_ card: BoardRuleProposal) async {
        guard act != nil else { return }
        await settle()
        guard card.debugIsFirst else { return }
        if take("accept-rule") != nil { card.debugAnswer(true) }
        if take("refuse-rule") != nil { card.debugAnswer(false) }
        if let text = take("amend-rule") {
            if let text { card.debugAccept(text) } else { card.amend() }
        }
    }

    static func notes(_ page: BoardNotesPage, notes: [BoardNote]) async {
        guard act != nil else { return }
        await settle()
        if let text = take("add-note") { page.debugAdd(text ?? "Friday's walkthrough is at ten.") }
        if let text = take("edit-note"), let first = notes.first {
            if let text { page.debugSave(first, text: text) } else { page.debugEdit(first) }
        }
        if take("share-note") != nil, let shared = notes.first(where: { $0.audience != nil }) { page.share(shared) }
        if take("delete-note") != nil, let first = notes.first { page.delete(first) }
    }

    static func branches(_ page: BoardBranchesPage, data: BoardData, scroller: ScrollViewProxy) async {
        guard act != nil || scroll != nil else { return }
        await settle()
        if let scroll { withAnimation { scroller.scrollTo(scroll, anchor: .top) } }
        let rows = data.branchGroups(page.project.id).flatMap(\.rows)
        func conversation(_ named: String?) -> Int? {
            named.flatMap(Int.init) ?? rows.first(where: { !$0.status.managed && $0.sharing == nil })?.conversation.id
        }
        if take("refresh") != nil { await page.refresh() }
        if let named = take("new-worktree"), let id = conversation(named) { page.ask(id) }
        if let named = take("create-worktree"), let id = conversation(named) {
            page.ask(id)
            // The question opens once the engine's suggestion has come, with it in the field.
            for _ in 0..<50 where page.debugAsked == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1))
            page.debugCreate()
        }
        // The first worktree pi² made for a listed conversation, else the first left behind.
        let target = rows.first(where: { $0.status.managed }).map { BoardWorktreeRemoval(conversation: $0.conversation.id, status: $0.status) }
            ?? data.leftBehind(page.project.id).first.map { BoardWorktreeRemoval(conversation: $0.id, status: $0.status) }
        if let how = take("remove-worktree"), let removal = target {
            switch how {
            case "keep": page.debugRemove(removal, force: false, deleteBranch: false)
            case "branch": page.debugRemove(removal, force: false, deleteBranch: true)
            case "discard": page.debugRemove(removal, force: true, deleteBranch: false)
            default: page.debugRemove(removal.conversation, status: removal.status)
            }
        }
    }

    /// What the Agents page never offers, sent to show that the engine keeps it to the Mac (docs/iphone.md 4.2, question
    /// 5): Allow everything turned on. Not in `BoardRequests`, whose every form turns it off.
    static func allowEverythingOn(_ engine: EngineSession<MessageField>, agent: String) async -> String? {
        do {
            _ = try await engine.call("agents.allowEverything", ["id": agent, "on": true])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
