
import SwiftUI
import PaneKit
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
    /// The last line of the orchestrator's last finished answer, for the folded conversation's strip.
    let lastWords: LastWords?
    /// The project's settings (docs/projects.md, section 8) as the `projects` event sends them. The Agents tab reads
    /// the switches of 8.1; the Settings tab reads the rest: when reports wake the orchestrator, and the limits (#478).
    var settings: Settings? = nil

    /// A project's settings: the switches of 8.1, which the Agents tab reads, and the rest, which the Settings tab
    /// reads. A change to one part changes nothing in the tabs reading the other.
    struct Settings: Decodable, Equatable {
        /// What the orchestrator may do without asking, by switch name (8.1).
        let withoutAsking: [String: Bool]?
        /// The person's switch for reports waking the orchestrator.
        let wakeOnReports: Bool
        struct Limits: Decodable, Equatable {
            /// Percent of a plan window, 1 to 100, or nil for none.
            let planShare: Int?
            /// Dollars a day, or nil for none.
            let dailySpend: Double?
        }
        let limits: Limits
    }

    /// Whether the orchestrator may do what the switch of 8.1 named `name` governs without asking.
    func allows(_ name: String) -> Bool { settings?.withoutAsking?[name] ?? false }
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

/// How each project's hub was left: its fold, its board's tab and its panes (#657), kept in the app's preferences by
/// project id (`project.<id>.fold`, `project.<id>.tab`, `project.<id>.panes`; docs/projects.md, 10.1), and the
/// conversations being made for projects that have none yet. Which project shows is the window's selection
/// (`Selection.project`); `AppModel.showProject` sets them together, for the sidebar of projects and for a test copy's
/// `show`. What the panes are and how they change is `HubLayout` (PaneKit); what this keeps of them for the launch only,
/// and how the app's commands and the ways to open a conversation use them, is in HubPanes.swift.
@MainActor
@Observable
final class ProjectHubs {
    /// Set this launch; before that, what the preferences say.
    private var folds: [String: HubFold] = [:]
    private var tabs: [String: HubTab] = [:]
    /// Each project's panes, once changed this launch; before that, what the preferences say (`savedLayouts`).
    var layouts: [String: HubLayout] = [:]
    /// Each project's panes as the preferences had them, read once.
    @ObservationIgnored var savedLayouts: [String: HubLayout] = [:]
    /// Whether the conversation with the orchestrator has the keyboard, rather than the focused pane's (#473): the person
    /// clicked in its field, or moved to it with Next Pane. For the launch only.
    var orchestratorKeyed: [String: Bool] = [:]
    /// Goes up when the person moves to a pane, or to the orchestrator's conversation, with the keyboard, so its message
    /// field takes it.
    var keyboardRequests: [String: Int] = [:]
    /// The fold each hub was last drawn with: the one chosen, or with the window too narrow, the side that folded by
    /// itself. Next Pane goes only to what shows.
    var drawnFolds: [String: HubFold] = [:]
    /// Why the last split or opening beside could not be made, said in a line above the hub until the next one is.
    var refusals: [String: String] = [:]
    /// The room the hub's panes have, and where each pane is in it, as last laid out: for telling whether a split fits,
    /// and which pane a click landed in. Not observed: they change as the hub is laid out, and nothing on screen
    /// depends on them.
    @ObservationIgnored var rooms: [String: CGSize] = [:]
    @ObservationIgnored var frames: [UUID: CGRect] = [:]
    /// Projects whose conversation with the orchestrator is being made (`projects.startFresh`), and why it could not be.
    private(set) var starting: Set<String> = []
    private(set) var startProblems: [String: String] = [:]

