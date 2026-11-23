
import EngineKit
import Foundation
import PiModels

/// What the board's pages read of the engine's state (docs/design/iphone.md, "Every screen and function of the Mac
/// app"): the projects, the agents and templates, each project's rules and notes, and the branches its conversations
/// work on, as the Mac's board reads them (app/Sources/pi2/ProjectAgentsTab.swift, ProjectRulesTab.swift,
/// ProjectNotesTab.swift, BranchViews.swift). A value, so that the pages, their tests and a debug build's sample draw from
/// the same readings; nothing in it is kept: it is read again from `session.engine` each time a page is drawn.
struct BoardData {
    /// Whether the engine's connection is up; every change is refused while it is not.
    var connected = false
    /// Whether the engine's lists have come at least once, so that a project or an agent not in them is really not there.
    var loaded = false
    var projects: [ProjectRow] = []
    /// Every agent, the projects' own and the templates.
    var allAgents: [AgentProfile] = []
    var projectRules: [String: [ProjectRule]] = [:]
    /// Proposed rules waiting under Needs you, by project.
    var ruleNeeds: [String: [NeedItem]] = [:]
    /// The latest `memory` event, as sent: each project's notes, and each agent's memory switch.
    var memory: JSONValue?
    var conversations: [ConversationSummary] = []
    var archived: [ArchivedConversation] = []
    var branches: [Int: BranchStatus] = [:]
    var leftBehind: [LeftBehindWorktree] = []
    var activity: [ActivityRun] = []
    var allModels: [ModelInfo] = []
    var defaultModel: ModelRef?
    var builtInTools: [BuiltInTool] = []
    var mcpServers: [McpServer] = []
    /// Set by a debug build's sample (`BoardSample`), which the pages then say they show.
    var sample: String?

    init() {}

    @MainActor init(_ engine: EngineSession<MessageField>) {
        connected = engine.status == .connected
        loaded = engine.hasLoadedLibrary
        projects = engine.projects
        allAgents = engine.allAgents
        projectRules = engine.projectRules
        ruleNeeds = engine.ruleNeeds
        memory = engine.extras["memory"]
        conversations = engine.conversations
        archived = engine.archived
        branches = engine.branches
        leftBehind = engine.leftBehind
        activity = engine.activity
        allModels = engine.allModels
        defaultModel = engine.defaultModel
        builtInTools = engine.builtInTools
        mcpServers = engine.mcpServers
    }

    // MARK: - Projects and agents

    /// A project the phone can show: in the `projects` event, and not deleted (the Mac's `EngineClient.project(_:)`).
    func project(_ id: String) -> ProjectRow? {
        projects.first { $0.id == id && $0.deletedAt == nil }
    }

    func agent(_ id: String?) -> AgentProfile? {
        allAgents.first { $0.id == id }
    }

    /// The templates: agents of no project, kept to make a project's agents from (the Mac's `engine.agents`).
    var templates: [AgentProfile] {
        allAgents.filter { $0.projectId == nil }
    }

