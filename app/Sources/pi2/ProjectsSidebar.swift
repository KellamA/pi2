import BrowserKit
import SwiftUI

// The sidebar with the Projects preview on (#470; docs/design/projects.md, The sidebar): the Dashboard, the projects
// with their badges, the open project's orchestrator, the agents working now and its other conversations, then the
// templates and the Archive. Every part that changes while agents work is a view of its own reading an object of its
// own (`ProjectLive`, `RunLive`), so that a change to one agent draws its row again and nothing else (#446).

struct ProjectsSidebar: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }
    private var store: ProjectsStore { engine.projectStore }

    var body: some View {
        #if PI2_DEVELOPMENT
        let _ = PerfProbe.count("sidebar: projects list drawn")
        #endif
        // The arrow keys move the List's selection themselves, so a project chosen that way never reaches a row's button:
        // it has to come through `showProject` here as a click does, or a project whose agent's conversation was opened
        // earlier in this launch opens on that agent instead of its board (#553). An agent's row under it comes through
        // `openAgent`, as its click does; while one is shown in place of the board, the list's selection is that row, so
        // that the keys move on from it (#600).
        let listed = listSelection
        List(selection: Binding(
            get: { listed },
            set: { next in
                switch next {
                case .project(let id): model.showProject(id)
                case .projectAgent(let project, let conversation): model.openAgent(conversation, in: project)
                default: model.selection = next
                }
            }
        )) {
            DashboardRow(store: store)
                .tag(Selection.dashboard)

            Section {
                if store.listed.isEmpty && store.loaded {
                    Text("No projects yet. Make one from a folder with +.").font(.callout).foregroundStyle(Theme.tx3)
                }
                ForEach(store.listed) { project in
                    ProjectBlock(model: model, project: project, live: store.live(project.id), open: model.projectsSidebar.open == project.id)
                }
            } header: {
                HStack {
                    Text("Projects").sectionLabel()
                    Spacer()
                    Button("New Project…", systemImage: "plus") { model.newProject() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.tx3)
                        .disabled(engine.status != .connected)
                        .help("New project from a folder")
                }
            }

            Section {
                TemplateRows(model: model)
                // What runs on this Mac apart from the agents' runs, and where the money went (#655).
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(Theme.tx2).frame(width: 20)
                    Text("Activity").lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    ActivityRowBadge(engine: engine)
                }
                .tag(Selection.activity)
                .help("Background commands left running and models running on this Mac")
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar").foregroundStyle(Theme.tx2).frame(width: 20)
                    Text("Usage").lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    UsageRowBadge(engine: engine)
                }
                .tag(Selection.usage)
                .help("What was spent, by model, agent, project and day, and the daily budget")
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").foregroundStyle(Theme.tx2).frame(width: 20)
                    Text("Archive")
                    Spacer(minLength: 4)
                    ArchiveCount(engine: engine)
                }
                .tag(Selection.archive)
            } header: {
                Text("Shared").sectionLabel()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.side)
        .safeAreaInset(edge: .top, spacing: 0) {
            Button { model.showingPalette = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text("Search or run a command")
                    Spacer(minLength: 4)
                    Text("⌘K").font(.system(size: 11))
                }
                .lineLimit(1)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx3)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.window.opacity(0.6), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Search projects and conversations, and run commands (⌘K)")
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
            .background(Theme.side)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(engine: engine) }
        .toolbar {
            ToolbarItem {
                Button("New Project…", systemImage: "folder.badge.plus") { model.newProject() }
                    .disabled(engine.status != .connected)
                    .help("New project from a folder")
            }
        }
        .alert("Rename project", isPresented: Binding(get: { model.projectsSidebar.renaming != nil }, set: { if !$0 { model.projectsSidebar.renaming = nil } })) {
            TextField("Name", text: Binding(get: { model.projectsSidebar.newName }, set: { model.projectsSidebar.newName = $0 }))
            Button("Rename") { model.finishRename() }
            Button("Cancel", role: .cancel) { model.projectsSidebar.renaming = nil }
        }
    }
}

extension ProjectsSidebar {
    /// What the list marks as chosen: the window's selection, or, while an agent's conversation is shown in place of the
    /// project's board, that agent's row, when the sidebar lists one for it, or else the row of the conversation it
    /// belongs to, such as a finished sub-chat's parent (#644).
    fileprivate var listSelection: Selection? {
        guard case .project(let id) = model.selection, let agent = model.hubs.agent(id),
              let row = model.sidebarRow(for: agent, in: id) else { return model.selection }
        return .projectAgent(project: id, conversation: row)
    }
}

