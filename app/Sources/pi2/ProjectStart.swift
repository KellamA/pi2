import PiModels
import SwiftUI

// Starting a conversation with one of a project's agents, and changing who orchestrates it (#643; docs/projects.md,
// 3.5, 6.5 and 10.3). Every way in comes here: the Agents tab's rows, an agent's page, a working agent's row in the
// sidebar, ⌘N's picker, File › New Conversation With and the palette. A new conversation opens in place of the board,
// through `openConversation` (#644); one with the orchestrator is Start fresh, after its confirmation, since a project has
// one conversation with its orchestrator.

extension AppModel {
    /// Starts a conversation with one of a project's agents, in place of its board, or, for its orchestrator, asks to start
    /// fresh (the hub's confirmation, #632), showing the hub first if it is not on screen.
    func startWith(_ agent: AgentProfile, in project: ProjectRow) {
        guard agent.id == project.orchestratorId else {
            newConversation(agentId: agent.id)
            return
        }
        if shownProject != project.id { showProject(project.id) }
        hubs.freshAsked = project.id
    }

    /// Opens an agent's own page in its project's Agents tab, with the board showing.
    func showAgentPage(_ agentID: String, in project: String) {
        showProject(project, tab: .agents)
        if hubs.fold(project) == .boardFolded { hubs.setFold(.both, for: project) }
        hubs.setAgentPage(agentID, for: project)
    }

