import LoginItemKit
import SwiftUI
import WindowKit

/// What the main window is showing.
enum Selection: Hashable {
    case inbox
    case activity
    case usage
    case archive
    case branches
    case agent(String)
    case conversation(Int)
    /// A project's hub, by the project's id (ProjectHub.swift), with the projects preview on.
    case project(String)
    /// The Dashboard's row in the sidebar of projects, with the preview on (ProjectsSidebar.swift; drawn by #481).
    case dashboard
}

#if PI2_DEVELOPMENT
extension Selection {
    /// What a development build was asked to open on, in `PI2_SHOW`: "inbox", "activity", "usage", "archive", "branches", "agent:<id>", or
    /// a conversation's number or title, in the sidebar or the Archive (including archived sub-chats). For taking
    /// pictures of the app; see docs/development.md. "agent:<id>#<section>" opens the agent's page at one of its
    /// sections, which the page reads for itself (`AgentSection`). "settings" and what follows
    /// it is not about this window: it opens the Settings window (`SettingsLaunch`), and this one opens as usual; so does
    /// "output:<id>", which opens a background command's output window (`OutputLaunch`).
    init?(launch value: String?, conversations: [ConversationSummary], archived: [ArchivedConversation]) {
        guard let value, !value.isEmpty, !ProjectCopyView.reserves(value) else { return nil }
        switch value {
        case "inbox": self = .inbox
        case "activity": self = .activity
        case "usage": self = .usage
        case "archive": self = .archive
        case "branches": self = .branches
        default:
            if value.hasPrefix("agent:") {
                self = .agent(String(value.dropFirst("agent:".count).prefix { $0 != "#" }))
            } else if let found = conversations.first(where: { String($0.id) == value || $0.title == value }) {
                self = .conversation(found.id)
            } else if let found = archived.first(where: { String($0.id) == value || $0.title == value }) {
                self = .conversation(found.id)
            } else {
                return nil
            }
        }
    }
}

/// The background command whose output a development build was asked to open on, in `PI2_SHOW=output:<id>`, such as
/// `output:bg-1`. The main window opens as it would without `PI2_SHOW`. Taken once, so the window is not opened again.
@MainActor
enum OutputLaunch {
    static let asked: String? = {
        guard let value = ProcessInfo.processInfo.environment["PI2_SHOW"], value.hasPrefix("output:") else { return nil }
        let id = String(value.dropFirst("output:".count)).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }()
    private static var taken = false

    static func take() -> Bool {
        defer { taken = true }
        return asked != nil && !taken
    }
}
#endif

/// App-level UI state.
@MainActor
@Observable
final class AppModel {
    let engine = EngineClient()
    /// The panes the conversation area is split into.
    let workspace = Workspace()
    /// Chat mode's side of the window, and which side shows (ChatMode.swift).
    let chats = ChatModeState()
    /// How each project's hub was left (ProjectHub.swift).
    let hubs = ProjectHubs()
    var selection: Selection? {
        didSet {
            if chats.redirecting { return }
            // A chat chosen anywhere opens in chat mode; this side keeps what it had.
            if case .conversation(let id) = selection, engine.isChat(id) {
                chats.redirecting = true
                selection = oldValue
                chats.redirecting = false
                showChat(id)
                return
            }
            // Anything else chosen (from the menu bar, the palette, a notification) is shown in the agent view.
            if selection != nil, !chats.holdingMode { mode = .agents }
            // A conversation chosen anywhere goes to the pane that has it, or else the focused pane.
            if case .conversation(let id) = selection, selection != oldValue {
                workspace.show(id)
                // With the projects preview on, the sidebar unfolds the project the conversation belongs to.
                if engine.projectsPreview, let project = engine.conversations.first(where: { $0.id == id })?.projectId { projectsSidebar.open = project }
            }
            if case .project(let id) = selection { projectsSidebar.open = id }
        }
    }
    /// What the sidebar of projects keeps unfolded (ProjectsSidebar.swift).
    let projectsSidebar = ProjectsSidebarState()
    var showingPalette = false
    /// Conversations whose sub-chats are folded away in the sidebar.
    var collapsed: Set<Int> = []

    init() {
        #if PI2_DEVELOPMENT
        TestCopyPanels.install(engine: engine)
        #endif
        engine.onNavigate = { [weak self] id in self?.selection = .conversation(id) }
        engine.onOpenBeside = { [weak self] id, beside in self?.openBeside(id, beside: beside) }
    }

    /// The conversation whose rename prompt is showing.
    var renaming: ConversationSummary?
    var newTitle = ""
    /// The conversation whose delete confirmation is showing, from the sidebar or from the Archive.
    var deleting: PendingDelete?

    struct PendingDelete: Equatable {
        let id: Int
        let title: String
    }
    /// Brings back the main window after it was closed; set by the views that can open windows.
    var showMainWindow: () -> Void = {}

    /// Whether the detail shows agent conversations, including a split whose focused pane is empty.
    var showsWorkspace: Bool {
        guard mode == .agents else { return false }
        switch selection {
        case .conversation: return true
        case nil: return workspace.isSplit
        default: return false
        }
    }

