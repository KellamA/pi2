
import EngineKit
import Foundation
import PiModels

/// The requests the board's pages send, each made as the Mac app makes it, through the same client (`session.engine`), so
/// that they work as they are the day a Mac answers them. Each answers nil once the engine has taken the request, or the
/// engine's own words when it refused it or could not be reached, for the page to say beside what was changed. Nothing
/// here answers for the engine.
///
/// What a device may send is docs/iphone.md 4.2's: every request here is one a phone may send in a session Face ID
/// opened, the ones that widen reach notified on the Mac. `agents.allowEverything` with `on: true` is the Mac's alone, so
/// `allowEverythingOff` is the only form of it here; `variables.*`, choosing a folder or files in the Mac's panels, and an
/// agent's computer use and browser stay on the Mac, and nothing here sends them.
@MainActor
enum BoardRequests {
    typealias Engine = EngineSession<MessageField>

    // MARK: - The Agents page

    /// One of the switches of what the orchestrator may do without asking (docs/projects.md, 8.1), as the Mac's
    /// orchestrator card sets it (`OrchestratorCard.set`). Widens when on: the page asks first, as the Mac's does.
    static func setSwitch(_ engine: Engine, project: String, name: String, on: Bool) async -> String? {
        await failure { try await engine.call("projects.set", ["id": project, "settings": ["withoutAsking": [name: on]]]) }
    }

    /// Makes an agent of the project by hand, as the Mac's New Agent does (`ProjectAgentsTab.makeAgent`): a unique name, no
    /// description, tool access off. Answers the new agent's id, or the engine's words.
    static func newAgent(_ engine: Engine, project: String, named name: String) async -> Result<String, BoardFailure> {
        await made { try await engine.call("projects.addAgent", ["projectId": project, "agent": ["name": name, "description": "", "access": "none"]]) }
    }

    /// Copies a template into the project, as the Mac's From a Template does (`ProjectAgentsTab.copyTemplate`).
    static func copyTemplate(_ engine: Engine, project: String, template: String) async -> Result<String, BoardFailure> {
        await made { try await engine.call("projects.addAgent", ["projectId": project, "template": template]) }
    }

    /// Puts back an agent removed through a tool, as the Mac's Restore does.
    static func restore(_ engine: Engine, agent: String) async -> String? {
        await failure { try await engine.call("agents.restore", ["id": agent]) }
    }

    /// Makes another agent the project's orchestrator, with a fresh conversation (docs/projects.md, 6.5), as the Mac's
    /// Make Orchestrator does once confirmed (`AppModel.makeOrchestrator`).
    static func makeOrchestrator(_ engine: Engine, project: String, agent: String) async -> String? {
        await failure { try await engine.call("projects.setOrchestrator", ["id": project, "agentId": agent]) }
    }

    /// Starts a conversation with an agent, as the Mac's New Conversation does (`EngineSession.createConversation`):
    /// answers its id, to open.
    static func newConversation(_ engine: Engine, agent: String) async -> Result<Int, BoardFailure> {
        do {
            let result = try await engine.call("conversation.create", ["agentId": agent])
            guard let id = result["id"]?.intValue else { return .failure(BoardFailure("The Mac did not say which conversation it made.")) }
            return .success(id)
        } catch {
            return .failure(BoardFailure(error.localizedDescription))
        }
    }

    // MARK: - An agent's page

    /// Saves what the person changed of an agent, and nothing else, as the Mac's page does (`AgentEditor.save`): the
    /// settings edited since the page last caught up, with the id and the name, which are always sent.
    static func save(_ engine: Engine, draft: AgentProfile, edited: Set<String>) async -> String? {
        await failure { try await engine.call("agents.save", ["agent": BoardAgentDraft.payload(draft, edited: edited)]) }
    }

    /// Makes a template with a unique name, as the Mac's New Agent does with no project (`AppModel.newAgent`).
    static func newTemplate(_ engine: Engine, named name: String) async -> Result<String, BoardFailure> {
        await made { try await engine.call("agents.save", ["agent": ["name": name, "description": "", "access": "none"]]) }
    }