    static func key(_ id: String, _ what: String) -> String { "project.\(id).\(what)" }

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
        // Another tab puts the Agents tab back on its list, as leaving it always has.
        if tab != .agents { setAgentPage(nil, for: id) }
        guard tabs[id] != tab else { return }
        if tab == .work { PerfProbe.workTab("asked") }
        tabs[id] = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.key(id, "tab"))
    }

    /// The sections of the Work tab's list the person folded or unfolded, by project and section (#599), kept with the
    /// hub's fold and tab (`project.<id>.workFolds`: a section's id and whether it is folded). A section the person never
    /// touched is as `WorkFolds.foldedAtFirst` says.
    private var workFolds: [String: [String: Bool]] = [:]

    private func workChoices(_ id: String) -> [String: Bool] {
        workFolds[id] ?? (UserDefaults.standard.dictionary(forKey: Self.key(id, "workFolds")) as? [String: Bool]) ?? [:]
    }

    func workFolded(_ id: String, section: String) -> Bool {
        workChoices(id)[section] ?? WorkFolds.foldedAtFirst.contains(section)
    }

    func setWorkFolded(_ folded: Bool, section: String, for id: String) {
        var choices = workChoices(id)
        guard choices[section] != folded else { return }
        choices[section] = folded
        workFolds[id] = choices
        UserDefaults.standard.set(choices, forKey: Self.key(id, "workFolds"))
    }

    /// Folds or shows the conversation, or the board, as its button and key do.
    func toggle(_ panel: HubFold, for id: String) {
        let current = fold(id)
        setFold(current == panel ? .both : panel, for: id)
    }

    /// The agent whose own page shows in each project's Agents tab in place of its list (#475), kept here rather than in
    /// the tab so that the palette, Duplicate and New Agent can open one there (#643). For the launch only.
    private var agentPages: [String: String] = [:]

    func agentPage(_ id: String) -> String? { agentPages[id] }

    func setAgentPage(_ agent: String?, for id: String) {
        guard agentPages[id] != agent else { return }
        agentPages[id] = agent
    }

    /// The conversation of the focused pane beside the orchestrator's, if it shows one: the one in place of the board,
    /// with a single pane (#473).
    func agent(_ id: String) -> Int? { layout(id).focusedConversation }

    /// The conversation of each project's hub that has the keyboard, as the hub last drew it: the focused pane's, unless
    /// the person clicked in the orchestrator's field, else the orchestrator's. The Conversation menu acts on
    /// it, as it acts on the focused pane in the old screens (#632).
    private(set) var keyboard: [String: Int] = [:]

    func setKeyboard(_ conversation: Int?, for id: String) {
        guard keyboard[id] != conversation else { return }
        keyboard[id] = conversation
    }

    /// The project whose Start fresh confirmation shows, asked for from the context meter or the Conversation menu (#632).
    var freshAsked: String?

    /// A fresh conversation with the orchestrator (docs/projects.md, 6.5), once the person has confirmed it. The
    /// `projects` event then names it, and the hub shows it; a refusal is said as any failed request is.
    func startFresh(_ project: ProjectRow, engine: EngineClient) {
        Task {
            do {
                _ = try await engine.call("projects.startFresh", ["id": project.id])
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    /// A pull request to open on a project's Work tab as it next shows, asked for from a Dashboard column (#618).
    @ObservationIgnored private var pullsToOpen: [String: Int] = [:]

    func openPull(_ number: Int, for id: String) { pullsToOpen[id] = number }

    /// The pull request asked for, once: the Work tab opens it as it appears.
    func takePull(for id: String) -> Int? { pullsToOpen.removeValue(forKey: id) }

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

    /// Why a conversation cannot be summarised or given a fresh context: an earlier conversation with a project's
    /// orchestrator takes no messages with the preview on (docs/projects.md, 3.5), and the current one has those.
    func earlierRefusal(_ id: Int) -> String? {
        guard projectsPreview, conversations.first(where: { $0.id == id })?.orchestrator == "earlier" else { return nil }
        return "This is an earlier conversation with the orchestrator. Write in the current one."
    }

    /// Why a conversation cannot be forked: one with a project's orchestrator, current or earlier, since a project has one
    /// conversation with its orchestrator, which Start fresh begins again (docs/projects.md, 6.5).
    func forkRefusal(_ id: Int) -> String? {
        guard projectsPreview, conversations.first(where: { $0.id == id })?.orchestrator != nil else { return nil }
        return "A project has one conversation with its orchestrator. To begin it again, use Start Fresh…"
    }

    /// Why Start fresh cannot be done for a project now, in the words the engine refuses it with (docs/projects.md, 6.5),
    /// so the control can say so before it is chosen; nil when it can. A project with no conversation yet gets one as its
    /// hub opens.
    func freshRefusal(_ project: ProjectRow) -> String? {
        if status != .connected { return "pi² is not connected to its engine." }
        if project.archivedAt != nil { return "This project is archived. Restore it first." }
        guard let id = project.conversation else { return "The conversation with the orchestrator is still being started." }
        if inbox.contains(where: { $0.conversationId == id }) { return "Answer what the orchestrator is waiting for first." }
        let state = open[id]?.state
        if state?.queued.contains(where: { $0.mode != "write" }) == true || outgoing[id]?.isEmpty == false {
            return "Send or take back your queued message first."
        }
        if state?.busy == true || conversations.first(where: { $0.id == id })?.busy == true {
            return "The orchestrator is answering. Let it finish, or stop it, first."
        }
        return nil
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
    /// in: the sidebar of projects (#470) and a test copy's `show` both come here. Choosing the project while its hub
    /// shows, or asking for a tab of its board, brings the board back into view (#473, #657): its pane, or in place of
    /// the focused pane's conversation. Coming to it from elsewhere shows its panes as they were left.
    func showProject(_ id: String, tab: HubTab? = nil, fold: HubFold? = nil) {
        if (tab ?? hubs.tab(id)) == .work { PerfProbe.workTab("asked") }
        if let tab { hubs.setTab(tab, for: id) }
        if let fold { hubs.setFold(fold, for: id) }
        if shownProject == id || tab != nil { hubs.update(id) { $0.showBoard() } }
        selection = .project(id)
    }

    /// Shows one of a project's conversations in its hub (#473, #657): in the pane that shows it, else in a new pane
    /// beside the focused one when `beside` (⌥ held, when not said), else in the focused pane, or the conversation pane
    /// focused last when the board has the focus. `parent`, for a sub-chat card's Beside, is the conversation whose pane
    /// the new one goes beside. The board's side has to show for the conversation to be there, so a folded board is
    /// shown again.
    func openAgent(_ conversation: Int, in project: String, beside: Bool? = nil, from parent: Int? = nil) {
        selection = .project(project)
        if hubs.fold(project) == .boardFolded { hubs.setFold(.both, for: project) }
        hubs.open(conversation, in: project, beside: beside ?? NSEvent.modifierFlags.contains(.option), from: parent)
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

    /// The conversations in the hub's panes, when the board's side shows: told to the engine with the rest, for the same
    /// reason.
    var hubPaneConversations: Set<Int> {
        guard let id = shownProject, hubs.fold(id) != .boardFolded else { return [] }
        return Set(hubs.layout(id).conversations)
    }

    /// The conversation the Conversation menu acts on (#632): with a hub shown, the one of its conversations that has the keyboard,
    /// the orchestrator's when the hub has not said (its conversation folded, say, which the strip still writes to); else
    /// the focused pane's, or chat mode's chat.
    var commandConversationID: Int? {
        if let id = shownProject {
            let orchestrator = engine.project(id)?.conversation
            guard let keyed = hubs.keyboard[id], keyed == orchestrator || hubs.layout(id).conversations.contains(keyed) else { return orchestrator }
            return keyed
        }
        return activeConversationID
    }

    /// The project whose orchestrator's current conversation the Conversation menu acts on, if it does: Start Fresh is
    /// then the project's own, and Fork does not apply (#632).
    var commandOrchestratorProject: ProjectRow? {
        guard let id = shownProject, let project = engine.project(id), let conversation = project.conversation,
              commandConversationID == conversation else { return nil }
        return project
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
        /// The focused pane's conversation, if the board's side shows one (#473).
        let agent: Int?
        /// Whether the board's side holds more than the board alone: a conversation, or several panes (#657).
        let panes: Bool
        /// Every conversation the panes show, when the board's side shows.
        let shown: [Int]
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