    /// The conversations the window has on screen: those open in the agent view's panes and chat mode's chat, whichever
    /// side shows, since each keeps what it shows while the other is up. The engine is told (docs/local-models-running.md).
    var shownConversations: Set<Int> {
        workspace.shownConversations.union(chats.selection.map { [$0] } ?? [])
            .union(hubConversation.map { [$0] } ?? []).union(hubAgentConversation.map { [$0] } ?? [])
    }

    var selectedConversationID: Int? {
        if case .conversation(let id) = selection { return id }
        return nil
    }

    var selectedConversation: ConversationSummary? {
        engine.conversations.first { $0.id == selectedConversationID }
    }

    /// Starts a conversation with `agentId`, or with the agent used last when nil.
    func newConversation(agentId: String? = nil) {
        Task {
            if let id = await engine.createConversation(agentId: agentId) { selection = .conversation(id) }
        }
    }

    func newAgent() {
        Task {
            // A unique placeholder name; the editor opens so it can be changed straight away.
            var name = "New Agent"
            var n = 2
            while engine.agents.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                name = "New Agent \(n)"
                n += 1
            }
            do {
                let result = try await engine.call("agents.save", ["agent": ["name": name, "description": "", "access": "none"]])
                if let id = result["id"]?.stringValue { selection = .agent(id) }
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    /// The copy's settings open straight away, with a reminder about incoming handoffs.
    var duplicatedAgentID: String?

    func duplicateAgent(_ id: String) {
        Task {
            do {
                let result = try await engine.call("agents.duplicate", ["id": id])
                if let copyID = result["id"]?.stringValue {
                    duplicatedAgentID = copyID
                    selection = .agent(copyID)
                }
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    func beginRename(_ conversation: ConversationSummary) {
        newTitle = conversation.title
        renaming = conversation
    }

    func delete(_ conversation: ConversationSummary) {
        deleting = PendingDelete(id: conversation.id, title: conversation.title)
    }

    func delete(id: Int, title: String) {
        deleting = PendingDelete(id: id, title: title)
    }

    /// Deletes the conversation being asked about. With `removingWorktree`, its worktree goes too (its branch is kept);
    /// only offered when the worktree has nothing uncommitted. The conversation is deleted first, which stops its agent,
    /// since a worktree cannot be removed while its agent works.
    func confirmDelete(removingWorktree: Bool = false) {
        if let deleting {
            moveOnFromChat(deleting.id)
            if selectedConversationID == deleting.id { selection = nextAfter(deleting.id) }
            let id = deleting.id
            if removingWorktree {
                Task {
                    do {
                        _ = try await engine.call("conversation.delete", ["id": id])
                        _ = try await engine.call("worktree.remove", ["id": id, "force": false, "deleteBranch": false])
                    } catch {
                        engine.lastError = error.localizedDescription
                    }
                }
            } else {
                engine.perform("conversation.delete", ["id": id])
            }
        }
        deleting = nil
    }

    /// The worktree pi² made for a conversation, whether it is in the sidebar or the Archive.
    func ownWorktree(_ id: Int) -> BranchStatus? {
        if let status = engine.branches[id], status.managed { return status }
        return engine.leftBehind.first { $0.id == id }?.status
    }

    /// Puts a conversation in the Archive. The window moves on to the next conversation, as it would in a mail app.
    func archive(_ conversation: ConversationSummary) {
        moveOnFromChat(conversation.id)
        if selectedConversationID == conversation.id { selection = nextAfter(conversation.id) }
        engine.perform("conversation.archive", ["id": conversation.id])
    }

    /// What to show once `id` leaves the sidebar: the conversation below it, else the one above, else nothing.
    private func nextAfter(_ id: Int) -> Selection? {
        let roots = engine.rootConversations
        guard let index = roots.firstIndex(where: { $0.id == id }) else { return engine.archived.contains { $0.id == id } ? .archive : nil }
        let next = index + 1 < roots.count ? roots[index + 1] : index > 0 ? roots[index - 1] : nil
        return next.map { .conversation($0.id) }
    }

    /// Whether a conversation is one the app may show although the sidebar does not list it: an archived one, or a
    /// sub-chat of one.
    func isArchived(_ id: Int) -> Bool {
        engine.archived.contains { $0.id == id } || engine.open[id]?.state?.archived == true
    }
}


@main
struct Pi2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    #if PI2_DEVELOPMENT
    private static let watch = BodyWatch("The app's scene body (Pi2App.body)")
    #endif

    var body: some Scene {
        #if PI2_DEVELOPMENT
        Self.watch.watch(report: { [model] in model.engine.note($0) }) { scenes }
        #else
        scenes
        #endif
    }

    /// Every scene of the app. SwiftUI works this out again, and with it every scene and each window's settings, whenever
    /// something it read changes, so it reads nothing that changes while the app runs: no state of the model or the
    /// engine, only the model itself, passed on to the views that show it. What depends on the inbox, the agents or the
    /// mode is a view of its own, which SwiftUI draws again on its own (#436). A development build says in app.log if
    /// it reads something that changes (`BodyWatch`).
    @SceneBuilder private var scenes: some Scene {
        #if PI2_DEVELOPMENT
        let _ = PerfProbe.count("scene body worked out")
        #endif
        Window("pi²", id: "main") {
            RootView(model: model)
                // The window's smallest size is worked out without measuring what it shows (#400).
                .windowMinimum(width: 820, height: 480) { model.engine.note($0) }
                .tint(.piAccent)
                .launchWindow()
                .testCopyControl(model: model)
                .onAppear {
                    delegate.engine = model.engine
                    model.engine.start()
                    Updates.shared.start(engine: model.engine)
                    QuickAsk.shared.install(model: model)
                }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .newItem) {
                NewItemCommands(model: model)
                Button("New Agent") { model.newAgent() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Command Palette…") { model.showingPalette = true }
                    .keyboardShortcut("k")
                Button("Quick Ask (⌃⌥Space anywhere)") { QuickAsk.shared.show(model: model) }
            }
            CommandGroup(after: .sidebar) {
                ModeCommands(model: model)
                Divider()
                Button("Show Inbox") { model.selection = .inbox }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Show Activity") { model.selection = .activity }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Usage") { model.selection = .usage }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Show Archive") { model.selection = .archive }
                Divider()
                PaneCommands(model: model)
                HubCommands(model: model)
            }
            CommandMenu("Conversation") {
                ConversationCommands(model: model)
            }
            CommandMenu("Debug") {
                Button("Kill Engine (Simulate Crash)") { model.engine.killEngine() }
                    .keyboardShortcut("k", modifiers: [.command, .option, .shift])
            }
        }

        // pi²'s own browser: the pages agents are on, which the person can watch and use. Opened from the Window menu,
        // the sidebar or a conversation's toolbar, never at launch: the main window is what starts the engine.
        Window("Browser", id: "browser") {
            BrowserWindow(engine: model.engine)
                .windowMinimum(width: 620, height: 400) { model.engine.note($0) }
                .tint(.piAccent)
                .launchWindow()
        }
        .defaultSize(width: 1100, height: 780)
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // A background command's output, one window per command, opened from Activity, the conversation or the menu
        // bar. Never at launch, and not brought back after a restart: the command's output does not outlast the engine.
        WindowGroup("Background Command", id: BackgroundOutputScene.id, for: String.self) { $id in
            Group {
                if let id {
                    BackgroundOutputWindow(model: model, id: id)
                } else {
                    Text("No command was chosen.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .windowMinimum(width: 520, height: 320) { model.engine.note($0) }
            .tint(.piAccent)
            .launchWindow()
        }
        .defaultSize(width: 760, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarView(model: model)
                .watchWindowSize(name: "Menu Bar", threshold: SizeWatch.panelThreshold) { model.engine.note($0) }
                .tint(.piAccent)
        } label: {
            MenuBarLabel(engine: model.engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(engine: model.engine)
                .tint(.piAccent)
                .launchWindow()
        }
    }
}

/// The menu bar item: the icon, filled while something waits on the person, and the count of what waits beside it, so it
/// is visible without opening anything. A view of its own, so that the inbox changing draws this again and not every
/// scene (#436).
struct MenuBarLabel: View {
    let engine: EngineClient

    var body: some View {
        Image(systemName: engine.inbox.isEmpty ? "circle.hexagongrid" : "circle.hexagongrid.fill")
        if !engine.inbox.isEmpty { Text("\(engine.inbox.count)") }
    }
}

/// The File menu's ways to start something new that depend on what changes while the app runs: ⌘N, which starts
/// whatever the window is showing (a chat in chat mode), and a conversation with each agent. A view of its own, so that
/// the mode or the agents changing draws the menu again and not every scene (#436).
struct NewItemCommands: View {
    let model: AppModel

    var body: some View {
        if model.mode == .chat {
            Button("New Chat") { model.newChat() }
                .keyboardShortcut("n")
        } else {
            Button("New Conversation") { model.newConversation() }
                .keyboardShortcut("n")
        }
        Menu("New Conversation With") {
            ForEach(model.engine.agents) { agent in
                Button(agent.name) { model.newConversation(agentId: agent.id) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var engine: EngineClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.apply()
        NSApp.activate()
    }

    /// Closing the window leaves pi² in the menu bar, so agents keep working and can still reach the person.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting stops the engine cleanly unless the person asked for agents to keep running.
        MainActor.assumeIsolated {
            let loginItem = engine.map { EngineLoginItem.current?.serves(home: $0.dataFolder.path) == true } ?? false
            let keep = UserDefaults.standard.bool(forKey: BackgroundSettings.keepEngineKey) || loginItem
            if !keep { engine?.stopEngine() }
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        NavigationSplitView {
            Group {
                if model.mode == .chat {
                    ChatSidebar(model: model)
                } else if engine.projectsPreview {
                    ProjectsSidebar(model: model)
                } else {
                    SidebarView(model: model)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ModeSwitch(model: model) }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            // One branch for every way the conversation area shows, so moving between panes, or to an empty one, keeps
            // the panes' pages loaded.
            Group {
                if model.mode == .chat {
                    ChatModeDetail(model: model)
                } else if model.showsWorkspace {
                    WorkspaceView(model: model)
                } else {
                    switch model.selection {
                    case .inbox:
                        InboxView(model: model)
                    case .activity:
                        ActivityView(model: model)
                    case .usage:
                        UsageView(model: model)
                    case .archive:
                        ArchiveView(model: model)
                    case .branches:
                        BranchesView(model: model)
                    case .agent(let id):
                        AgentEditor(model: model, agentID: id)
                            .id(id)
                    case .project(let id):
                        ProjectHubView(model: model, projectID: id)
                            .id(id)
                    case .dashboard:
                        DashboardPlaceholder(model: model)
                    case .conversation, nil:
                        WelcomeView(model: model)
                    }
                }
            }
            // The page loaded ahead for the next conversation waits here, in the window but unseen, whatever shows, so
            // that WebKit has it ready to draw (#441).
            .background { SparePageSpot() }
            // An engine that keeps failing to start is said so above whatever is showing, until one starts.
            .safeAreaInset(edge: .top, spacing: 0) { EngineTroubleBanner(engine: engine) }
            // Requests stacked above the message field cannot make the split view taller than the window (#400).
            .columnGivesWay()
        }
        .background(WindowOpener(model: model))
        .projectsPreviewFollowing(model: model)
        .worktreeDialogs(engine: engine)
        .sheet(isPresented: $model.showingPalette) { PaletteView(model: model) }
        .sheet(isPresented: Binding(get: { engine.onboarded == false }, set: { _ in })) {
            OnboardingView(model: model)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.selection) { _, selection in
            if case .conversation(let id) = selection {
                engine.openConversation(id)
                // Showing a sub-chat unfolds its parent, so the selection is visible in the sidebar.
                if let parent = engine.conversations.first(where: { $0.id == id })?.parent { model.collapsed.remove(parent) }
            }
        }
        // Which conversations are on screen, for the engine: it keeps a model on this Mac loaded while one using it is.
        .onChange(of: model.shownConversations, initial: true) { _, shown in engine.setShown(shown) }
        .onChange(of: engine.hasLoadedLibrary) { _, loaded in
            guard loaded else { return }
            // Panes kept from last time that show conversations since deleted are emptied.
            model.workspace.forget { id in !engine.conversations.contains { $0.id == id } && !model.isArchived(id) }
            guard model.selection == nil else { return }
            #if PI2_DEVELOPMENT
            if ChatLaunch.apply(ProcessInfo.processInfo.environment["PI2_SHOW"], to: model) { return }
            if let asked = Selection(launch: ProcessInfo.processInfo.environment["PI2_SHOW"], conversations: engine.conversations, archived: engine.archived) {
                model.selection = asked
                return
            }
            #endif
            // Split into panes last time: come back to the same panes. The window stays on the side it was last on.
            if model.workspace.isSplit {
                model.restoreSelection(model.workspace.focusedConversation.map { .conversation($0) })
                return
            }
            // On launch, land on the most recent conversation.
            if let first = engine.rootConversations.first { model.restoreSelection(.conversation(first.id)) }
        }
        .onChange(of: engine.conversations) { _, list in
            // Panes showing a deleted conversation are emptied; the focused one moves on below.
            if engine.hasLoadedLibrary {
                model.workspace.forget { id in id != model.selectedConversationID && !list.contains { $0.id == id } && !model.isArchived(id) }
            }
            // The conversation on screen was deleted: move to the next one. An archived one may stay on screen: it can
            // still be read.
            if let id = model.selectedConversationID, engine.hasLoadedLibrary, !list.contains(where: { $0.id == id }), !model.isArchived(id) {
                model.restoreSelection(engine.rootConversations.first.map { .conversation($0.id) })
            }
            #if PI2_DEVELOPMENT
            // A conversation `PI2_SHOW` names that is made after launch, through the engine's socket, opens when it comes,
            // as long as nothing else has been chosen.
            if model.selection == nil, engine.hasLoadedLibrary,
               let asked = Selection(launch: ProcessInfo.processInfo.environment["PI2_SHOW"], conversations: list, archived: engine.archived) {
                model.selection = asked
            }
            #endif
        }
        .alert(engine.isChat(model.renaming?.id ?? 0) ? "Rename chat" : "Rename conversation", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Title", text: $model.newTitle)
            Button("Rename") {
                if let renaming = model.renaming { engine.perform("conversation.rename", ["id": renaming.id, "title": model.newTitle]) }
                model.renaming = nil
            }
            Button("Cancel", role: .cancel) { model.renaming = nil }
        }
        .confirmationDialog(
            "Delete “\(model.deleting.map { $0.title.isEmpty ? (engine.isChat($0.id) ? "New chat" : "New conversation") : $0.title } ?? "")”?",
            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })
        ) {
            let worktree = model.deleting.flatMap { model.ownWorktree($0.id) }
            if let worktree, !worktree.isDirty {
                Button("Delete and Remove Worktree", role: .destructive) { model.confirmDelete(removingWorktree: true) }
                Button("Delete, Keep Worktree") { model.confirmDelete() }
            } else {
                Button("Delete", role: .destructive) { model.confirmDelete() }
            }
            Button("Cancel", role: .cancel) { model.deleting = nil }
        } message: {
            let worktree = model.deleting.flatMap { model.ownWorktree($0.id) }
            let base = "Any work it is doing is stopped, and pi² will not show it again or bring it back. Its text stays in pi²’s data on this Mac. To put it away but keep it, archive it instead."
            if let deleting = model.deleting, engine.isChat(deleting.id) {
                Text("pi² will not show this chat again or bring it back. Its text stays in pi²’s data on this Mac. To put it away but keep it, archive it instead.")
            } else if let worktree {
                let branch = worktree.branch.map { "Its branch \($0)" } ?? "Its commits"
                Text(worktree.isDirty
                    ? "\(base)\n\nIts worktree of \(worktree.repo) has uncommitted changes, so it is kept. Branches lists it under Left Behind, where it can be removed later."
                    : "\(base)\n\nIts worktree of \(worktree.repo) can be removed with it. \(branch) stay\(worktree.branch == nil ? "" : "s") in the repository either way.")
            } else {
                Text(base)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { engine.lastError != nil }, set: { if !$0 { engine.lastError = nil } })) {
            Button("OK") { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        List(selection: $model.selection) {
            InboxRow(engine: engine)
                .tag(Selection.inbox)
            navRow("Activity", icon: "waveform.path.ecg", tag: .activity) {
                ActivityBadges(engine: engine)
            }
            navRow("Usage", icon: "chart.bar", tag: .usage) {
                if engine.usage?.overBudget == true {
                    Tag("over budget", .bad)
                }
            }
            navRow("Archive", icon: "archivebox", tag: .archive) {
                if !engine.archived.isEmpty {
                    Text("\(engine.archived.count)").font(.caption).monospacedDigit().foregroundStyle(Theme.tx3)
                        .accessibilityLabel("\(engine.archived.count) archived")
                }
            }

            if !engine.branches.isEmpty || !engine.leftBehind.isEmpty || model.selection == .branches {
                navRow("Branches", icon: "arrow.triangle.branch", tag: .branches) {
                    let worktrees = engine.branches.values.filter(\.managed).count
                    if engine.branches.values.contains(where: { $0.state == "conflict" }) {
                        Tag("conflict", .bad)
                    } else if worktrees > 0 {
                        Text("\(worktrees)").font(.caption).monospacedDigit().foregroundStyle(Theme.tx3)
                            .help("\(worktrees) conversation\(worktrees == 1 ? "" : "s") in a worktree of its own")
                            .accessibilityLabel("\(worktrees) worktrees")
                    }
                }
            }

            Section {
                ForEach(engine.agents) { agent in
                    AgentRow(model: model, agent: agent)
                        .tag(Selection.agent(agent.id))
                }
            } header: {
                HStack {
                    Text("Agents").sectionLabel()
                    Spacer()
                    Button("New Agent", systemImage: "plus") { model.newAgent() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.tx3)
                        .help("New agent (⇧⌘N)")
                }
            }

            Section {
                if engine.rootConversations.isEmpty && engine.hasLoadedLibrary {
                    Text("No conversations yet").font(.callout).foregroundStyle(Theme.tx3)
                }
                ForEach(engine.rootConversations) { conversation in
                    let subChats = engine.subChats(of: conversation.id)
                    conversationRow(conversation, subChats: subChats.count)
                    // An agent's sub-chats sit under the conversation that opened them, like files in a folder.
                    if !model.collapsed.contains(conversation.id) {
                        ForEach(subChats) { subChat in
                            conversationRow(subChat, subChats: 0)
                                .padding(.leading, 16)
                        }
                    }
                }
            } header: {
                Text("Conversations").sectionLabel()
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx3)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.window.opacity(0.6), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Search conversations and run commands (⌘K)")
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
            .background(Theme.side)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(engine: engine) }
        .toolbar {
            ToolbarItem {
                Button("New Conversation", systemImage: "square.and.pencil") { model.newConversation() }
                    .disabled(engine.status != .connected)
                    .help("New conversation (⌘N)")
            }
        }
    }

    private func navRow<Trailing: View>(_ title: String, icon: String, tag: Selection, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.tx2).frame(width: 20)
            Text(title)
            Spacer(minLength: 4)
            trailing()
        }
        .tag(tag)
    }
    private func conversationRow(_ conversation: ConversationSummary, subChats: Int) -> some View {
        let wait = engine.limitWaits[conversation.id]
        return HStack(spacing: 8) {
            if let wait {
                // Waiting for a provider's limit is not working: no spinner (#343).
                Image(systemName: "hourglass").foregroundStyle(Theme.warn).frame(width: 16)
                    .help(wait.sentence)
                    .accessibilityLabel(wait.tag)
            } else if engine.heldByLimits.contains(conversation.id) {
                // Nothing of it works: all its sub-chats wait for a limit.
                Image(systemName: "hourglass").foregroundStyle(Theme.warn).frame(width: 16)
                    .help(LimitWait.subChatsLine(engine.subChatLimitWaits[conversation.id] ?? []) ?? "")
                    .accessibilityLabel("Waiting for a limit")
            } else if conversation.busy {
                Spinner().frame(width: 16)
            } else {
                AgentAvatar(agent: engine.agent(conversation.agentId), size: 16)
            }
            Text(conversation.title.isEmpty ? "New conversation" : conversation.title)
                .lineLimit(1)
                .foregroundStyle(conversation.title.isEmpty ? Theme.tx2 : Theme.tx)
            AllowEverythingMark(engine: engine, conversation: conversation)
            Spacer(minLength: 0)
            let needsYou = conversation.parent == nil
                ? engine.inbox.contains { $0.rootConversationId == conversation.id }
                : engine.inbox.contains { $0.conversationId == conversation.id }
            if needsYou {
                Tag("needs you", .warn).accessibilityLabel("Needs you")
            } else if let wait {
                // The title gives way, not the time.
                Tag(wait.shortTag, .warn).fixedSize().help(wait.sentence)
            } else if subChats > 0, model.collapsed.contains(conversation.id), let waits = engine.subChatLimitWaits[conversation.id] {
                // Folded away, its sub-chats' rows cannot say it.
                Tag("\(waits.count) at limit", .warn).fixedSize().help(LimitWait.subChatsLine(waits) ?? "")
            }
            // Which branch the conversation's folder is on, coloured by how it stands. On every row, sub-chats too, so
            // each one's branch can be followed from the sidebar; one in its parent's checkout draws it faded.
            if let branch = engine.branches[conversation.id] {
                BranchBadge(engine: engine, conversationID: conversation.id, status: branch)
            }
            if subChats > 0 {
                let collapsed = model.collapsed.contains(conversation.id)
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if collapsed { model.collapsed.remove(conversation.id) } else { model.collapsed.insert(conversation.id) }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("\(subChats)").font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                    }
                    .foregroundStyle(Theme.tx3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show \(subChats) sub-chat\(subChats == 1 ? "" : "s")" : "Hide sub-chats")
                .accessibilityLabel(collapsed ? "Show \(subChats) sub-chats" : "Hide \(subChats) sub-chats")
            }
        }
        .tag(Selection.conversation(conversation.id))
        // Dropped on a pane, the conversation shows there.
        .draggable(ConversationDrag(id: conversation.id)) {
            Label(conversation.title.isEmpty ? "New conversation" : conversation.title, systemImage: "bubble.left")
                .padding(6)
        }
        .contextMenu(previewAs: conversation.title.isEmpty ? "New conversation" : conversation.title, String(conversation.id)) {
            Button("Rename…") { model.beginRename(conversation) }
            if model.workspace.canSplit {
                Button("Open in New Pane") {
                    model.splitPane(.row)
                    model.put(conversation.id, in: model.workspace.focused)
                }
            }
            // A sub-chat is archived with the conversation it belongs to.
            if conversation.parent == nil { Button("Archive") { model.archive(conversation) } }
            Button("Delete", role: .destructive) { model.delete(conversation) }
        }
    }
}

/// The Inbox's row in the sidebar, with what waits there. A view of its own, so that a plan's limits, which can change
/// with every answer from a subscription, draw only this row again.
private struct InboxRow: View {
    let engine: EngineClient

    var body: some View {
        let notices = PlanLimits(engine.extras["limits"])?.notices.count ?? 0
        HStack(spacing: 8) {
            Image(systemName: engine.inbox.isEmpty && notices == 0 ? "tray" : "tray.full").foregroundStyle(Theme.tx2).frame(width: 20)
            Text("Inbox")
            Spacer(minLength: 4)
            if !engine.inbox.isEmpty {
                Tag("\(engine.inbox.count)", .warn).accessibilityLabel("\(engine.inbox.count) waiting")
            } else if notices > 0 {
                // A notice of a plan's window waits on nobody, so it is counted without the colour of a request.
                Tag("\(notices)").accessibilityLabel(notices == 1 ? "1 notice" : "\(notices) notices")
            }
        }
    }
}

/// Activity's row in the sidebar: how many runs there are, and whether the engine restarted. A view of its own, since
/// the engine says what is running several times a second while agents work, and only this needs drawing again for it,
/// not the whole sidebar (#347).
private struct ActivityBadges: View {
    let engine: EngineClient

    var body: some View {
        if engine.recovery != nil {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Theme.ok)
                .help("The engine restarted after stopping unexpectedly")
                .accessibilityLabel("Engine restarted")
        }
        // A run waiting for a provider's limit is counted apart from those working (#343).
        let waiting = engine.limitWaits.count
        if engine.runningCount > waiting {
            // Beside the count at the limit, the word gives way so that the row's own title fits.
            let running = engine.runningCount - waiting
            Tag(waiting > 0 ? "\(running)" : "\(running) running", .acc).fixedSize()
                .help("\(running) running")
                .accessibilityLabel("\(running) running")
        }
        if waiting > 0 {
            Tag("\(waiting) at limit", .warn).fixedSize()
                .help("\(waiting) waiting for a provider’s limit; they carry on by themselves")
                .accessibilityLabel("\(waiting) waiting for a limit")
        }
    }
}

/// The foot of the sidebar, on both sides of the window: whether the engine runs, today's spend, the browser, Settings.
struct SidebarFooter: View {
    let engine: EngineClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 7) {
            Dot(color: statusColor)
            // The status keeps its one line; in a narrow sidebar the day's spend gives way first. While the engine keeps
            // the Mac awake (#561) the line says so, including how many conversations it is kept awake for.
            Text(statusText).foregroundStyle(Theme.tx2).lineLimit(1).fixedSize()
                .help(awakeHelp)
            Spacer(minLength: 4)
            if let today = engine.usage?.today, today.cost > 0 {
                // The longer wording when there is room for it, the bare amount when there is not.
                ViewThatFits(in: .horizontal) {
                    Text("\(today.costText) today")
                    Text(today.costText)
                }
                .lineLimit(1)
                .foregroundStyle(Theme.tx3)
                .help("Spent today on models paid for by use")
            }
            Button("Browser", systemImage: "globe") { openWindow(id: "browser") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tx3)
                .help("Open pi²’s browser: the pages your agents are on (⇧⌘B)")
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tx3)
                .help("Settings")
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.side)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var statusText: String {
        if engine.startProblem != nil { return "Engine could not start" }
        return switch engine.status {
        case .connecting: "Starting engine…"
        case .connected: "Engine running"
        case .restarting: "Engine stopped — restarting…"
        }
    }

    /// What the "Engine running" line says when hovered: while the engine keeps the Mac awake, that it does and for how
    /// many conversations (#561). The count is of the runs Activity shows as working, which are the ones the engine keeps
    /// the Mac awake for; for the minute after the last one it says it is still kept, so a run that starts again does not
    /// find the Mac asleep.
    private var awakeHelp: Text {
        guard case .bool(true)? = engine.extras["awake"]?["holding"] else {
            return Text("The engine keeps running with pi²’s window closed")
        }
        let working = engine.activity.filter { $0.status == "working" }.count
        if working > 0 {
            return Text("Keeping this Mac awake: \(working) conversation\(working == 1 ? "" : "s") working")
        }
        return Text("Keeping this Mac awake, for now with no conversation working")
    }

    private var statusColor: Color {
        if engine.startProblem != nil { return Theme.bad }
        return switch engine.status {
        case .connecting: Theme.tx3
        case .connected: Theme.ok
        case .restarting: Theme.warn
        }
    }
}

/// An agent in the sidebar: its avatar and name, the model it runs, and a quick way to start a conversation with it.
struct AgentRow: View {
    let model: AppModel
    let agent: AgentProfile
    @State private var hovering = false
    private var engine: EngineClient { model.engine }

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: agent, size: 20)
            // With the red tag beside it, the name keeps its room and the model's name gives way first.
            Text(agent.name).lineLimit(1).layoutPriority(1)
            if agent.allowEverything == true {
                Tag(AllowEverything.tag, .bad).fixedSize().help("\(agent.name) asks you about nothing and may use any app")
            }
            Spacer(minLength: 4)
            if hovering {
                Button("New conversation with \(agent.name)", systemImage: "plus.bubble") {
                    model.newConversation(agentId: agent.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.tx2)
                .help("New conversation with \(agent.name)")
            } else {
                Text(engine.shortModelName(agent.model)).font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1).layoutPriority(-1)
                    // Kept for VoiceOver and keyboard users, who never hover.
                    .accessibilityAction(named: "New conversation with \(agent.name)") { model.newConversation(agentId: agent.id) }
            }
        }
        .onHover { hovering = $0 }
        .contextMenu(previewAs: agent.name, agent.id) {
            Button("Duplicate", systemImage: "doc.on.doc") { model.duplicateAgent(agent.id) }
        }
    }
}

extension EngineClient {
    /// A model's name as the sidebar shows it: "Opus 5.5" rather than "Claude Opus 5.5". Nil means the app default.
    func shortModelName(_ ref: ModelRef?) -> String {
        guard let ref = ref ?? defaultModel else { return "" }
        let name = allModels.first { $0.ref == ref }?.name ?? ref.modelId
        for prefix in ["Claude ", "Demo model "] where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? name : rest.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return name
    }
}

/// Menu bar equivalents of the toolbar controls, for the keyboard and for accessibility.
struct ConversationCommands: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }
    private var state: ConversationState? { model.activeConversationID.flatMap { engine.open[$0]?.state } }

    var body: some View {
        let id = model.activeConversationID
        // A chat's assistant has no tools on this Mac and no folder.
        let chat = id.map(engine.isChat) ?? false
        Picker("Tool Access", selection: Binding(
            get: { state?.agent.access ?? "none" },
            set: { value in if let id { engine.setAccess(value, for: id) } }
        )) {
            ForEach(AccessLevel.all, id: \.id) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(id == nil || chat)
        Button("Choose Folder…") { if let id { engine.chooseFolder(for: id) } }
            .disabled(id == nil || chat)
        Divider()
        Menu("Model") {
            ForEach(engine.modelGroups, id: \.provider) { group in
                Menu(group.name) {
                    ForEach(group.models, id: \.ref) { item in
                        Button(item.listName) {
                            if let id { engine.configure(id, ["model": ["provider": item.provider, "modelId": item.id]]) }
                        }
                    }
                }
            }
        }
        .disabled(id == nil)
        Divider()
        Button("Summarise Earlier Messages") { if let id { engine.perform("conversation.compact", ["id": id]) } }
            .disabled(id == nil || state?.compacting == true)
        Button("Start Fresh Context") { if let id { engine.perform("conversation.reset", ["id": id]) } }
            .disabled(id == nil)
        Button("Continue with an Agent…") { if let id { model.continueWithAgent(id) } }
            .disabled(id == nil || !chat || model.mode != .chat || !engine.canContinueWithAgent(id ?? 0))
        Button("Fork From Last Answer") {
            if let id, let last = engine.open[id]?.items.last(where: { $0.kind == "assistant" && $0.stop == "stop" }) { engine.fork(id, at: last.id) }
        }
        .disabled(id == nil)
        Menu("Export") {
            Button("As Markdown…") { if let conversation = model.activeConversation { StorageActions.export(conversation, format: "markdown", engine: engine) } }
            Button("As JSON…") { if let conversation = model.activeConversation { StorageActions.export(conversation, format: "json", engine: engine) } }
        }
        .disabled(model.activeConversation == nil)
        Divider()
        Button("Rename…") { if let conversation = model.activeConversation { model.beginRename(conversation) } }
            .disabled(model.activeConversation == nil)
        // The same key as in Mail. A sub-chat is archived with the conversation it belongs to.
        Button("Archive Conversation") { if let conversation = model.activeConversation { model.archive(conversation) } }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(model.activeConversation == nil || model.activeConversation?.parent != nil)
        Button("Delete Conversation") { if let conversation = model.activeConversation { model.delete(conversation) } }
            .disabled(model.activeConversation == nil)
        Divider()
        Button("Stop") { if let id { engine.perform("abort", ["id": id]) } }
            .keyboardShortcut(".")
            .disabled(state?.busy != true)
        Button("Continue") { if let id { engine.perform("continue", ["id": id]) } }
            .disabled(state?.failure == nil || state?.busy == true)
    }
}

/// What the window shows with nothing selected: the pi² mark and the agents to start with.
struct WelcomeView: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        VStack(spacing: 18) {
            PiMark(size: 64)
            VStack(spacing: 6) {
                Text("What should we work on?").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                Text("Pick an agent to start a conversation. Each one has its own model, instructions and tools.")
                    .foregroundStyle(Theme.tx2)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                ForEach(engine.agents.prefix(4)) { agent in
                    Button { model.newConversation(agentId: agent.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                AgentAvatar(agent: agent, size: 24)
                                Text(agent.name).font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 0)
                                Text(engine.shortModelName(agent.model)).font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1)
                            }
                            Text(agent.description.isEmpty ? "No description yet." : agent.description)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tx2)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                        }
                        .padding(12)
                        .frame(width: 190, alignment: .leading)
                        .panel(radius: 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(LiftButtonStyle())
                    .disabled(engine.status != .connected)
                    .help("New conversation with \(agent.name)")
                }
            }
            Text("⌘N starts a conversation with the agent you used last · ⌘K finds anything")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tx3)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

