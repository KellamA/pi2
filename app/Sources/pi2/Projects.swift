import Foundation
import Observation

// Projects (epic #450, docs/projects.md): what the app reads of the engine's `projects` and `needs` events, and the state
// the sidebar and the hub share. The engine sends these events whether the preview is on or not; with it off the app shows
// nothing of them but the switch in Settings (10.2).

/// A project as the `projects` event sends it (docs/projects.md, 3.2 and 4.3): the parts the app reads. Fields the app
/// does not read, such as `lastWords`, are left out, so that a change to them changes nothing here.
struct ProjectInfo: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    /// The real path of its folder, or nil for a project with no folder.
    let folder: String?
    /// The project agent that is its orchestrator.
    let orchestratorId: String
    /// The orchestrator's conversation now; nil until one is made with `projects.startFresh` (9.6).
    let conversation: Int?
    let createdAt: Double
    let archivedAt: Double?
    let deletedAt: Double?
    /// Its folder has gone since it was set.
    let folderMissing: Bool?
}

/// What carrying over has left to do, as the `projects` event says (4.3).
struct CarryOverState: Codable, Equatable {
    struct Pending: Codable, Equatable {
        let copy: String
        let name: String
        let project: String
        let variables: [String]
        let error: String?
    }
    let ranAt: Double?
    let backup: String?
    let secretsPending: [Pending]
}

/// What carrying over would do, or did (docs/projects.md, 9.8).
struct CarryOverReport: Codable, Equatable {
    struct Project: Codable, Equatable, Identifiable {
        struct Orchestrator: Codable, Equatable {
            let conversation: Int?
            let title: String?
            let template: String?
        }
        struct Copy: Codable, Equatable, Identifiable {
            let template: String
            let name: String
            let existing: String?
            let allowEverything: Bool
            let variables: [String]
            let worktreeOff: Bool
            let folder: String?
            var id: String { template }
        }
        let key: String
        let name: String
        let existing: String?
        let adopted: Bool
        let archived: Bool
        let orchestrator: Orchestrator?
        let copies: [Copy]
        let conversations: Int
        let archivedConversations: Int
        let subChats: Int
        let notes: Int
        let notices: [String]
        var id: String { key }
    }
    struct LeftOut: Codable, Equatable {
        let chats: Int
        let deleted: Int
        let deletedProject: Int
        let notesLeft: Int
    }
    let plan: String?
    let projects: [Project]
    let leftOut: LeftOut
    let already: Int
    let ranAt: Double?
    let backup: String?
    let secretsPending: [CarryOverState.Pending]

    init(_ value: JSONValue) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

/// The `projects` event as the sidebar and Settings read it. The hub reads it as `ProjectsEvent` (ProjectHub.swift).
struct SidebarProjectsEvent: Decodable {
    let projects: [ProjectInfo]
    let carryOver: CarryOverState?
}

/// One thing waiting for the person, as much as the sidebar reads of it: whose project it is. The `needs` event
/// decodes as `NeedItemsEvent` (ProjectRulesTab.swift), which the Rules tab reads the proposed rules from.
struct NeedRef: Equatable {
    let id: String
    let projectId: String?
}

/// A conversation of a project that is not the orchestrator's, as the sidebar lists it under the project.
struct ProjectConversation: Equatable, Identifiable {
    let id: Int
    let title: String
    /// The agent it runs as.
    let agentId: String?
}

/// What the sidebar shows of one project that changes while agents work: its badge and what is listed under it. One
/// object for each project, set only when something in it changed, so that a change in one project draws that
/// project's rows again and no other (#446).
@MainActor
@Observable
final class ProjectLive {
    /// How many things wait for the person in this project.
    fileprivate(set) var needs = 0
    /// How many of its runs are working (not waiting for the person).
    fileprivate(set) var working = 0
    /// Whether the orchestrator's own conversation is running.
    fileprivate(set) var orchestratorWorking = false
    /// The conversations working or waiting now, but the orchestrator's, oldest run first.
    fileprivate(set) var runs: [Int] = []
    /// Its other conversations, newest first by when they were made, so that one being used does not reorder the list.
    fileprivate(set) var others: [ProjectConversation] = []
}

/// One run working in a project, as its row in the sidebar shows it. An object of its own, so that a change to one
/// agent's run draws its row again and nothing else.
@MainActor
@Observable
final class RunLive {
    fileprivate(set) var title = ""
    /// The agent it runs as.
    fileprivate(set) var agentId: String?
    /// Waiting for the person.
    fileprivate(set) var waiting = false
    /// Waiting for a provider's limit.
    fileprivate(set) var atLimit = false
    /// A sub-chat: the conversation that opened it.
    fileprivate(set) var parent: Int?
}

/// The projects, the preview switch and carrying over's state, from the engine's `projects`, `needs`, `activity` and
/// `library` events. Each property is set only when it changed.
@MainActor
@Observable
final class ProjectsStore {
    /// Whether the engine has sent the `projects` event since the app connected.
    private(set) var loaded = false
    /// The projects the sidebar lists: neither archived nor deleted, in the engine's order.
    private(set) var listed: [ProjectInfo] = []
    /// Archived projects, newest first, for the Archive.
    private(set) var archivedProjects: [ProjectInfo] = []
    /// Deleted projects, newest first, for the Archive: their conversations are shown there alone (docs/projects.md, 3.6).
    private(set) var deletedProjects: [ProjectInfo] = []
    private(set) var carryOver: CarryOverState?
    /// Everything that waits for the person, in every project and none: the Dashboard row's count.
    private(set) var needsCount = 0
    /// Every project not deleted, by id.
    private(set) var byID: [String: ProjectInfo] = [:]

