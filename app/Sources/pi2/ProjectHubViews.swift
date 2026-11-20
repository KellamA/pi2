
import SwiftUI
import WindowKit

/// A project's hub: its bar, then the conversation with the orchestrator and the board, each folding (#471).
struct ProjectHubView: View {
    let model: AppModel
    let projectID: String
    /// Whether the hub is too narrow for both panels, so the board is folded whatever the fold.
    @State private var narrow = false
    /// Whether the person is typing to the orchestrator while an agent's conversation holds the board's place: one of
    /// the two takes the keyboard and ⌘Return, and the agent's does until the person clicks in the orchestrator's
    /// field (#473).
    @State private var orchestratorTyping = false
    private var engine: EngineClient { model.engine }

    /// The conversation of one of the project's agents shown in place of the board, while it is still in the library
    /// (#473).
    private var agentConversation: Int? {
        guard let id = model.hubs.agent(projectID), engine.conversations.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        if let project = engine.project(projectID) {
            let fold = model.hubs.fold(projectID)
            let agent = agentConversation
            let shown = fold.shown(narrow: narrow, agent: agent != nil)
            let tab = model.hubs.tab(projectID)
            // Exactly one of the two conversations takes the keyboard: the agent's, which the person just opened,
            // unless they clicked in the orchestrator's field.
            let orchestratorActive = agent == nil || orchestratorTyping
            let agentActive = agent != nil && !orchestratorTyping
            VStack(spacing: 0) {
                HubBar(engine: engine, project: project)
                if shown != fold {
                    NarrowNote(agent: agent != nil) { model.hubs.setFold(.conversationFolded, for: projectID) }
                }
                HubPanels(fold: fold, narrow: $narrow, agent: agent != nil) {
                    HubConversationPanel(model: model, project: project, shown: shown, active: orchestratorActive) {
                        orchestratorTyping = true
                    }
                } board: {
                    if let agent {
                        HubAgentPanel(model: model, project: project, conversation: agent, shown: shown, active: agentActive) {
                            orchestratorTyping = false
                        }
                    } else {
                        HubBoard(model: model, project: project, tab: tab, shown: shown)
                    }
                } strip: {
                    HubStrip(engine: engine, hubs: model.hubs, project: project)
                }
            }
            .background(Theme.window)
            .navigationTitle(project.name)
            .navigationSubtitle("Project")
            // A project with no conversation yet gets one as its hub opens (docs/projects.md, 3.2).
            .task(id: project.conversation == nil) {
                if project.conversation == nil { model.hubs.startConversation(project, engine: engine) }
            }
            #if PI2_DEVELOPMENT
            .onChange(of: HubDrawn.Shown(project: project.id, tab: tab, fold: shown, narrow: narrow, conversation: shown == .conversationFolded ? nil : project.conversation, agent: shown == .boardFolded ? nil : agent), initial: true) { _, drawn in
                HubDrawn.current = drawn
            }
            // A conversation the person opens takes the keyboard, whichever one had it.
            .onChange(of: agent) { orchestratorTyping = false }
            // The hub of the next project can appear before this one goes.
            .onDisappear { if HubDrawn.current?.project == projectID { HubDrawn.current = nil } }
            #endif
        } else {
            ContentUnavailableView(
                "No Project Here",
                systemImage: "folder.badge.questionmark",
                description: Text(engine.projectsPreview ? "This project was deleted, or has not reached the app yet." : "Projects are a preview. Turn them on in Settings › General.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.window)
            .navigationTitle("pi²")
        }
    }
}

/// The line that says the board folded by itself, with the way to see it.
private struct NarrowNote: View {
    /// Whether an agent's conversation takes the board's place, so that it is that which folds the board, not the
    /// board's own side being chosen: the way back is in its own header then (#473).
    let agent: Bool
    let showBoard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.righthalf.inset.filled").foregroundStyle(Theme.tx3)
            Text(agent ? "The window is too narrow for both panels, so the agent’s conversation takes the width."
                       : "The window is too narrow for both panels, so the board is folded.")
                .foregroundStyle(Theme.tx2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !agent {
                Button("Show the Board", action: showBoard)
                    .buttonStyle(.piGhost)
                    .help("Fold the conversation instead, so the board takes the width (⌥⌘[)")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - The bar

/// The hub's bar: the project, its folder and branch, the orchestrator's model, and how much of the plan's week is used.
private struct HubBar: View {
    let engine: EngineClient
    let project: ProjectRow

    private var orchestrator: AgentProfile? { engine.agent(project.orchestratorId) }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.acc.opacity(0.85))
                .frame(width: 28, height: 28)
                .overlay {
                    Text(String(project.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.onAcc)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(1)
                place
            }
            .layoutPriority(1)
            OrchestratorModelMenu(engine: engine, agent: orchestrator)
                .fixedSize()
            Spacer(minLength: 8)
            WeekUsed(engine: engine, provider: orchestrator?.model?.provider)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// "~/Developer/site · main".
    private var place: some View {
        let branch = project.conversation.flatMap { engine.branches[$0]?.branch }
        let folder = project.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }
        return HStack(spacing: 4) {
            if let folder {
                Text(folder).lineLimit(1).truncationMode(.middle)
                    .help(project.folder ?? "")
                if project.folderMissing == true {
                    Text("· folder missing").foregroundStyle(Theme.warn)
                        .help("The project's folder is not there any more. Its agents work as a conversation whose folder has gone does.")
                } else if let branch {
                    Text("·")
                    Text(branch).lineLimit(1)
                }
            } else {
                Text("No folder")
                    .help("The project's agents work in pi²'s shared workspace folder.")
            }
        }
        .font(Theme.mono)
        .foregroundStyle(Theme.tx3)
    }
}

/// The orchestrator's model. Choosing another changes the orchestrator's agent, so every conversation with it uses the
/// new model from its next message. Shown in the hub's bar and on the board's Settings tab (#478).
struct OrchestratorModelMenu: View {
    let engine: EngineClient
    let agent: AgentProfile?

    /// Its own model, or the default for all agents when it has none.
    private var ref: ModelRef? { agent?.model ?? engine.defaultModel }
    private var current: ModelInfo? { ref.flatMap { ref in engine.allModels.first { $0.ref == ref } } }

    var body: some View {
        Menu {
            ModelChoices(engine: engine, selected: agent?.model) { model in choose(model) }
            Divider()
            SettingsLink { Text("Connect More Providers…") }
        } label: {
            Text("\(agent?.name ?? "Orchestrator") · \(current?.name ?? ref?.modelId ?? "No model")")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .disabled(agent == nil || engine.status != .connected)
        .help("The orchestrator's model. Changing it changes the orchestrator's agent, from its next message.")
    }

    private func choose(_ model: ModelInfo) {
        guard let agent else { return }
        // The engine keeps every setting it is not sent, and the agent's project.
        engine.perform("agents.save", ["agent": ["id": agent.id, "name": agent.name, "model": ["provider": model.provider, "modelId": model.id]]])
    }
}

/// How much of the week is used on the plan the orchestrator's model runs on, as the provider last said. Nothing for a
/// model on no plan, or a plan that reports no week.
private struct WeekUsed: View {
    let engine: EngineClient
    let provider: String?

    var body: some View {
        if let provider, let plan = PlanLimits(engine.extras["limits"])?.providers.first(where: { $0.id == provider }),
           let week = plan.windows?.first(where: { $0.label.hasPrefix("This week") }) {
            let used = min(max(week.usedPercent, 0), 100)
            HStack(spacing: 8) {
                Text("Week").foregroundStyle(Theme.tx3)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line2)
                    Capsule().fill(used >= 90 ? Theme.warn : Theme.acc).frame(width: 64 * used / 100)
                }
                .frame(width: 64, height: 5)
                Text("\(Int(used.rounded()))%").foregroundStyle(Theme.tx2).monospacedDigit()
            }
            .font(.system(size: 11.5))
            .help("\(plan.name)\(plan.plan.map { " \($0)" } ?? ""): \(Int(used.rounded()))% of this week used\(week.resetsAt.map { ", resets \(LimitsFormat.exact(LimitsFormat.date($0)))" } ?? "")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("This week, \(Int(used.rounded())) percent used")
        }
    }
}

// MARK: - The panels

/// A panel's header: what it is, and the buttons that fold it and show the other.
private struct PanelHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 4)
            trailing
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx3)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// The conversation with the orchestrator.
private struct HubConversationPanel: View {
    let model: AppModel
    let project: ProjectRow
    let shown: HubFold
    /// Whether this conversation takes the keyboard and ⌘Return, while an agent's conversation holds the other side
    /// (#473).
    let active: Bool
    /// Called when the person clicks in its message field while another conversation has the keyboard.
    let onFocus: () -> Void
    private var engine: EngineClient { model.engine }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                let orchestrator = engine.agent(project.orchestratorId)
                if project.conversation.map({ id in engine.conversations.first { $0.id == id }?.busy == true }) == true {
                    Spinner().frame(width: 14)
                } else {
                    AgentAvatar(agent: orchestrator, size: 14)
                }
                Text(orchestrator?.name ?? "Orchestrator")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(1)
            } trailing: {
                if shown == .boardFolded {
                    // Folded by a narrow window, the board can only show in place of the conversation.
                    let narrow = model.hubs.fold(project.id) == .both
                    Button("Show the Board", systemImage: "sidebar.right") { model.hubs.setFold(narrow ? .conversationFolded : .both, for: project.id) }
                        .help(narrow ? "Fold the conversation instead, so the board takes the width (⌥⌘[)" : "Show the board beside the conversation (⌥⌘])")
                } else {
                    Button("Fold the Conversation", systemImage: "sidebar.left") { model.hubs.setFold(.conversationFolded, for: project.id) }
                        .help("Fold the conversation, so the board takes the width (⌥⌘[)")
                }
            }
            Group {
                if let id = project.conversation {
                    ChatView(engine: engine, id: id, active: active, onFocus: onFocus)
                        .id(id)
                } else {
                    StartingConversation(hubs: model.hubs, engine: engine, project: project)
                }
            }
            .environment(\.inSplitPane, shown == .both)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// While the conversation with the orchestrator is being made, or why it could not be.
private struct StartingConversation: View {
    let hubs: ProjectHubs
    let engine: EngineClient
    let project: ProjectRow

    var body: some View {
        VStack(spacing: 10) {
            if let problem = hubs.startProblems[project.id] {
                Text("The conversation with the orchestrator could not be started.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.tx)
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { hubs.startConversation(project, engine: engine) }
                    .buttonStyle(.piSecondary)
                    .disabled(engine.status != .connected)
            } else if project.archivedAt != nil {
                Text("This project is archived, so nothing new starts in it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx2)
            } else {
                ProgressView().controlSize(.small)
                Text("Starting the conversation with the orchestrator…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The board: its tabs, which are the project's navigation, and what the tab shows.
private struct HubBoard: View {
    let model: AppModel
    let project: ProjectRow
    let tab: HubTab
    let shown: HubFold

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                if shown == .conversationFolded {
                    Button("Show the Conversation", systemImage: "sidebar.left") { model.hubs.setFold(.both, for: project.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tx3)
                        .help("Show the conversation with the orchestrator beside the board (⌥⌘[)")
                }
                BoardTabs(selected: tab) { model.hubs.setTab($0, for: project.id) }
            } trailing: {
                if shown != .conversationFolded {
                    Button("Fold the Board", systemImage: "sidebar.right") { model.hubs.setFold(.boardFolded, for: project.id) }
                        .help("Fold the board, so the conversation takes the width (⌥⌘])")
                }
            }
            switch tab {
            case .now: ProjectNowTab(model: model, project: project)
            case .work: ProjectWorkTab(model: model, project: project)
            case .agents: ProjectAgentsTab(model: model, project: project)
            case .rules: ProjectRulesTab(model: model, project: project)
            case .notes: ProjectNotesTab(model: model, project: project)
            case .branches: ProjectBranchesTab(model: model, project: project)
            case .settings: ProjectSettingsTab(model: model, project: project)
            }
        }
    }
}

/// The board's tabs, in a row that scrolls sideways when the panel is narrower than they are.
private struct BoardTabs: View {
    let selected: HubTab
    let choose: (HubTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(HubTab.allCases) { tab in
                    let on = tab == selected
                    Button { choose(tab) } label: {
                        Text(tab.title)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.tx : Theme.tx2)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(on ? Theme.card2 : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// What a tab will show, until it does.
private struct BoardTabEmpty: View {
    let tab: HubTab

    private var words: (icon: String, text: String) {
        switch tab {
        case .now: ("bolt.horizontal.circle", "What needs you, who is working now and what finished today.")
        case .work: ("checklist", "The project's list of work: kept by pi², or the issues and pull requests of its GitHub repository.")
        case .agents: ("person.2", "The project's agents, the orchestrator among them, and the templates to make more from.")
        case .rules: ("text.badge.checkmark", "The project's rules, given word for word to the orchestrator or to every agent at each turn, and what they cost.")
        case .notes: ("note.text", "What the project's agents keep for themselves about it, which a new orchestrator starts with.")
        case .branches: ("arrow.triangle.branch", "The branches and worktrees the project's conversations work on.")
        case .settings: ("gearshape", "What the orchestrator may do without asking, when reports wake it, and the project's limits.")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: words.icon)
                .font(.system(size: 22))
                .foregroundStyle(Theme.tx3)
            Text(tab.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.tx)
            Text(words.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Coming in a later step of the projects preview.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tx3)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One of the project's agents in place of the board (#473): its conversation, which the person can read and write to
/// as any other, under its avatar and name, the conversation's title and the way back to the board.
private struct HubAgentPanel: View {
    let model: AppModel
    let project: ProjectRow
    let conversation: Int
    let shown: HubFold
    /// Whether this conversation takes the keyboard and ⌘Return, while the orchestrator's also shows (#473).
    let active: Bool
    /// Called when the person clicks in its message field while the orchestrator's conversation has the keyboard.
    let onFocus: () -> Void
    private var engine: EngineClient { model.engine }
    private var summary: ConversationSummary? { engine.conversations.first { $0.id == conversation } }
    private var agent: AgentProfile? { engine.agent(summary?.agentId) }
    private var title: String { summary?.title ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 14, as the conversation panel's header beside it (PanelHeader).
                AgentAvatar(agent: agent, size: 14)
                Text(agent?.name ?? "Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tx)
                    .lineLimit(1)
                    .fixedSize()
                Text(title.isEmpty ? "New conversation" : title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title.isEmpty ? "This conversation has no title yet" : title)
                Spacer(minLength: 8)
                Button("Back to the Board") { model.hubs.setAgent(nil, for: project.id) }
                    .buttonStyle(.piGhost)
                    .help("Show the project's board again, keeping the conversation with the orchestrator")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            ChatView(engine: engine, id: conversation, active: active, onFocus: onFocus)
                .id(conversation)
                .environment(\.inSplitPane, shown == .both)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - The strip

/// Along the bottom of the board while the conversation is folded: the orchestrator's last words, and a field that
/// sends it a message.
private struct HubStrip: View {
    let engine: EngineClient
    let hubs: ProjectHubs
    let project: ProjectRow
    @State private var text = ""
    @FocusState private var focused: Bool

    private var busy: Bool { project.conversation.map { id in engine.conversations.first { $0.id == id }?.busy == true } ?? false }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && project.conversation != nil && engine.status == .connected && project.archivedAt == nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if busy { Spinner(size: 10) } else { Circle().fill(Theme.acc).frame(width: 7, height: 7) }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 6) {
                lastWords
                TextField(project.conversation == nil ? "Starting the conversation with the orchestrator…" : "Message the orchestrator…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(project.conversation == nil || project.archivedAt != nil)
            }
            Button("Send", action: send)
                .buttonStyle(.piPrimary)
                .disabled(!canSend)
                .help("Send to the orchestrator (Return)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel(radius: 12, border: focused ? Theme.acc.opacity(0.55) : Theme.line2)
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 6)
    }

    @ViewBuilder
    private var lastWords: some View {
        if let words = project.lastWords {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Rectangle().fill(Theme.acc).frame(width: 2, height: 13)
                    Text("“\(words.text)”")
                        .foregroundStyle(Theme.tx2)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    Text(LimitsFormat.ago(LimitsFormat.date(words.at), now: context.date))
                        .foregroundStyle(Theme.tx3)
                        .fixedSize()
                }
                .font(.system(size: 12))
            }
        } else {
            Text(busy ? "The orchestrator is answering." : "The orchestrator has not answered yet.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx3)
        }
    }

    private func send() {
        guard canSend, let id = project.conversation else { return }
        let message = text
        text = ""
        Task { await engine.submit(message, to: id, steer: busy) }
    }
}
