
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
    /// The project's settings (docs/projects.md, section 8) as the event sends them. The Agents tab reads the switches
    /// of 8.1; the rest are the Settings tab's (#478).
    let settings: Settings?

    /// A project's settings, as far as the Agents tab reads them (docs/projects.md, section 8). The parts other tabs
    /// read (limits, `wakeOnReports`) are left out, so a change to them changes nothing here.
    struct Settings: Decodable, Equatable {
        let withoutAsking: [String: Bool]?
    }

    /// Whether the orchestrator may do what the switch of 8.1 named `name` governs without asking.
    func allows(_ name: String) -> Bool { settings?.withoutAsking?[name] ?? false }
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
/// (`project.<id>.fold`, `project.<id>.tab`; docs/projects.md, 10.1), and the conversations being made for projects that
/// have none yet. Which project shows is the window's selection (`Selection.project`); `AppModel.showProject` sets the
/// three together, for the sidebar of projects and for a test copy's `show`.
@MainActor
@Observable
final class ProjectHubs {
    /// Set this launch; before that, what the preferences say.
    private var folds: [String: HubFold] = [:]
    private var tabs: [String: HubTab] = [:]
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

extension AppModel {
    /// Shows a project's hub, on a tab of its board and with a fold when they are given, or as it was left. The one way
    /// in: the sidebar of projects (#470) and a test copy's `show` both come here.
    func showProject(_ id: String, tab: HubTab? = nil, fold: HubFold? = nil) {
        if let tab { hubs.setTab(tab, for: id) }
        if let fold { hubs.setFold(fold, for: id) }
        selection = .project(id)
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
    }

    static var current: Shown?
}
#endif