    /// Duplicates an agent's saved settings, as the Mac's Duplicate does (`AppModel.duplicateAgent`): answers the copy's id.
    static func duplicate(_ engine: Engine, agent: String) async -> Result<String, BoardFailure> {
        await made { try await engine.call("agents.duplicate", ["id": agent]) }
    }

    /// Deletes an agent, as the Mac's Delete Agent… does once confirmed. Its conversations stay.
    static func delete(_ engine: Engine, agent: String) async -> String? {
        await failure { try await engine.call("agents.delete", ["id": agent]) }
    }

    /// Turns Allow everything off. Turning it on is the Mac's alone (docs/iphone.md 4.2, question 5): no form of this sends
    /// `on: true`.
    static func allowEverythingOff(_ engine: Engine, agent: String) async -> String? {
        await failure { try await engine.call("agents.allowEverything", ["id": agent, "on": false]) }
    }

    /// The agent's memory switch, as the Mac's page sets it (`AgentMemorySwitch.set`), at once, without Save.
    static func setMemory(_ engine: Engine, agent: String, on: Bool) async -> String? {
        await failure { try await engine.call("memory.setEnabled", ["agentId": agent, "enabled": on]) }
    }

    /// Allows a command in a folder, as the Mac's Allowed commands do (`CommandRulesSection.add`).
    static func allowCommand(_ engine: Engine, agent: String, folder: String, command: String) async -> String? {
        await failure { try await engine.call("rules.add", ["agentId": agent, "folder": folder, "command": command]) }
    }

    /// Takes an allowed command away, as the Mac's Remove does (`CommandRulesSection.remove`): the agent asks again.
    static func removeCommand(_ engine: Engine, agent: String, rule: CommandRule) async -> String? {
        await failure { try await engine.call("rules.remove", ["agentId": agent, "folder": rule.folder, "words": rule.words]) }
    }

    /// What Update from Template would change, changing nothing, as the Mac's sheet asks first (`apply: false`).
    static func templateChanges(_ engine: Engine, agent: String) async -> Result<[BoardTemplateChange], BoardFailure> {
        do {
            let result = try await engine.call("agents.updateFromTemplate", ["id": agent, "apply": false])
            return .success((result["changes"]?.arrayValue ?? []).compactMap(BoardTemplateChange.init))
        } catch {
            return .failure(BoardFailure(error.localizedDescription))
        }
    }

    /// Brings a copy up to date with its template, as the Mac's sheet's Update does.
    static func updateFromTemplate(_ engine: Engine, agent: String) async -> String? {
        await failure { try await engine.call("agents.updateFromTemplate", ["id": agent, "apply": true]) }
    }

    // MARK: - Rules

    /// Adds a rule, as the Mac's field does (`AddRuleField.add`).
    static func addRule(_ engine: Engine, project: String, text: String, binds: ProjectRule.Binds) async -> String? {
        await failure { try await engine.call("projects.rules.add", ["projectId": project, "text": text, "binds": binds.rawValue]) }
    }

    /// Changes a rule's text, as the Mac's row does when the field is left (`RuleRow.commit`).
    static func editRule(_ engine: Engine, project: String, rule: String, text: String) async -> String? {
        await failure { try await engine.call("projects.rules.edit", ["projectId": project, "id": rule, "text": text]) }
    }

    /// Changes whom a rule binds, as the Mac's menu on the row does.
    static func bindRule(_ engine: Engine, project: String, rule: String, binds: ProjectRule.Binds) async -> String? {
        await failure { try await engine.call("projects.rules.edit", ["projectId": project, "id": rule, "binds": binds.rawValue]) }
    }

    /// Moves a rule to a place counted from 0 (docs/projects.md, 4.2), as the Mac's up and down buttons do.
    static func moveRule(_ engine: Engine, project: String, rule: String, to place: Int) async -> String? {
        await failure { try await engine.call("projects.rules.move", ["projectId": project, "id": rule, "to": place]) }
    }

    /// Removes a rule, as the Mac's Remove does once confirmed.
    static func removeRule(_ engine: Engine, project: String, rule: String) async -> String? {
        await failure { try await engine.call("projects.rules.remove", ["projectId": project, "id": rule]) }
    }