/// The Dashboard's row, with how many things wait for the person in every project.
private struct DashboardRow: View {
    let store: ProjectsStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2").foregroundStyle(Theme.tx2).frame(width: 20)
            Text("Dashboard").lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            if store.needsCount > 0 {
                // In a narrow sidebar the words give way to the count, and the row's name keeps its room.
                ViewThatFits(in: .horizontal) {
                    Tag("\(store.needsCount) need you", .warn).fixedSize()
                    Tag("\(store.needsCount)", .warn).fixedSize()
                }
                .help(store.needsCount == 1 ? "1 thing waits for you" : "\(store.needsCount) things wait for you")
                .accessibilityLabel("\(store.needsCount) waiting on you")
            }
        }
    }
}

/// "over budget" on Usage's row, as the old sidebar's row says it.
private struct UsageRowBadge: View {
    let engine: EngineClient

    var body: some View {
        if engine.usage?.overBudget == true {
            Tag("over budget", .bad).fixedSize()
        }
    }
}

private struct ArchiveCount: View {
    let engine: EngineClient

    var body: some View {
        let count = engine.archived.count + engine.projectStore.archivedProjects.count
        if count > 0 {
            Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(Theme.tx3)
                .accessibilityLabel("\(count) archived")
        }
    }
}

/// A project's row, and when it is the open one, what is listed under it.
private struct ProjectBlock: View {
    let model: AppModel
    let project: ProjectInfo
    let live: ProjectLive
    let open: Bool
    private var engine: EngineClient { model.engine }

    var body: some View {
        #if PI2_DEVELOPMENT
        let _ = PerfProbe.count("sidebar: project block drawn")
        #endif
        // A button, as every row of the sidebar that goes somewhere is: a List row's tap gesture never arrives.
        // Choosing the project itself is choosing its board, whatever agent's conversation took its place (#473). The
        // project's row is its orchestrator's too (#600): the hub opens on the conversation with it, and the row says
        // how the orchestrator is and offers what can be done to its conversation.
        Button { model.showProject(project.id) } label: {
            ProjectSidebarRow(engine: engine, project: project, live: live).contentShape(.rect)
        }
            .buttonStyle(.plain)
            .tag(Selection.project(project.id))
            .contextMenu(previewAs: project.name, project.id) {
                // The orchestrator's row had no menu of its own: what can be done to its conversation from here is stopping
                // it, offered while it runs, as Activity offers it for every run.
                if let conversation = project.conversation, live.orchestratorWorking {
                    Button("Stop the Orchestrator") { engine.perform("abort", ["id": conversation]) }
                    Divider()
                }
                Button("Rename…") { model.beginRename(project) }
                Button("Archive") { model.archiveProject(project.id) }
            }
        if open {
            // The rows below carry a tag of their own, so that the arrow keys go from the project to its first working
            // agent and on (#600). Choosing one opens its conversation in place of the board, and the window's selection
            // stays the project's; while it shows, the list marks its row (`listSelection`).
            let agent = model.hubs.agent(project.id).flatMap { model.sidebarRow(for: $0, in: project.id) }
            ForEach(live.runs, id: \.self) { id in
                if let run = engine.projectStore.run(id) {
                    RunRow(engine: engine, id: id, run: run) { model.openAgent(id, in: project.id) }
                        .padding(.leading, 14)
                        .tag(Selection.projectAgent(project: project.id, conversation: id))
                }
            }
            OtherConversations(model: model, project: project, live: live, agent: agent)
        }
    }
}

/// A project: its mark, its name, and its badge: what needs the person, else who is working, else idle.
private struct ProjectSidebarRow: View {
    let engine: EngineClient
    let project: ProjectInfo
    let live: ProjectLive