    @ObservationIgnored private var lives: [String: ProjectLive] = [:]
    @ObservationIgnored private var runLives: [Int: RunLive] = [:]
    @ObservationIgnored private var needs: [NeedRef] = []
    @ObservationIgnored private var activity: [ActivityRun] = []
    @ObservationIgnored private var conversations: [ConversationSummary] = []

    func project(_ id: String) -> ProjectInfo? { byID[id] }

    /// What the sidebar shows of a project that changes while agents work.
    func live(_ id: String) -> ProjectLive {
        if let live = lives[id] { return live }
        let live = ProjectLive()
        lives[id] = live
        refresh(only: id)
        return live
    }

    /// A run working in a project, while it does.
    func run(_ conversation: Int) -> RunLive? { runLives[conversation] }

    // MARK: Taking events in

    func take(projects event: SidebarProjectsEvent) {
        if !loaded { loaded = true }
        let kept = event.projects.filter { $0.deletedAt == nil }
        let ids = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if byID != ids { byID = ids }
        let shown = kept.filter { $0.archivedAt == nil }
        if listed != shown { listed = shown }
        let archived = kept.filter { $0.archivedAt != nil }.sorted { ($0.archivedAt ?? 0) > ($1.archivedAt ?? 0) }
        if archivedProjects != archived { archivedProjects = archived }
        let deleted = event.projects.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) }
        if deletedProjects != deleted { deletedProjects = deleted }
        if carryOver != event.carryOver { carryOver = event.carryOver }
        refresh()
    }

    func take(needs items: [NeedRef]) {
        needs = items
        if needsCount != items.count { needsCount = items.count }
        refresh()
    }

    func take(activity runs: [ActivityRun]) {
        activity = runs
        refresh()
    }

    func take(conversations list: [ConversationSummary]) {
        conversations = list
        refresh()
    }

    /// Works out every project's rows again from what the engine last sent, and sets only what changed.
    private func refresh(only: String? = nil) {
        let projectRuns = activity.filter { $0.projectId != nil && $0.chat != true }
        // Runs: one object each, while they run.
        var seen = Set<Int>()
        for run in projectRuns {
            seen.insert(run.conversationId)
            let live = runLives[run.conversationId] ?? {
                let made = RunLive()
                runLives[run.conversationId] = made
                return made
            }()
            if live.title != run.title { live.title = run.title }
            let agent = run.runsAs ?? run.agentId
            if live.agentId != agent { live.agentId = agent }
            let waiting = run.status == "waiting"
            if live.waiting != waiting { live.waiting = waiting }
            let atLimit = run.limit != nil
            if live.atLimit != atLimit { live.atLimit = atLimit }
            if live.parent != run.parent { live.parent = run.parent }
        }
        for id in runLives.keys where !seen.contains(id) { runLives[id] = nil }

        for (id, live) in lives where only == nil || only == id {
            let project = byID[id]
            let mine = projectRuns.filter { $0.projectId == id }
            let needCount = needs.count(where: { $0.projectId == id })
            if live.needs != needCount { live.needs = needCount }
            let working = mine.count(where: { $0.status != "waiting" })
            if live.working != working { live.working = working }
            let orchestrator = project?.conversation
            let orchestratorWorking = orchestrator.map { conversation in mine.contains { $0.conversationId == conversation } } ?? false
            if live.orchestratorWorking != orchestratorWorking { live.orchestratorWorking = orchestratorWorking }
            let runs = mine.map(\.conversationId).filter { $0 != orchestrator }
            if live.runs != runs { live.runs = runs }
            let others = conversations
                .filter { $0.projectId == id && $0.parent == nil && $0.orchestrator == nil && !$0.isChat && $0.id != orchestrator }
                .sorted { ($0.createdAt ?? 0, $0.id) > ($1.createdAt ?? 0, $1.id) }
                .map { ProjectConversation(id: $0.id, title: $0.title, agentId: $0.runsAs ?? $0.agentId) }
            if live.others != others { live.others = others }
        }
    }
}

/// What the projects' sidebar keeps folded or unfolded while the app runs.
@MainActor
@Observable
final class ProjectsSidebarState {
    /// The project unfolded in the sidebar: the one whose hub, or one of whose conversations, was chosen last.
    var open: String?
    /// Projects whose other conversations are unfolded.
    var othersShown: Set<String> = []
    /// Whether the templates are listed.
    var templatesShown = false
    /// The project whose rename prompt is showing, and the name being typed.
    var renaming: ProjectInfo?
    var newName = ""
}

extension AppModel {
    /// Makes a project from a folder the person chooses, with its orchestrator and an empty conversation with it, and
    /// opens it.
    func newProject() {
        guard let folder = ProjectActions.pickFolder() else { return }
        Task {
            do {
                let result = try await engine.call("projects.create", ["folder": folder])
                if let id = result["id"]?.stringValue {
                    // The `projects` event that lists it may come after the answer.
                    for _ in 0..<20 where engine.project(id) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    showProject(id)
                }
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    func archiveProject(_ id: String) {
        Task {
            do {
                _ = try await engine.call("projects.archive", ["id": id])
                if projectsSidebar.open == id { projectsSidebar.open = nil }
                if selection == .project(id) { selection = nil }
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    func restoreProject(_ id: String) {
        engine.perform("projects.unarchive", ["id": id])
    }

    func beginRename(_ project: ProjectInfo) {
        projectsSidebar.newName = project.name
        projectsSidebar.renaming = project
    }

    func finishRename() {
        guard let project = projectsSidebar.renaming else { return }
        projectsSidebar.renaming = nil
        let name = projectsSidebar.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != project.name else { return }
        engine.perform("projects.rename", ["id": project.id, "name": name])
    }
}
