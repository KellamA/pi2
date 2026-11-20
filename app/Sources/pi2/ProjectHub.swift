
import SwiftUI
import WindowKit

// A project's hub (#471): what opens when a project is selected, with the preview on. The bar, the conversation with
// the orchestrator and the board side by side, each folding. docs/design/projects.md says what it is for, and
// docs/projects.md (10.1, 10.3) what it reads and keeps. The views are in ProjectHubViews.swift.

/// A project as the engine's `projects` event sends it (docs/projects.md, 3.2 and 4.3): what the app reads of it.
struct ProjectRow: Decodable, Equatable, Identifiable {
    struct Repository: Decodable, Equatable {
        let owner: String
        let name: String
    }

    struct LastWords: Decodable, Equatable {
        let text: String
        /// Milliseconds since 1970.
        let at: Double
    }

    /// The parts of the project's settings the hub reads (docs/projects.md, section 8); the Settings tab (#478) reads
    /// the rest.
    struct Settings: Decodable, Equatable {
        /// The person's switch: whether a report wakes the orchestrator rather than waiting to be read (8.2).
        let wakeOnReports: Bool?
    }

    /// About how many tokens the rules add to each request (docs/projects.md, 6.2): an orchestrator's, and every other
    /// agent's. Absent from an engine before #459 filled it.
    struct RuleTokens: Decodable, Equatable {
        let orchestrator: Int
        let agents: Int
    }

    let id: String
    let name: String
    /// The real path of its folder, or nil for a project with none.
    let folder: String?
    let repository: Repository?
    /// The project agent that is its orchestrator.
    let orchestratorId: String
    /// The orchestrator's conversation now: nil until it is first opened, for a project carried over (3.2).
    let conversation: Int?
    let archivedAt: Double?
    let deletedAt: Double?
    /// Its folder has gone since it was set.
    let folderMissing: Bool?
    let settings: Settings?
    /// The last line of the orchestrator's last finished answer, for the folded conversation's strip.
    let lastWords: LastWords?
    /// What the rules add to each request, for the Rules tab; nil when the engine sends none.
    let ruleTokens: RuleTokens?
}

struct ProjectsEvent: Decodable {
    let preview: Bool
    let projects: [ProjectRow]
}

/// The board's tabs, which are the project's navigation, in the order they show. The raw values are the ones
/// `PI2_SHOW=project:<name>#<tab>` and the app's preferences use.
enum HubTab: String, CaseIterable, Identifiable {
    case now, work, agents, rules, notes, branches, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Now"
        case .work: "Work"
        case .agents: "Agents"
        case .rules: "Rules"
        case .notes: "Notes"
        case .branches: "Branches"
        case .settings: "Settings"
        }
    }
}

/// How each project's hub was left: its fold and its board's tab, kept in the app's preferences by project id
/// (`project.<id>.fold`, `project.<id>.tab`; docs/projects.md, 10.1), the conversation an agent's row put in place of the
/// board, which lasts this launch, and the conversations being made for projects that have none yet. Which project shows
/// is the window's selection (`Selection.project`); `AppModel.showProject` sets them together, for the sidebar of projects
/// and for a test copy's `show`.
@MainActor
@Observable
final class ProjectHubs {
    /// Set this launch; before that, what the preferences say.
    private var folds: [String: HubFold] = [:]
    private var tabs: [String: HubTab] = [:]
    /// The conversation shown in place of each project's board, while the person reads or writes to one of its agents
    /// (#473). Kept for the launch only, as the design has it: a hub opens on its board.
    private var agents: [String: Int] = [:]
    /// Projects whose conversation with the orchestrator is being made (`projects.startFresh`), and why it could not be.
    private(set) var starting: Set<String> = []
    private(set) var startProblems: [String: String] = [:]

    private static func key(_ id: String, _ what: String) -> String { "project.\(id).\(what)" }

    func fold(_ id: String) -> HubFold {
        folds[id] ?? UserDefaults.standard.string(forKey: Self.key(id, "fold")).flatMap(HubFold.init(rawValue:)) ?? .both
    }

    func tab(_ id: String) -> HubTab {
        tabs[id] ?? UserDefaults.standard.string(forKey: Self.key(id, "tab")).flatMap(HubTab.init(rawValue:)) ?? .now
    }