    /// Makes another agent of the project its orchestrator, with a fresh conversation, in one commit (6.5), once the person
    /// has confirmed it. The `projects` event then names the new conversation, and the hub shows it in its panel.
    func makeOrchestrator(_ agent: AgentProfile, of project: ProjectRow) {
        Task {
            do {
                _ = try await engine.call("projects.setOrchestrator", ["id": project.id, "agentId": agent.id])
                if hubs.fold(project.id) == .conversationFolded { hubs.setFold(.both, for: project.id) }
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    /// The agents a project's picker and menus offer: its orchestrator first, then the others not removed, in the order
    /// they were made, as the Agents tab lists them.
    func startableAgents(_ project: ProjectRow) -> [AgentProfile] {
        let others = engine.allAgents
            .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return (engine.agent(project.orchestratorId).map { [$0] } ?? []) + others
    }

    /// ⌘N: the picker of the shown project's agents, or with no project shown, of the projects first
    /// (the Dashboard, a shared page); with one project there is nothing to choose, and it goes straight to its agents.
    func askNewConversation() {
        let listed = engine.projectStore.listed
        startPicker = StartPickerAsk(project: shownProject ?? (listed.count == 1 ? listed[0].id : nil))
    }
}

/// What the confirmation for Make Orchestrator says: what changes, and what is kept (6.5). Modelled on Start fresh's.
enum MakeOrchestrator {
    static func title(_ agent: AgentProfile, project: ProjectRow) -> String {
        "Make \(agent.name) the orchestrator of \(project.name)?"
    }

    static func words(_ agent: AgentProfile, previous: AgentProfile?) -> String {
        let before = previous?.name ?? "the orchestrator"
        return "\(agent.name) takes over from \(before): it hands out the project’s work, with the orchestrator’s tools and what the orchestrator may do without asking, as set on this tab. A new conversation with \(agent.name) begins, started fresh with the project as it stands: who is working, what waits for you, the reports not yet read and the work. Work handed out and not yet reported goes on, and reports to the new one.\n\nThe present conversation with \(before) is kept and can be read, linked from the new one, but takes no more messages. \(before.prefix(1).uppercased() + before.dropFirst()) stays in the project as one of its agents."
    }
}

/// ⌘N's picker, asked for with a project or without (then the projects come first).
struct StartPickerAsk: Identifiable, Equatable {
    let id = UUID()
    let project: String?
}

/// ⌘N: a short list, keyboard first (type to filter, the arrows to move, Return to choose), of the
/// shown project's agents, or of the projects and then the chosen one's agents. The orchestrator's row is Start fresh,
/// with its confirmation; another agent's starts a conversation in place of the board.
struct NewConversationPicker: View {
    let model: AppModel
    /// The project whose agents are listed; nil while the projects are.
    @State private var project: String?
    /// Whether the projects were listed first, so the way back to them shows.
    private let projectFirst: Bool
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private var engine: EngineClient { model.engine }

    init(model: AppModel, ask: StartPickerAsk) {
        self.model = model
        _project = State(initialValue: ask.project)
        projectFirst = ask.project == nil
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let mark: AnyView
        /// Why it cannot be chosen now, shown in place of its detail.
        var refusal: String? = nil
        let choose: () -> Void
    }

    private var shown: ProjectRow? { project.flatMap(engine.project) }

    private var rows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = { (text: String) in needle.isEmpty || text.lowercased().contains(needle) }
        if let shown {
            return model.startableAgents(shown).filter { matches($0.name) }.map { agent in
                let orchestrator = agent.id == shown.orchestratorId
                let working = engine.activity.contains { $0.projectId == shown.id && $0.runsAs == agent.id }
                return Row(
                    id: agent.id,
                    title: agent.name,
                    detail: orchestrator ? "Orchestrator · Start Fresh…" : working ? "\(engine.shortModelName(agent.model)) · working" : engine.shortModelName(agent.model),
                    mark: AnyView(AgentAvatar(agent: agent, size: 18)),
                    refusal: orchestrator ? engine.freshRefusal(shown) : shown.archivedAt != nil ? "This project is archived. Restore it first." : nil
                ) {
                    dismiss()
                    // The orchestrator's confirmation is an alert of the hub's, which waits for this sheet to go first.
                    if orchestrator {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.startWith(agent, in: shown) }
                    } else {
                        model.startWith(agent, in: shown)
                    }
                }
            }
        }
        var rows = engine.projectStore.listed.filter { matches($0.name) }.map { listed in
            Row(id: listed.id, title: listed.name, detail: listed.folder.map(engine.folderName) ?? "No folder",
                mark: AnyView(ProjectMark(name: listed.name, color: engine.agent(listed.orchestratorId)?.color, size: 18))) {
                project = listed.id
                query = ""
                selected = 0
            }
        }
        if matches("new project") {
            rows.append(Row(id: "new-project", title: "New Project…", detail: "Choose its folder",
                            mark: AnyView(Image(systemName: "folder.badge.plus").foregroundStyle(Theme.tx2).frame(width: 18))) {
                dismiss()
                // The folder panel waits for the sheet to go first, as the palette's does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.newProject() }
            })
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if projectFirst, shown != nil {
                    Button { back() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.tx2)
                    .help("Back to the projects")
                    .accessibilityLabel("Back to the projects")
                }
                Text(shown.map { "New conversation in \($0.name)" } ?? "New conversation in which project?")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tx2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 12)
            TextField(shown == nil ? "Type a project’s name" : "Type an agent’s name", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { choose(rows, at: selected) }
                .onKeyPress(.downArrow) { selected = min(selected + 1, max(rows.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                .accessibilityIdentifier("new-conversation-field")
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text(shown == nil ? (engine.projectStore.listed.isEmpty ? "No projects yet" : "No project by that name") : "No agent by that name")
                            .foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button { choose(rows, at: index) } label: {
                            HStack(spacing: 10) {
                                row.mark
                                Text(row.title).lineLimit(1).foregroundStyle(row.refusal == nil ? Theme.tx : Theme.tx3)
                                Spacer(minLength: 8)
                                Text(row.refusal ?? row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(index == selected ? Color.piAccent.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(row.refusal ?? "")
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 460, height: 320)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func back() {
        project = nil
        query = ""
        selected = 0
    }

    private func choose(_ rows: [Row], at index: Int) {
        guard rows.indices.contains(index), rows[index].refusal == nil else { return }
        rows[index].choose()
    }
}

/// File › New Conversation With: the shown project's agents, the orchestrator's being Start fresh;
/// with no project shown, each project with its agents.
struct ProjectAgentChoices: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        if let id = model.shownProject, let project = engine.project(id) {
            agents(of: project)
        } else {
            ForEach(engine.projectStore.listed) { listed in
                if let project = engine.project(listed.id) {
                    Menu(project.name) { agents(of: project) }
                }
            }
        }
    }

    @ViewBuilder
    private func agents(of project: ProjectRow) -> some View {
        ForEach(model.startableAgents(project)) { agent in
            if agent.id == project.orchestratorId {
                Button("\(agent.name) (Start Fresh…)") { model.startWith(agent, in: project) }
                    .disabled(engine.freshRefusal(project) != nil)
            } else {
                Button(agent.name) { model.startWith(agent, in: project) }
                    .disabled(project.archivedAt != nil)
            }
        }
    }
}