    /// The project's other agents, not removed, in the order they were made, as the Mac's Agents tab lists them.
    func projectAgents(_ project: ProjectRow) -> [AgentProfile] {
        allAgents
            .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Agents removed through a tool (docs/projects.md, 3.3), kept whole so that Restore puts them back as they were.
    func removedAgents(_ project: ProjectRow) -> [AgentProfile] {
        allAgents
            .filter { $0.projectId == project.id && $0.removedAt != nil }
            .sorted { ($0.removedAt ?? 0, $0.id) < ($1.removedAt ?? 0, $1.id) }
    }

    /// Whether the agent is working in the project now.
    func working(_ agent: String, in project: String) -> Bool {
        activity.contains { $0.projectId == project && $0.runsAs == agent }
    }

    /// A model's name as the Mac's lists show it: "Opus 5.5" rather than "Claude Opus 5.5"; nil means the default.
    func shortModelName(_ ref: ModelRef?) -> String {
        guard let ref = ref ?? defaultModel else { return "" }
        let name = allModels.first { $0.ref == ref }?.name ?? ref.modelId
        for prefix in ["Claude ", "Demo model "] where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? name : rest.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return name
    }

    /// "Anthropic · Opus 5.5": a model with its provider, as a picker shows it closed.
    func fullModelName(_ ref: ModelRef) -> String {
        guard let model = allModels.first(where: { $0.ref == ref }) else { return "\(ref.modelId) (not connected)" }
        return "\(model.providerName) · \(model.name)\(model.hidden == true ? " (hidden)" : "")"
    }

    /// "App default (Anthropic · Opus 5.5)": what an agent with no model of its own starts on.
    var appDefaultName: String {
        guard let ref = defaultModel else { return "App default" }
        let name = allModels.first { $0.ref == ref }.map { "\($0.providerName) · \($0.name)" } ?? ref.modelId
        return "App default (\(name))"
    }

    /// The models a picker offers, by provider in name order (EngineKit's `modelGroups`).
    var modelGroups: [(provider: String, name: String, models: [ModelInfo])] {
        Dictionary(grouping: allModels.filter { $0.hidden != true }, by: \.provider)
            .map { (provider: $0.key, name: $0.value[0].providerName, models: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Who made this agent through a tool (docs/projects.md, 3.3), as the Mac's row says it.
    func madeBy(_ agent: AgentProfile, in project: ProjectRow) -> String? {
        guard let mark = agent.madeBy else { return nil }
        if mark.agentId == project.orchestratorId { return "Made by the orchestrator" }
        return "Made by \(self.agent(mark.agentId)?.name ?? "an agent")"
    }

    /// Whether the template this agent was copied from has changed since (docs/projects.md, 3.3).
    func templateChanged(_ agent: AgentProfile) -> Bool {
        guard let mark = agent.template, let template = self.agent(mark.id), template.projectId == nil else { return false }
        return (template.updatedAt ?? template.createdAt) != mark.templateUpdatedAt
    }

    /// Whether the template this agent was copied from has been deleted, so that it cannot be updated from it.
    func templateGone(_ agent: AgentProfile) -> Bool {
        guard let mark = agent.template else { return false }
        return self.agent(mark.id) == nil || self.agent(mark.id)?.projectId != nil
    }

    /// The agents this one may be allowed to hand work to: a template's are the templates, a project agent's its
    /// project's agents.
    func delegateCandidates(_ agent: AgentProfile) -> [AgentProfile] {
        allAgents.filter { $0.id != agent.id && $0.projectId == agent.projectId }
    }

    /// The agent's memory switch, from the `memory` event (the Mac's `AgentMemoryState`).
    func memoryEnabled(_ agent: String) -> Bool {
        if case .bool(let on)? = memory?["agents"]?[agent]?["enabled"] { return on }
        return false
    }

    // MARK: - Rules

    func rules(_ project: String) -> [ProjectRule] {
        projectRules[project] ?? []
    }

    func proposals(_ project: String) -> [NeedItem] {
        ruleNeeds[project] ?? []
    }

    /// Who added the rule and when, as the Mac's row says it.
    func origin(_ rule: ProjectRule) -> String {
        let when = Date(timeIntervalSince1970: rule.createdAt / 1000).formatted(date: .abbreviated, time: .shortened)
        switch rule.addedBy {
        case .person:
            return "Added by you, \(when)"
        case .agent(let agentId, _):
            return "Added by \(agent(agentId)?.name ?? "the orchestrator"), \(when)"
        case .proposal(let agentId, _, _):
            return "Proposed by \(agent(agentId)?.name ?? "an agent"), accepted by you, \(when)"
        }
    }

    /// What the rules cost at every request (docs/projects.md, 6.2), or nil when the engine sends no estimate.
    static func ruleCost(_ tokens: ProjectRow.RuleTokens?) -> String? {
        guard let tokens else { return nil }
        return "About \(tokens.orchestrator) tokens with every request to the orchestrator, \(tokens.agents) to each other agent. The rules are read whole again at every request, so a shorter list costs less."
    }

    // MARK: - Notes

    /// The project's notes, newest first, from the `memory` event's `projects` (the Mac's `ProjectNotes`).
    func notes(_ project: String) -> [BoardNote] {
        (memory?["projects"]?[project]?["notes"]?.arrayValue ?? []).compactMap(BoardNote.init)
            .sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }

    /// The agent's name, or the one a note kept when it was carried over, or what the Mac calls an agent that has gone.
    func writer(_ agentId: String, of note: BoardNote) -> String {
        agent(agentId)?.name ?? note.carriedFrom ?? "a deleted agent"
    }

    /// Who wrote a note and when, as the Mac's row says it.
    func origin(_ note: BoardNote) -> String {
        let when = note.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let agentId = note.agentId else { return "Added by you, \(when)" }
        return "Written by \(writer(agentId, of: note)), \(when)"
    }

    // MARK: - Branches

    /// The project's conversations working in git, grouped by repository in name order, most pressing state first, with
    /// each sub-chat in its parent's checkout listed under the conversation whose checkout it is (the Mac's
    /// `BranchTracker.groups`).
    func branchGroups(_ project: String) -> [BoardBranchGroup] {
        let rows: [BoardBranchRow] = conversations.compactMap { conversation in
            guard conversation.projectId == project, let status = branches[conversation.id] else { return nil }
            return BoardBranchRow(conversation: conversation, status: status, sharing: sharing(of: conversation.id))
        }
        return Dictionary(grouping: rows, by: \.status.repo)
            .map { repo, rows in
                let sorted = rows.sorted {
                    let a = BranchStatus.boardOrder.firstIndex(of: $0.status.state) ?? 99
                    let b = BranchStatus.boardOrder.firstIndex(of: $1.status.state) ?? 99
                    return a != b ? a < b : $0.conversation.updatedAt > $1.conversation.updatedAt
                }
                let tops = Set(sorted.filter { $0.sharing == nil }.map(\.id))
                let isNested = { (row: BoardBranchRow) in row.sharing.map { tops.contains($0.id) } ?? false }
                let under = Dictionary(grouping: sorted.filter(isNested), by: { $0.sharing!.id })
                let ordered = sorted.filter { !isNested($0) }.flatMap { row in
                    [row] + (under[row.id] ?? [])
                        .sorted { ($0.conversation.createdAt ?? 0) < ($1.conversation.createdAt ?? 0) }
                        .map { var nested = $0; nested.nested = true; return nested }
                }
                return BoardBranchGroup(repo: repo, rows: ordered)
            }
            .sorted { $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending }
    }

    /// For a sub-chat working in a checkout that is not its own: the conversation it is listed under, the one pi² made
    /// the worktree for further up, or its parent whose checkout it shares (the Mac's `EngineClient.sharing(of:)`).
    func sharing(of id: Int) -> ConversationSummary? {
        guard let status = branches[id], !status.managed else { return nil }
        // A worktree pi² made for a conversation further up.
        if status.worktree {
            var seen: Set<Int> = [id]
            var parentID = conversations.first { $0.id == id }?.parent
            while let next = parentID, seen.insert(next).inserted, let parent = conversations.first(where: { $0.id == next }),
                  let parentStatus = branches[next], parentStatus.root == status.root {
                if parentStatus.managed { return parent }
                parentID = parent.parent
            }
        }
        guard let parentID = conversations.first(where: { $0.id == id })?.parent,
              let parent = conversations.first(where: { $0.id == parentID }),
              branches[parentID]?.root == status.root else { return nil }
        return parent
    }

    /// Worktrees of conversations archived in this project, and of deleted conversations in a repository the project's
    /// conversations work in or named as its folder is (the Mac's `BranchTracker.leftBehind`).
    func leftBehind(_ project: String) -> [LeftBehindWorktree] {
        var repos = Set(conversations.filter { $0.projectId == project }.compactMap { branches[$0.id]?.repo })
        if let folder = self.project(project)?.folder { repos.insert((folder as NSString).lastPathComponent) }
        return leftBehind.filter { item in
            item.reason == "archived"
                ? archived.first(where: { $0.id == item.id })?.projectId == project
                : repos.contains(item.status.repo)
        }
    }

    /// "3 conversations in git · 1 in a worktree of its own", as the Mac's Branches bar says it.
    func branchSummary(_ project: String) -> String {
        let ids = Set(conversations.filter { $0.projectId == project }.map(\.id))
        let rows = branches.filter { ids.contains($0.key) }.values
        let worktrees = rows.filter(\.managed).count
        let own = worktrees == 0 ? "" : " · \(worktrees) in \(worktrees == 1 ? "a worktree of its own" : "worktrees of their own")"
        return "\(rows.count) conversation\(rows.count == 1 ? "" : "s") in git\(own)"
    }
}

/// One note of a project, as the `memory` event sends it (docs/projects.md, 3.8).
struct BoardNote: Identifiable, Equatable {
    let id: String
    let text: String
    let createdAt: Date
    /// The agent that wrote it; nil for the person.
    let agentId: String?
    /// Who is given it: nil, every agent of the project; an agent's id, that agent alone.
    let audience: String?
    /// The name of the agent whose note it was copied from, when carried over.
    let carriedFrom: String?

    init?(_ item: JSONValue) {
        guard let id = item["id"]?.stringValue, let text = item["text"]?.stringValue else { return nil }
        self.id = id
        self.text = text
        var written = 0.0
        if case .number(let milliseconds)? = item["createdAt"] { written = milliseconds }
        createdAt = Date(timeIntervalSince1970: written / 1000)
        agentId = item["agentId"]?.stringValue
        audience = item["audience"]?.stringValue
        carriedFrom = item["carriedFrom"]?["agentName"]?.stringValue
    }
}

/// A conversation's branch on the Branches page.
struct BoardBranchRow: Identifiable, Equatable {
    let conversation: ConversationSummary
    let status: BranchStatus
    /// For a sub-chat in a checkout not its own: the conversation it is listed under.
    let sharing: ConversationSummary?
    var nested = false
    var id: Int { conversation.id }
}

/// One repository's rows on the Branches page.
struct BoardBranchGroup: Identifiable, Equatable {
    let repo: String
    let rows: [BoardBranchRow]
    var id: String { repo }
    var worktrees: Int { rows.filter(\.status.managed).count }
}

extension BranchStatus {
    /// Most pressing first, as the Mac's tracker orders its rows.
    static let boardOrder = ["conflict", "changes", "missing", "unavailable", "ahead", "behind", "detached", "merged", "clean"]

    /// The branch's name, or what HEAD is when it is on none.
    var boardName: String { branch ?? head.map { "detached at \($0)" } ?? "no branch" }

    /// The state in a word or two, for a tag (the Mac's `stateTitle`).
    var boardStateTitle: String {
        switch state {
        case "conflict": operation.map { "\($0) stopped" } ?? "conflicts"
        case "changes": "\(changes) changed"
        case "ahead": upstream == nil ? "\(unmerged ?? ahead) new" : "\(ahead) to push"
        case "behind": "\(behind) behind"
        default: state
        }
    }

    /// The checkout in a few words, after the branch's name (the Mac's `kindText`).
    func boardKind(shared: Bool) -> String {
        if managed { return "own worktree" }
        if shared { return worktree ? "parent’s worktree" : "parent’s checkout" }
        return worktree ? "worktree" : "main checkout"
    }

    /// One line per fact, as the Mac's details say them (`facts`).
    var boardFacts: [String] {
        var lines: [String] = []
        if state == "missing" { lines.append("The worktree’s folder is gone. Remove the worktree to let git forget it.") }
        if state == "unavailable" { return ["The checkout could not be read. Use Remove to retry an interrupted removal."] }
        if conflicts > 0 { lines.append("\(conflicts) file\(conflicts == 1 ? "" : "s") with unresolved conflicts") }
        if let operation, conflicts == 0 { lines.append("A \(operation) stopped half way") }
        if changes > 0 { lines.append("\(changes) uncommitted change\(changes == 1 ? "" : "s")") }
        if let upstream {
            switch (ahead, behind) {
            case (0, 0): lines.append("Up to date with \(upstream)")
            case (let a, 0): lines.append("\(a) commit\(a == 1 ? "" : "s") not pushed to \(upstream)")
            case (0, let b): lines.append("\(b) commit\(b == 1 ? "" : "s") behind \(upstream)")
            case (let a, let b): lines.append("\(a) ahead of \(upstream), \(b) behind")
            }
        } else if state != "missing", branch != nil {
            lines.append("Not pushed anywhere yet")
        }
        if state == "merged", let into = containedIn ?? base {
            lines.append("Everything on it is on \(into)")
        } else if branch == nil, let into = containedIn {
            lines.append("Its commit is on \(into), so removing it loses nothing")
        } else if let unmerged, let base, unmerged > 0 {
            if let into = containedIn {
                lines.append("Everything on it is on \(into)")
            } else if let defaultBranch, let unmergedDefault {
                lines.append("\(unmerged) commit\(unmerged == 1 ? "" : "s") not on \(base), \(unmergedDefault) not on \(defaultBranch) yet")
            } else {
                lines.append("\(unmerged) commit\(unmerged == 1 ? "" : "s") not on \(base) yet")
            }
        }
        return lines
    }
}