    func setFold(_ fold: HubFold, for id: String) {
        guard folds[id] != fold else { return }
        folds[id] = fold
        UserDefaults.standard.set(fold.rawValue, forKey: Self.key(id, "fold"))
    }

    func setTab(_ tab: HubTab, for id: String) {
        guard tabs[id] != tab else { return }
        tabs[id] = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.key(id, "tab"))
    }

    /// Folds or shows the conversation, or the board, as its button and key do.
    func toggle(_ panel: HubFold, for id: String) {
        let current = fold(id)
        setFold(current == panel ? .both : panel, for: id)
    }

    /// The conversation shown in place of a project's board, if one is.
    func agent(_ id: String) -> Int? { agents[id] }

    /// Puts a conversation in place of the board, or, with nil, brings the board back.
    func setAgent(_ conversation: Int?, for id: String) {
        guard agents[id] != conversation else { return }
        agents[id] = conversation
    }

    /// Makes the conversation with the orchestrator of a project that has none yet: one carried over whose orchestrator
    /// has never been opened, or whose conversation was deleted (docs/projects.md, 3.2). Once at a time per project; the
    /// `projects` event then names it, and the hub shows it.
    func startConversation(_ project: ProjectRow, engine: EngineClient) {
        guard project.conversation == nil, project.archivedAt == nil, project.deletedAt == nil, !starting.contains(project.id) else { return }
        starting.insert(project.id)
        startProblems[project.id] = nil
        Task {
            do {
                _ = try await engine.call("projects.startFresh", ["id": project.id])
            } catch {
                startProblems[project.id] = error.localizedDescription
            }
            starting.remove(project.id)
        }
    }
}

extension EngineClient {
    /// A project the window can show: in the `projects` event, with the preview on, and not deleted.
    func project(_ id: String) -> ProjectRow? {
        guard projectsPreview else { return nil }
        return projects.first { $0.id == id && $0.deletedAt == nil }
    }
}

/// What the app has told the engine it shows of a project, through `projects.watch` (docs/projects.md, 4.2, 10.3): the
/// one place the board's tabs say so, the Now tab (#472) and the Work tab (#479) both. The engine keeps one watch for
/// each connection, so every send names the project the person is looking at and all of that project's tabs on screen.
/// A tab that comes can appear before the tab that goes disappears — switching tabs, switching projects, folding the
/// board and closing the window alike — so a going tab tells the engine what is left rather than emptying the watch, and
/// there is nothing for it to undo: whichever of the two arrives last, the engine is left watching the tabs that show.
@MainActor
final class ProjectTabWatch {
    static let shared = ProjectTabWatch()
    /// The tabs each project's board shows now, by project id, and the projects in the order they were last shown in.
    private var shown: [String: Set<HubTab>] = [:]
    private var order: [String] = []
    /// The last send, so that the calls reach the engine in the order they were made.
    private var sending: Task<Void, Never>?

    func shows(_ project: String, tab: HubTab, engine: EngineClient) {
        var tabs = shown[project] ?? []
        guard !tabs.contains(tab) else { return }
        tabs.insert(tab)
        shown[project] = tabs
        order.removeAll { $0 == project }
        order.append(project)
        send(engine)
    }

    func hides(_ project: String, tab: HubTab, engine: EngineClient) {
        guard var tabs = shown[project], tabs.contains(tab) else { return }
        tabs.remove(tab)
        shown[project] = tabs
        send(engine)
    }

    /// The newest project that still has a tab on screen, with every tab of it that does; the app shows none when there
    /// is no such project.
    private func send(_ engine: EngineClient) {
        let params: [String: Any]
        if let project = order.last(where: { !(shown[$0] ?? []).isEmpty }) {
            params = ["projectId": project, "tabs": (shown[project] ?? []).map(\.rawValue)]
        } else {
            params = ["projectId": NSNull(), "tabs": [String]()]
        }
        let before = sending
        sending = Task {
            _ = await before?.value
            _ = try? await engine.call("projects.watch", params)
        }
    }
}