/// A card that lifts slightly under the pointer.
struct LiftButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? Theme.acc.opacity(0.5) : .clear))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .offset(y: hovering ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 10, y: 6)
            .animation(.snappy(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Hands the app model a way to reopen the main window, from a view that has the environment to do it.
private struct WindowOpener: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    #if PI2_DEVELOPMENT
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        Color.clear.onAppear {
            model.showMainWindow = { openWindow(id: "main") }
            model.engine.browser.showWindow = { openWindow(id: "browser") }
        }
        #if PI2_DEVELOPMENT
        // `PI2_SHOW=settings…` opens the Settings window, but not while the app is launching: a development build once
        // overflowed its stack there, inside the Settings scene, as the first window came on screen and the scenes'
        // phases changed (#74). So it waits until the engine has answered with the library, which is after the main
        // window is up and has chosen what to show, then a second more, and opens Settings from a task of its own.
        .task(id: model.engine.hasLoadedLibrary) {
            guard model.engine.hasLoadedLibrary, SettingsLaunch.asked != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, SettingsLaunch.takeWindow() { openSettings() }
        }
        // `PI2_SHOW=output:<id>` opens that background command's output window, the same way and as late.
        .task(id: model.engine.hasLoadedLibrary) {
            guard model.engine.hasLoadedLibrary, let id = OutputLaunch.asked else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, OutputLaunch.take() { openWindow(id: BackgroundOutputScene.id, value: id) }
        }
        // `PI2_SHOW=palette:<query>` opens the command palette with that query, once the sidebar has what it lists.
        .task(id: model.engine.hasLoadedLibrary) {
            guard model.engine.hasLoadedLibrary, PaletteLaunch.asked != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, PaletteLaunch.takeOpen() { model.showingPalette = true }
        }
        // `PI2_MENU=<label>` writes what that element's context menu holds, once the page `PI2_SHOW` opened has settled.
        .task(id: model.engine.hasLoadedLibrary) {
            guard model.engine.hasLoadedLibrary, ContextMenuPreview.asked != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await ContextMenuPreview.start(home: model.engine.home) }
        }
        #endif
    }
}