    var body: some View {
        #if PI2_DEVELOPMENT
        let _ = PerfProbe.count("sidebar: project row drawn")
        #endif
        HStack(spacing: 8) {
            // How the orchestrator is, in the mark's place, as an agent's row shows it in place of its avatar (#600).
            Group {
                if live.orchestratorAtLimit {
                    Image(systemName: "hourglass").foregroundStyle(Theme.warn)
                        .accessibilityLabel("The orchestrator waits for a limit")
                } else if live.orchestratorWaiting {
                    Circle().fill(Theme.warn).frame(width: 7, height: 7)
                        .accessibilityLabel("The orchestrator waits for you")
                } else if live.orchestratorWorking {
                    Spinner().accessibilityLabel("The orchestrator is working")
                } else {
                    ProjectMark(name: project.name, color: engine.agent(project.orchestratorId)?.color)
                }
            }
            .frame(width: 20, height: 20)
            Text(project.name).lineLimit(1).layoutPriority(1)
            if project.folderMissing == true {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.warn)
                    .help("This project’s folder has gone: \(project.folder.map(engine.folderName) ?? "")")
                    .accessibilityLabel("Folder missing")
            }
            Spacer(minLength: 4)
            if live.needs > 0 {
                Tag("\(live.needs)", .warn).fixedSize()
                    .help(live.needs == 1 ? "1 thing waits for you" : "\(live.needs) things wait for you")
                    .accessibilityLabel("\(live.needs) waiting on you")
            } else if live.working > 0 {
                Tag("\(live.working) working", .acc).fixedSize()
                    .accessibilityLabel("\(live.working) working")
            } else {
                Tag("idle").fixedSize()
            }
        }
        .help(help)
    }

    /// The folder, the orchestrator with its model, and how it is: what the row stands for (#600).
    private var help: String {
        let orchestrator = engine.agent(project.orchestratorId)
        let ref = orchestrator?.model ?? engine.defaultModel
        let model = ref.flatMap { ref in engine.allModels.first { $0.ref == ref }?.name ?? ref.modelId }
        let state = live.orchestratorAtLimit ? "It waits for a provider’s limit."
            : live.orchestratorWaiting ? "It waits for you."
            : live.orchestratorWorking ? "It is working."
            : nil
        return [
            project.folder.map(engine.folderName) ?? "No folder",
            "Orchestrator: \(orchestrator?.name ?? "none")\(model.map { " · \($0)" } ?? "")",
            state,
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

/// A project's mark: its first letter on its orchestrator's colour.
struct ProjectMark: View {
    let name: String
    let color: String?
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(AgentColor.color(color))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(nsColor: Theme.rgb(0x15161C)))
            }
            .accessibilityHidden(true)
    }
}

/// One agent working now in the open project.
private struct RunRow: View {
    let engine: EngineClient
    /// Its conversation.
    let id: Int
    let run: RunLive
    /// Opens its conversation in place of the board, in the project's hub (#473).
    let open: () -> Void

    var body: some View {
        #if PI2_DEVELOPMENT
        let _ = PerfProbe.count("sidebar: working agent row drawn")
        #endif
        let agent = engine.agent(run.agentId)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    if run.waiting {
                        Circle().fill(Theme.warn).frame(width: 7, height: 7).frame(width: 16)
                            .accessibilityLabel("Needs you")
                    } else if run.atLimit {
                        Image(systemName: "hourglass").foregroundStyle(Theme.warn).frame(width: 16)
                            .accessibilityLabel("Waiting for a limit")
                    } else {
                        Spinner().frame(width: 16)
                    }
                    // The title has the room: the agent's name gives way first (#598).
                    Text(run.title.isEmpty ? agent?.name ?? "New conversation" : run.title).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    if let agent, !run.title.isEmpty { AgentNameGivingWay(agent: agent) }
                }
                BranchLine(engine: engine, conversationID: id, working: true).padding(.leading, 24)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // One thing only, what the row does: the spinner, dot or hourglass in it already says how the agent is.
        .help("Open this agent’s conversation in place of the board")
    }
}

/// The agent's name beside a working agent's title, which gives way to it (#598): whole, then cut in the middle, then only
/// the agent's avatar, with the name in its help.
private struct AgentNameGivingWay: View {
    let agent: AgentProfile

    var body: some View {
        let name = Text(agent.name).font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1)
        ViewThatFits(in: .horizontal) {
            name.fixedSize()
            name.truncationMode(.middle).frame(maxWidth: 72, alignment: .trailing)
            AgentAvatar(agent: agent, size: 14)
        }
        .help(agent.name)
    }
}

/// A project's other conversations, folded under it until the person unfolds them.
private struct OtherConversations: View {
    let model: AppModel
    let project: ProjectInfo
    let live: ProjectLive
    /// The conversation in place of the board, whose row the list marks (#473, #600).
    let agent: Int?

    var body: some View {
        let others = live.others
        // Open while one of the group is the conversation in place of the board: an agent that stops working moves out of
        // the working rows and into this group, and its marked row would be hidden until the person unfolded it (#553).
        let shown = model.projectsSidebar.othersShown.contains(project.id)
            || agent.map { id in others.contains { $0.id == id } } ?? false
        if !others.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if shown { model.projectsSidebar.othersShown.remove(project.id) } else { model.projectsSidebar.othersShown.insert(project.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(shown ? 90 : 0))
                        .frame(width: 16)
                    Text(others.count == 1 ? "1 other conversation" : "\(others.count) other conversations")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .accessibilityLabel(shown ? "Hide \(others.count) other conversations" : "Show \(others.count) other conversations")
            if shown {
                ForEach(others) { conversation in
                    Button { model.openAgent(conversation.id, in: project.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 8) {
                                AgentAvatar(agent: model.engine.agent(conversation.agentId), size: 16)
                                Text(conversation.title.isEmpty ? "New conversation" : conversation.title)
                                    .lineLimit(1)
                                    .foregroundStyle(conversation.title.isEmpty ? Theme.tx2 : Theme.tx)
                                Spacer(minLength: 0)
                            }
                            BranchLine(engine: model.engine, conversationID: conversation.id).padding(.leading, 24)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                    .tag(Selection.projectAgent(project: project.id, conversation: conversation.id))
                    .help("Open its conversation in place of the board")
                    .draggable(ConversationDrag(id: conversation.id)) {
                        Label(conversation.title.isEmpty ? "New conversation" : conversation.title, systemImage: "bubble.left").padding(6)
                    }
                }
            }
        }
    }
}

/// The templates: the agents of no project, which projects' agents are made from (#475's Agents tab names them).
private struct TemplateRows: View {
    let model: AppModel