extension AppModel {
    /// Shows a project's hub, on a tab of its board and with a fold when they are given, or as it was left. The one way
    /// in: the sidebar of projects (#470) and a test copy's `show` both come here. Choosing the project, or its
    /// orchestrator, goes back to the board, from whichever agent's conversation was in its place (#473).
    func showProject(_ id: String, tab: HubTab? = nil, fold: HubFold? = nil) {
        if let tab { hubs.setTab(tab, for: id) }
        if let fold { hubs.setFold(fold, for: id) }
        hubs.setAgent(nil, for: id)
        selection = .project(id)
    }

    /// Shows one of a project's agents in place of its board, with the conversation the person chose in the sidebar
    /// (#473). The board's side has to show for the conversation to be there, so a folded board is shown again.
    func openAgent(_ conversation: Int, in project: String) {
        selection = .project(project)
        if hubs.fold(project) == .boardFolded { hubs.setFold(.both, for: project) }
        hubs.setAgent(conversation, for: project)
    }

    /// The project whose hub the window shows, if it does.
    var shownProject: String? {
        guard mode == .agents, case .project(let id) = selection else { return nil }
        return id
    }

    /// The orchestrator's conversation, when the hub shows it in its panel: for the engine, which keeps a model on this
    /// Mac loaded while a conversation using it is on screen.
    var hubConversation: Int? {
        guard let id = shownProject, hubs.fold(id) != .conversationFolded else { return nil }
        return engine.project(id)?.conversation
    }

    /// The agent's conversation shown in place of the hub's board, when the board's side shows: told to the engine with
    /// the rest, for the same reason.
    var hubAgentConversation: Int? {
        guard let id = shownProject, hubs.fold(id) != .boardFolded else { return nil }
        return hubs.agent(id)
    }
}

/// The View menu's commands for the hub's two panels, with the preview on. A view of its own, so that what it reads
/// draws this menu again and not every scene (#436). ⌘[ and ⌘] are taken by the panes, so the keys have ⌥ as well.
struct HubCommands: View {
    let model: AppModel

    var body: some View {
        if model.engine.projectsPreview {
            let project = model.shownProject
            let fold = project.map { model.hubs.fold($0) }
            Divider()
            Button(fold == .conversationFolded ? "Show Conversation" : "Fold Conversation") {
                if let project { model.hubs.toggle(.conversationFolded, for: project) }
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(project == nil)
            Button(fold == .boardFolded ? "Show Board" : "Fold Board") {
                if let project { model.hubs.toggle(.boardFolded, for: project) }
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(project == nil)
        }
    }
}

#if PI2_DEVELOPMENT
/// What the hub last drew, for a test copy's `show`, which answers once the hub has drawn what it asked for.
@MainActor
enum HubDrawn {
    struct Shown: Equatable {
        let project: String
        let tab: HubTab
        /// The fold as drawn: the board folded by a narrow window shows as folded.
        let fold: HubFold
        let narrow: Bool
        /// The orchestrator's conversation in its panel, if the panel shows one.
        let conversation: Int?
        /// The agent's conversation in place of the board, if the board's side shows one (#473).
        let agent: Int?
    }

    static var current: Shown?
}

/// Which of a project's agents a test copy asked for, and the conversation to show in place of the board (#473).
enum AgentChoice: Equatable {
    case conversation(Int)
    case problem(String)
}

extension AppModel {
    /// The conversation of one of a project's agents, for a test copy's `project:<name>#agent:<name>`: the agent's
    /// working conversation, else the newest of its conversations in the project. A name it does not know, or an agent
    /// with no conversation yet, says so.
    func agentChoice(_ asked: String, of project: String) -> AgentChoice {
        let agents = engine.allAgents.filter { $0.projectId == project }
        guard let agent = agents.first(where: { $0.name.lowercased() == asked.lowercased() }) ?? agents.first(where: { $0.id == asked }) else {
            return .problem("no agent called \(asked) in the project")
        }
        let runs = engine.projectStore.live(project).runs.compactMap { id in engine.projectStore.run(id).map { (id, $0) } }
            .filter { $0.1.agentId == agent.id }
        if let working = runs.first(where: { !$0.1.waiting }) ?? runs.first { return .conversation(working.0) }
        if let other = engine.projectStore.live(project).others.first(where: { $0.agentId == agent.id }) {
            return .conversation(other.id)
        }
        return .problem("\(agent.name) has no conversation in the project")
    }
}
#endif