    /// Answers a proposed rule, as the Mac's card does (`RuleProposalCard.answer`): accepted as it is, accepted with the
    /// text or whom it binds changed, or refused.
    static func answerProposal(_ engine: Engine, need: String, accept: Bool, text: String? = nil, binds: ProjectRule.Binds? = nil) async -> String? {
        var answer: [String: Any] = ["kind": "rule", "accept": accept]
        if let text { answer["text"] = text }
        if let binds { answer["binds"] = binds.rawValue }
        return await failure { try await engine.call("needs.answer", ["id": need, "answer": answer]) }
    }

    // MARK: - Notes

    /// Adds a note of the person's own, which every agent of the project is given, as the Mac's field does.
    static func addNote(_ engine: Engine, project: String, text: String) async -> String? {
        await failure { try await engine.call("memory.add", ["projectId": project, "text": text]) }
    }

    /// Corrects a note's text, as the Mac's row does when the field is left.
    static func editNote(_ engine: Engine, project: String, note: String, text: String) async -> String? {
        await failure { try await engine.call("memory.edit", ["projectId": project, "id": note, "text": text]) }
    }

    /// Shares a note one agent wrote for itself with every agent of the project, as the Mac's Share with the Project does.
    static func shareNote(_ engine: Engine, project: String, note: String) async -> String? {
        await failure { try await engine.call("memory.edit", ["projectId": project, "id": note, "audience": NSNull()]) }
    }

    /// Deletes a note, as the Mac's Delete note does.
    static func deleteNote(_ engine: Engine, project: String, note: String) async -> String? {
        await failure { try await engine.call("memory.delete", ["projectId": project, "id": note]) }
    }

    // MARK: - Branches

    /// Asks the engine to look at the branches again now, as the Mac's Refresh does.
    static func refreshBranches(_ engine: Engine) async -> String? {
        await failure { try await engine.call("branches.refresh") }
    }

    /// The branch name the engine suggests for a conversation's new worktree, as the Mac's dialog fills in; nil when it
    /// suggests none or cannot be asked.
    static func suggestBranch(_ engine: Engine, conversation: Int) async -> String? {
        try? await engine.call("worktree.suggest", ["id": conversation])["branch"]?.stringValue
    }

    /// Moves a conversation into a worktree of its own on `branch`, or on the engine's choice when it is empty, as the
    /// Mac's New Worktree… does.
    static func createWorktree(_ engine: Engine, conversation: Int, branch: String) async -> String? {
        var params: [String: Any] = ["id": conversation]
        let branch = branch.trimmingCharacters(in: .whitespaces)
        if !branch.isEmpty { params["branch"] = branch }
        return await failure { try await engine.call("worktree.create", params) }
    }

    /// Removes a conversation's worktree, as the Mac's Remove Worktree… does once the person chose how. Answers the
    /// engine's note (a branch kept, and why), or its refusal.
    static func removeWorktree(_ engine: Engine, conversation: Int, force: Bool, deleteBranch: Bool) async -> Result<String?, BoardFailure> {
        do {
            let result = try await engine.call("worktree.remove", ["id": conversation, "force": force, "deleteBranch": deleteBranch])
            return .success(result["note"]?.stringValue)
        } catch {
            return .failure(BoardFailure(error.localizedDescription))
        }
    }

    // MARK: -

    /// The engine's words when `request` fails, nil when it is answered.
    private static func failure(_ request: () async throws -> JSONValue) async -> String? {
        do {
            _ = try await request()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The id a request that makes something answers with, or the engine's words.
    private static func made(_ request: () async throws -> JSONValue) async -> Result<String, BoardFailure> {
        do {
            guard let id = try await request()["id"]?.stringValue else { return .failure(BoardFailure("The Mac did not say what it made.")) }
            return .success(id)
        } catch {
            return .failure(BoardFailure(error.localizedDescription))
        }
    }
}

/// The engine's words for a request it refused, or could not be asked.
struct BoardFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One setting Update from Template would change: its value in the copy now, and the template's.
struct BoardTemplateChange: Identifiable, Equatable {
    let setting: String
    let now: JSONValue
    let template: JSONValue
    var id: String { setting }

    init?(_ item: JSONValue) {
        guard let setting = item["setting"]?.stringValue else { return nil }
        self.setting = setting
        now = item["now"] ?? .null
        template = item["template"] ?? .null
    }
}