    var body: some View {
        let templates = model.engine.agents
        let shown = model.projectsSidebar.templatesShown
        Button {
            withAnimation(.snappy(duration: 0.2)) { model.projectsSidebar.templatesShown.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(Theme.tx2).frame(width: 20)
                Text("Templates").foregroundStyle(Theme.tx)
                Spacer(minLength: 4)
                Text("\(templates.count)").font(.caption).monospacedDigit().foregroundStyle(Theme.tx3)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tx3)
                    .rotationEffect(.degrees(shown ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Agents kept outside any project, to make a project’s agents from")
        .accessibilityLabel(shown ? "Hide agent templates" : "Show \(templates.count) agent templates")
        if shown {
            ForEach(templates) { agent in
                AgentRow(model: model, agent: agent)
                    .padding(.leading, 14)
                    .tag(Selection.agent(agent.id))
            }
            Button {
                model.newAgent()
            } label: {
                Label("New Template", systemImage: "plus").font(.system(size: 12)).foregroundStyle(Theme.tx3)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
        }
    }
}

/// Archived projects, at the top of the Archive while the preview is on, each with Restore.
struct ArchivedProjects: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        let projects = engine.projectStore.archivedProjects
        if engine.projectsPreview, !projects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Projects").font(.headline)
                ForEach(projects) { project in
                    HStack(spacing: 10) {
                        ProjectMark(name: project.name, color: engine.agent(project.orchestratorId)?.color, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).lineLimit(1)
                            Text("\(project.folder.map(engine.folderName) ?? "No folder") · archived \(ArchiveRow.ago(project.archivedAt ?? 0))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Restore") { model.restoreProject(project.id) }
                            .help("Put it back in the sidebar")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .panel()
                    .contextMenu(previewAs: project.name, project.id) {
                        Button("Restore") { model.restoreProject(project.id) }
                    }
                }
                Text("An archived project keeps its conversations, which stay in the list below as they were.").formFooter()
            }
        }
    }
}

@MainActor
enum ProjectActions {
    static func pickFolder() -> String? {
        FilePanels.open("project-folder", selecting: .folders) { panel in
            panel.prompt = "Make Project"
            panel.message = "Choose the folder the project works in. pi² makes the project and its orchestrator in one step."
        }?.first?.path
    }
}

// MARK: - Following the switch

extension View {
    /// Keeps the window's selection to what the sidebar on screen can show as the preview is switched, and in a
    /// development build opens the project `PI2_SHOW` names once the engine has listed it.
    func projectsPreviewFollowing(model: AppModel) -> some View {
        modifier(ProjectsPreviewFollowing(model: model))
    }
}

private struct ProjectsPreviewFollowing: ViewModifier {
    let model: AppModel
    #if PI2_DEVELOPMENT
    @State private var launchTaken = false
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: model.engine.projectsPreview) { _, on in
                if on {
                    // The old panes are not drawn with the preview on (#644): what the window landed on at launch, before
                    // the engine said, gives way to the Dashboard, and a conversation chosen opens where it lives.
                    if model.launchChose {
                        model.landOnProjects()
                    } else if case .conversation(let id) = model.selection {
                        model.openConversation(id)
                    } else if model.selection == nil || model.selection == .inbox || model.selection == .branches {
                        // Neither the Inbox nor the page of every conversation's branches is offered with projects (#655).
                        model.landOnProjects()
                    }
                    return
                }
                // The old sidebar has no Dashboard or project to select: show the orchestrator's conversation instead.
                let project = model.projectsSidebar.open.flatMap { model.engine.projectStore.project($0) }
                model.projectsSidebar.open = nil
                switch model.selection {
                case .dashboard: model.selection = nil
                case .project: model.selection = project?.conversation.map { .conversation($0) }
                default: break
                }
            }
            #if PI2_DEVELOPMENT
            // `PI2_SHOW=dashboard` selects the Dashboard's row once the engine has said the preview is on. A project named
            // there is opened by the test copy's hook as it comes (TestCopyControl.swift).
            .onChange(of: model.engine.projectsPreview, initial: true) { _, on in
                guard on, !launchTaken, ProjectCopyView.launch?.show == "dashboard" else { return }
                launchTaken = true
                model.selection = .dashboard
            }
            #endif
    }
}
