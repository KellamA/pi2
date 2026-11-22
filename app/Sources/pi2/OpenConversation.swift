import SwiftUI

// One way to open any conversation where it lives (#644; docs/projects.md, 10.1). Every "Open" in the app — the
// palette, the Archive, the Branches tab, the menu bar item, Quick Ask, a background command's source, a local model,
// a need's card, Continue with an Agent, a sub-chat's card, a fork, ⌘N — comes through `AppModel.openConversation`, and
// a window with nothing chosen lands on the Dashboard, the one project's hub, or the page that makes the first.

/// Where a conversation shows.
enum ConversationPlace: Equatable {
    /// Its project's hub, in the panel for the conversation with the orchestrator: the orchestrator's present one.
    case hub(String)
    /// In place of its project's board (#473): every other conversation of a project the sidebar lists, an earlier one
    /// with the orchestrator, an agent's, a sub-chat or a fork among them, and an archived one, which reads there with
    /// its Restore bar in place of the message field.
    case board(String)
    /// Chat mode, which is outside projects.
    case chat
    /// The Archive's reader: a conversation of a deleted or an archived project, which the sidebar does not list, or of
    /// no project.
    case archive
}

extension AppModel {
    /// Opens a conversation where it lives. `parent`, when the caller knows it, is the conversation it was opened from,
    /// for a sub-chat that neither list names: one of an archived conversation.
    /// `beside` opens one of a project's conversations in a new pane of its hub beside the focused one, or beside
    /// `parent`'s (a sub-chat card's Beside); nil reads ⌥ (#657).
    func openConversation(_ id: Int, from parent: Int? = nil, beside: Bool? = nil) {
        // ⌥ is read as the person asks, not once the conversation has come.
        let beside = beside ?? NSEvent.modifierFlags.contains(.option)
        if knows(id) {
            go(to: id, from: parent, beside: beside)
            return
        }
        // A conversation just made (⌘N, Quick Ask, a fork, Continue with an Agent) can be answered for before the
        // library that lists it, with its project, reaches the app; a sub-chat of an archived conversation is in no list,
        // and is known once it has come.
        Task {
            for _ in 0..<40 where !knows(id) { try? await Task.sleep(for: .milliseconds(50)) }
            go(to: id, from: parent, beside: beside)
        }
    }

    /// Where a conversation shows.
    func place(of id: Int, from parent: Int? = nil) -> ConversationPlace {
        if engine.isChat(id) { return .chat }
        let listed = engine.conversations.first { $0.id == id }
        let archived = engine.archived.first { $0.id == id }
        if listed == nil, archived == nil, let up = engine.open[id]?.state?.agent.parent ?? parent, up != id {
            // A sub-chat of an archived conversation is in neither list: it shows where that conversation does, in place
            // of the board even if that is the orchestrator's.
            return switch place(of: up) {
            case .hub(let project), .board(let project): .board(project)
            case .chat, .archive: .archive
            }
        }
        guard let projectID = listed?.projectId ?? archived?.projectId, let project = engine.project(projectID), project.archivedAt == nil else {
            return .archive
        }
        // The orchestrator's present conversation shows in its panel, archived too, with Restore (docs/projects.md, 3.6).
        return project.conversation == id ? .hub(projectID) : .board(projectID)
    }

    private func knows(_ id: Int) -> Bool {
        engine.conversations.contains { $0.id == id } || engine.archived.contains { $0.id == id } || engine.open[id]?.state != nil
    }

    private func go(to id: Int, from parent: Int?, beside: Bool) {
        switch place(of: id, from: parent) {
        case .chat:
            showChat(id)
        case .hub(let project):
            // Its panel, which takes the keyboard; the panes beside it stay as they are (#657).
            selection = .project(project)
            if hubs.fold(project) == .conversationFolded { hubs.setFold(.both, for: project) }
            hubs.keyOrchestrator(project)
        case .board(let project):
            // The panel asks for it as it appears; a sub-chat of an archived conversation is known to be one only once it
            // has come, and the panel waits for that. It goes to the focused pane, or with ⌥ to a new one (#657).
            engine.openConversation(id)
            openAgent(id, in: project, beside: beside, from: parent)
        case .archive:
            engine.openConversation(id)
            selection = .archive
            archiveReading = id
        }
    }

    /// The conversation the Archive's reader shows, while the Archive is on screen.
    var archiveConversation: Int? {
        guard mode == .agents, selection == .archive, let id = archiveReading,
              engine.conversations.contains(where: { $0.id == id }) || isArchived(id) else { return nil }
        return id
    }

    /// The row the sidebar of projects marks while a conversation shows in place of a project's board: its own, or for
    /// one with no row, such as a finished sub-chat, the row of the conversation it belongs to, which is the way back to
    /// it. Nil when that is the orchestrator's, whose row is the project's.
    func sidebarRow(for conversation: Int, in project: String) -> Int? {
        let live = engine.projectStore.live(project)
        var id = conversation
        for _ in 0..<16 {
            if live.runs.contains(id) || live.others.contains(where: { $0.id == id }) { return id }
            guard let up = engine.conversations.first(where: { $0.id == id })?.parent ?? engine.open[id]?.state?.agent.parent else { return nil }
            id = up
        }
        return nil
    }

    /// Where the window goes with nothing chosen: the hub of the one project, the Dashboard for several, and with none,
    /// the page that makes the first.
    func landOnProjects() {
        let listed = engine.projectStore.listed
        if listed.count == 1 {
            showProject(listed[0].id)
        } else if listed.isEmpty {
            if selection != nil { selection = nil }
        } else {
            selection = .dashboard
        }
    }
}

/// With no project yet, what the window shows: the way to make the first.
struct NoProjectsPage: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            PiMark(size: 64)
            VStack(spacing: 6) {
                Text("Make your first project").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                Text("A project is a folder, an orchestrator that hands out its work, and the agents that do it. Choose the folder to begin.")
                    .foregroundStyle(Theme.tx2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("New Project…") { model.newProject() }
                .buttonStyle(.piPrimary)
                .disabled(model.engine.status != .connected)
            Text("⌘K finds anything")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tx3)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .navigationTitle("pi²")
    }
}

/// The Archive's reader: a conversation of a deleted or an archived project, or of no project, in
/// place of the Archive's list, as a project's hub shows an agent's conversation in place of its board (#473). An
/// archived one reads with its Restore bar in place of the message field.
struct ArchiveReader: View {
    let model: AppModel
    let conversation: Int
    private var engine: EngineClient { model.engine }

    var body: some View {
        let listed = engine.conversations.first { $0.id == conversation }
        let archived = engine.archived.first { $0.id == conversation }
        let agent = engine.agent(listed?.runsAs ?? listed?.agentId ?? archived?.agentId ?? engine.open[conversation]?.state?.agent.agentId)
        let projectID = listed?.projectId ?? archived?.projectId
        let project = projectID.flatMap { id in engine.projects.first { $0.id == id } }
        let title = engine.conversationTitle(conversation)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentAvatar(agent: agent, size: 14)
                Text(agent?.name ?? "Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(1)
                    .fixedSize()
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                    .layoutPriority(1)
                if let project {
                    Text(project.deletedAt != nil ? "· of \(project.name), deleted" : project.archivedAt != nil ? "· of \(project.name), archived" : "· of \(project.name)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tx3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Back to the Archive") { model.archiveReading = nil }
                    .buttonStyle(.piGhost)
                    .fixedSize()
                    .help("Show the Archive's list again")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            ChatView(engine: engine, id: conversation)
                .id(conversation)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.window)
        .navigationTitle(title)
        .navigationSubtitle("Archive")
    }
}
