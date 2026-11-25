import LoginItemKit
import PiModels
import SwiftUI
import WindowKit

/// What the main window is showing, beside chat mode. Every conversation opens where it lives
/// (`AppModel.openConversation`, OpenConversation.swift): in its project's hub, in chat mode or in the Archive's reader.
enum Selection: Hashable {
    /// The Shared pages of the sidebar of projects: Activity, Usage and the Archive; a template's page.
    case activity
    case usage
    case archive
    case agent(String)
    /// A project's hub, by the project's id (ProjectHub.swift).
    case project(String)
    /// The Dashboard's row in the sidebar of projects (ProjectsSidebar.swift; drawn by #481).
    case dashboard
    /// A row under the open project in the sidebar of projects: one of its agents' conversations, shown in place of the
    /// board (#473). Only the sidebar's list holds it, so that the arrow keys reach those rows (#600); choosing it opens the
    /// conversation with `AppModel.openAgent`, and the window's selection stays `.project`.
    case projectAgent(project: String, conversation: Int)
}

#if PI2_DEVELOPMENT
extension Selection {
    /// What a development build was asked to open on, in `PI2_SHOW`: "activity", "usage", "archive" or "agent:<id>" (a
    /// template's page). For taking pictures of the app; see docs/development.md. "agent:<id>#<section>" opens the
    /// agent's page at one of its sections, which the page reads for itself (`AgentSection`). A conversation's number or
    /// title is `LaunchConversation`'s, and opens where the conversation lives. "settings" and what follows it is not
    /// about this window: it opens the Settings window (`SettingsLaunch`), and this one opens as usual; so does
    /// "output:<id>", which opens a background command's output window (`OutputLaunch`).
    init?(launch value: String?) {
        guard let value, !value.isEmpty, !ProjectCopyView.reserves(value) else { return nil }
        switch value {
        case "activity": self = .activity
        case "usage": self = .usage
        case "archive": self = .archive
        default:
            guard value.hasPrefix("agent:") else { return nil }
            self = .agent(String(value.dropFirst("agent:".count).prefix { $0 != "#" }))
        }
    }
}

/// The conversation a development build was asked to open on, in `PI2_SHOW`: its number or title, matched exactly in the
/// library first, then the Archive (archived sub-chats included). It opens where it lives, as every Open does.
@MainActor
enum LaunchConversation {
    /// Set once the conversation has been opened, so that it is opened once.
    private static var taken = false

    /// The launch's conversation, once: nil after it has been found.
    static func find(_ value: String?, conversations: [ConversationSummary], archived: [ArchivedConversation]) -> Int? {
        guard waits(value) else { return nil }
        let found = match(value, conversations: conversations, archived: archived)
        if found != nil { taken = true }
        return found
    }

    /// The conversation a value names, if it names one: for the launch, and a test copy's `show` while it runs.
    static func match(_ value: String?, conversations: [ConversationSummary], archived: [ArchivedConversation]) -> Int? {
        guard let value, names(value) else { return nil }
        return conversations.first(where: { String($0.id) == value || $0.title == value })?.id
            ?? archived.first(where: { String($0.id) == value || $0.title == value })?.id
    }

    /// Whether `PI2_SHOW` names a conversation not opened yet, which the window waits for rather than landing elsewhere.
    static func waits(_ value: String?) -> Bool {
        guard !taken, let value else { return false }
        return names(value)
    }

    /// Whether a value can only name a conversation: no page, project, chat mode or other window.
    private static func names(_ value: String) -> Bool {
        guard !value.isEmpty, !ProjectCopyView.reserves(value), Selection(launch: value) == nil, !value.hasPrefix("output:") else { return false }
        return !["chat", "settings", "palette", "presentation"].contains { value == $0 || value.hasPrefix($0 + ":") }
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
    /// Chat mode's side of the window, and which side shows (ChatMode.swift).
    let chats = ChatModeState()
    /// How each project's hub was left (ProjectHub.swift).
    let hubs = ProjectHubs()
    var selection: Selection? {
        didSet {
            // Anything chosen (from the menu bar, the palette, a notification) is shown on the projects' side.
            if selection != nil, !chats.holdingMode { mode = .agents }
            if case .project(let id) = selection { projectsSidebar.open = id }
            // Coming to the Archive from elsewhere shows its list, not the conversation it was last reading.
            if selection == .archive, oldValue != .archive { archiveReading = nil }
        }
    }
    /// The conversation the Archive reads in place of its list (OpenConversation.swift).
    var archiveReading: Int?
    /// What the sidebar of projects keeps unfolded (ProjectsSidebar.swift).
    let projectsSidebar = ProjectsSidebarState()
    var showingPalette = false
    /// ⌘N's picker of a project's agents (ProjectStart.swift).
    var startPicker: StartPickerAsk?
    #if PI2_DEVELOPMENT
    /// Opens the Settings window and a background command's output window, for `scripts/test-copy show` while the copy
    /// runs (#553); set once the main window is up, so nil before that.
    var openSettingsWindow: (() -> Void)?
    var openOutputWindow: ((String) -> Void)?
    /// The Settings tab the running copy was asked for, for a Settings window that is already open to move to (#553).
    var settingsTabLive: SettingsTab?
    #endif
    /// The orchestrators' conversations the Dashboard's columns show the end of, while they are on screen and not
    /// folded away (#618). Set by the Dashboard, and empty while it is not shown.
    var dashboardConversations: Set<Int> = []
    /// What the View menu's Dashboard keys ask of it (#618).
    let dashboardKeys = DashboardKeys()
    /// Stop All, from the Dashboard's line or the palette, while it waits for the person to confirm it (#645).
    var stoppingAll: StopAllRequest?

    init() {
        #if PI2_DEVELOPMENT
        TestCopyPanels.install(engine: engine)
        #endif
        engine.onNavigate = { [weak self] id, from in self?.openConversation(id, from: from) }
        // A sub-chat card's Beside opens it in a new pane of its project's hub, beside the conversation it came from
        // (#657), or where it lives, as Open does, when that is not a hub (#644).
        engine.onOpenBeside = { [weak self] id, beside in self?.openConversation(id, from: beside, beside: true) }
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

    /// The conversations the window has on screen: chat mode's chat, the hub's and the Archive reader's, and the ends
    /// of the Dashboard's orchestrators. The engine is told (docs/local-models-running.md).
    var shownConversations: Set<Int> {
        Set(chats.selection.map { [$0] } ?? [])
            .union(hubConversation.map { [$0] } ?? []).union(hubPaneConversations)
            .union(archiveConversation.map { [$0] } ?? [])
            .union(dashboardConversations)
    }

    /// Starts a conversation with an agent, and opens it where it lives.
    func newConversation(agentId: String) {
        Task {
            if let id = await engine.createConversation(agentId: agentId) { openConversation(id) }
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
                    // A project agent's copy is in the same project, and its page opens in that project's Agents tab, as
                    // New Agent's does, rather than at window level, which no row of the sidebar marks (#643).
                    if let project = engine.agent(id)?.projectId, engine.project(project) != nil {
                        showAgentPage(copyID, in: project)
                    } else {
                        selection = .agent(copyID)
                    }
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
            // Shown in place of a project's board, the board comes back (#642).
            hubs.boardBack(from: [deleting.id])
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

    /// Puts a conversation in the Archive. A chat on screen gives way to the next, as it would in a mail app.
    func archive(_ conversation: ConversationSummary) {
        moveOnFromChat(conversation.id)
        // Shown in place of a project's board, it or one of its sub-chats, which go with it, the board comes back (#642).
        hubs.boardBack(from: withSubChats(conversation.id))
        engine.perform("conversation.archive", ["id": conversation.id])
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
                Button("Show Activity") { model.selection = .activity }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Usage") { model.selection = .usage }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Show Archive") { model.selection = .archive }
                Divider()
                HubPaneCommands(model: model)
                HubCommands(model: model)
                DashboardCommands(model: model)
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

        // What an agent presented, one window per presentation, opened by Expand on its card or under Needs you
        // (PresentationWindow.swift, #946). Never at launch, and not brought back after a restart: the main window starts
        // the engine, and the card opens it again.
        WindowGroup("Presentation", id: PresentationWindowScene.id, for: PresentationRef.self) { $ref in
            Group {
                if let ref {
                    PresentationWindow(app: model, ref: ref)
                } else {
                    Text("No presentation was chosen.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .windowMinimum(width: PresentationBar.minimumWidth, height: 460) { model.engine.note($0) }
            .tint(.piAccent)
            .launchWindow()
        }
        .defaultSize(width: 1180, height: 820)
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
            SettingsView(engine: model.engine, model: model)
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
        Image(systemName: engine.waitingCount == 0 ? "circle.hexagongrid" : "circle.hexagongrid.fill")
        if engine.waitingCount > 0 { Text("\(engine.waitingCount)") }
    }
}

/// The File menu's ways to start something new that depend on what changes while the app runs: ⌘N, which starts
/// whatever the window is showing (a chat in chat mode), and a conversation with each of a project's agents. A view of
/// its own, so that the mode or the agents changing draws the menu again and not every scene (#436).
struct NewItemCommands: View {
    let model: AppModel

    var body: some View {
        if model.mode == .chat {
            Button("New Chat") { model.newChat() }
                .keyboardShortcut("n")
        } else {
            // A conversation is started with one of a project's agents, chosen in a short picker (#643).
            Button("New Conversation…") { model.askNewConversation() }
                .keyboardShortcut("n")
        }
        Menu("New Conversation With") {
            ProjectAgentChoices(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var engine: EngineClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.apply()
        #if PI2_DEVELOPMENT
        // A test copy's own appearance comes after the preference every build draws with, so that
        // `scripts/test-copy start|reopen --appearance` wins (#553).
        TestCopyAppearance.apply()
        #endif
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

/// The sidebar column's widths in points, which a test copy's `sidebar` request keeps to as well (#613).
enum SidebarColumn {
    static let narrowest: CGFloat = 210
    static let ideal: CGFloat = 250
    static let widest: CGFloat = 340
}

struct RootView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        NavigationSplitView {
            Group {
                if model.mode == .chat {
                    ChatSidebar(model: model)
                } else {
                    ProjectsSidebar(model: model)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ModeSwitch(model: model) }
            .navigationSplitViewColumnWidth(min: SidebarColumn.narrowest, ideal: SidebarColumn.ideal, max: SidebarColumn.widest)
        } detail: {
            Group {
                if model.mode == .chat {
                    ChatModeDetail(model: model)
                } else {
                    switch model.selection {
                    case .activity:
                        // What runs apart from the agents' runs (ActivityPage.swift, #655).
                        ActivityPage(model: model)
                    case .usage:
                        UsageView(model: model)
                    case .archive:
                        ArchiveView(model: model)
                    case .agent(let id):
                        AgentEditor(model: model, agentID: id)
                            .id(id)
                    case .project(let id), .projectAgent(let id, _):
                        ProjectHubView(model: model, projectID: id)
                            .id(id)
                            // The restart notice, over the hub rather than in its panels' headers, when the
                            // Dashboard is not showing (#645), and the notice of the update to projects (#716).
                            .safeAreaInset(edge: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    RemovalNotice(model: model)
                                    RecoveryBanner(model: model)
                                }
                            }
                    case .dashboard:
                        DashboardView(model: model)
                    case nil:
                        // Nothing chosen: what `landOnProjects` chooses, drawn until it has (#644).
                        if engine.projectStore.listed.isEmpty {
                            NoProjectsPage(model: model)
                                .safeAreaInset(edge: .top, spacing: 0) { RemovalNotice(model: model) }
                        } else {
                            DashboardView(model: model)
                        }
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
        .background(PresentationWindowOpener(engine: engine))
        .worktreeDialogs(engine: engine)
        .sheet(isPresented: $model.showingPalette) { PaletteView(model: model) }
        .sheet(item: $model.startPicker) { ask in NewConversationPicker(model: model, ask: ask) }
        .stopAllConfirmation(model: model)
        .sheet(isPresented: Binding(get: { engine.onboarded == false }, set: { _ in })) {
            OnboardingView(model: model)
                .interactiveDismissDisabled()
        }
        // Which conversations are on screen, for the engine: it keeps a model on this Mac loaded while one using it is.
        .onChange(of: model.shownConversations, initial: true) { _, shown in engine.setShown(shown) }
        .onChange(of: engine.hasLoadedLibrary) { _, loaded in
            // A hub's panes kept from last time whose conversations were archived or deleted since close (#657).
            if loaded { model.hubs.forget(projects: engine.projectStore.listed.map(\.id)) { id in !engine.conversations.contains { $0.id == id } } }
        }
        // At launch, once the engine has listed both the conversations and the projects, the window lands on the hub of
        // the one project, the Dashboard for several, or the page that makes the first (#644).
        .onChange(of: engine.hasLoadedLibrary && engine.projectStore.loaded, initial: true) { _, ready in
            guard ready, model.selection == nil else { return }
            #if PI2_DEVELOPMENT
            let asked = ProcessInfo.processInfo.environment["PI2_SHOW"]
            if ChatLaunch.apply(asked, to: model) { return }
            if let page = Selection(launch: asked) {
                model.selection = page
                return
            }
            if let id = LaunchConversation.find(asked, conversations: engine.conversations, archived: engine.archived) {
                model.openConversation(id)
                return
            }
            if ProjectCopyView.launch?.show == "dashboard" {
                model.selection = .dashboard
                return
            }
            // A conversation named there that is made after launch opens when it comes (below), so the window waits.
            if LaunchConversation.waits(asked) { return }
            #endif
            // The window stays on the side it was last on.
            model.chats.holdingMode = true
            model.landOnProjects()
            model.chats.holdingMode = false
        }
        // A window left with nothing chosen lands on the Dashboard, or the one project's hub (#644).
        .onChange(of: model.selection) { _, selection in
            if selection == nil, model.mode == .agents { model.landOnProjects() }
        }
        // So does one on the page that makes the first project, once there is one, made here or elsewhere.
        .onChange(of: engine.projectStore.listed.isEmpty) { _, none in
            guard !none, model.selection == nil, engine.hasLoadedLibrary else { return }
            #if PI2_DEVELOPMENT
            if LaunchConversation.waits(ProcessInfo.processInfo.environment["PI2_SHOW"]) { return }
            #endif
            model.chats.holdingMode = true
            model.landOnProjects()
            model.chats.holdingMode = false
        }
        .onChange(of: engine.conversations) { old, list in
            // A hub's pane whose conversation leaves the library, archived or deleted, closes (#657).
            if engine.hasLoadedLibrary {
                let gone = Set(old.map(\.id)).subtracting(list.map(\.id))
                if !gone.isEmpty { model.hubs.forget(projects: engine.projectStore.listed.map(\.id)) { gone.contains($0) } }
            }
            #if PI2_DEVELOPMENT
            // A conversation `PI2_SHOW` names that is made after launch, through the engine's socket, opens when it comes,
            // as long as nothing else has been chosen.
            if model.selection == nil, engine.hasLoadedLibrary,
               let id = LaunchConversation.find(ProcessInfo.processInfo.environment["PI2_SHOW"], conversations: list, archived: engine.archived) {
                model.openConversation(id)
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
                    ? "\(base)\n\nIts worktree of \(worktree.repo) has uncommitted changes, so it is kept. Its project’s Branches tab lists it under Left Behind, where it can be removed later."
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
            if agent.allowEverything == true { AllowEverythingTag(name: agent.name) }
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

/// Menu bar equivalents of the toolbar controls, for the keyboard and for accessibility. They act on chat mode's chat, or,
/// with a project's hub shown, the hub's conversation that has the keyboard (#632): the agent's in place of the board,
/// else the orchestrator's. Each says in its help why it does not apply when it does not.
struct ConversationCommands: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        let id = model.commandConversationID
        let state = id.flatMap { engine.open[$0]?.state }
        let conversation = id.flatMap { id in engine.conversations.first { $0.id == id } }
        // The orchestrator's current conversation: the project's Start fresh, the orchestrator's model, and no fork.
        let orchestrator = model.commandOrchestratorProject
        let inHub = model.shownProject != nil
        let none = inHub ? "The project's conversation with the orchestrator is still being started." : "No conversation is shown."
        // Only a chat is continued with an agent.
        let chat = id.map(engine.isChat) ?? false
        let lastAnswer = id.flatMap { engine.open[$0]?.items.last(where: { $0.kind == "assistant" && $0.stop == "stop" }) }
        // In a hub, the agent the conversation runs as, whose model the Model menu changes.
        let hubAgent = inHub ? engine.agent(conversation.flatMap { $0.runsAs ?? $0.agentId }) : nil
        // The orchestrator's current conversation is renamed with the project and archived by Start fresh (#642).
        let current = conversation?.orchestrator == "current" && inHub
        Menu("Model") {
            ForEach(engine.modelGroups, id: \.provider) { group in
                Menu(group.name) {
                    ForEach(group.models, id: \.ref) { item in
                        Button(item.listName) {
                            // In a project the model is the agent's, as the hub's bar and the agent panel's menu change
                            // it (#642).
                            if let hubAgent {
                                engine.setModel(item, for: hubAgent)
                            } else if let id {
                                engine.configure(id, ["model": ["provider": item.provider, "modelId": item.id]])
                            }
                        }
                    }
                }
            }
        }
        .disabled(id == nil)
        .help(id == nil ? none : hubAgent.map { AgentModelItems.modelHelp($0.name) } ?? "Model for this conversation")
        Divider()
        // An earlier conversation with a project's orchestrator takes no messages, so it is not summarised or started afresh.
        let earlier = id.flatMap(engine.earlierRefusal)
        Button("Summarise Earlier Messages") { if let id { engine.perform("conversation.compact", ["id": id]) } }
            .disabled(id == nil || earlier != nil || state?.compacting == true)
            .help(id == nil ? none : earlier ?? (state?.compacting == true ? "Earlier messages are being summarised now." : "Replace the earlier part of what the model reads with a summary. The messages stay in the conversation."))
        if let orchestrator {
            // The project's own (docs/projects.md, 6.5), after the hub's confirmation, never a fresh context.
            let refusal = engine.freshRefusal(orchestrator)
            Button("Start Fresh…") { model.hubs.freshAsked = orchestrator.id }
                .disabled(refusal != nil)
                .help(refusal ?? "Begin a new conversation with the orchestrator, which starts with the project as it stands. This one is kept, to read.")
        } else {
            Button("Start Fresh Context") { if let id { engine.perform("conversation.reset", ["id": id]) } }
                .disabled(id == nil || earlier != nil)
                .help(id == nil ? none : earlier ?? "The model stops seeing earlier messages. They stay in the conversation for you.")
        }
        Button("Continue with an Agent…") { if let id { model.continueWithAgent(id) } }
            .disabled(id == nil || !chat || model.mode != .chat || !engine.canContinueWithAgent(id ?? 0))
            .help(chat && model.mode == .chat ? "Carry this chat on in a conversation with an agent" : "Only a chat, in chat mode, can be continued with an agent.")
        Button("Fork From Last Answer") {
            guard let id, let lastAnswer else { return }
            // A fork of an agent's conversation in the hub is one of the project's, and shows in place of the board.
            if let project = model.shownProject { engine.fork(id, at: lastAnswer.id) { model.openAgent($0, in: project) } } else { engine.fork(id, at: lastAnswer.id) }
        }
        .disabled(id == nil || id.flatMap(engine.forkRefusal) != nil || lastAnswer == nil)
        .help(id == nil ? none
            : id.flatMap(engine.forkRefusal) ?? (lastAnswer == nil
            ? "There is no finished answer to fork from yet." : "A new conversation that goes on from the last answer"))
        Menu("Export") {
            Button("As Markdown…") { if let conversation { StorageActions.export(conversation, format: "markdown", engine: engine) } }
            Button("As JSON…") { if let conversation { StorageActions.export(conversation, format: "json", engine: engine) } }
        }
        .disabled(conversation == nil)
        .help(conversation == nil ? none : "Save this conversation to a file")
        Divider()
        Button("Rename…") { if let conversation { model.beginRename(conversation) } }
            .disabled(conversation == nil || current)
            .help(conversation == nil ? none : current ? ConversationActions.currentRefusal : "Rename this conversation")
        // The same key as in Mail. A sub-chat is archived with the conversation it belongs to.
        let archiveRefusal = conversation.flatMap { inHub ? ConversationActions.archiveRefusal($0) : $0.parent != nil ? "A sub-chat is archived with the conversation it belongs to." : nil }
        Button("Archive Conversation") { if let conversation { model.archive(conversation) } }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(conversation == nil || archiveRefusal != nil)
            .help(conversation == nil ? none : archiveRefusal ?? "Put this conversation away, stopping its work. It can be restored from the Archive.")
        Button("Delete Conversation") { if let conversation { model.delete(conversation) } }
            .disabled(conversation == nil || current)
            .help(conversation == nil ? none : current ? ConversationActions.currentRefusal : "Delete this conversation, after asking")
        Divider()
        Button("Stop") { if let id { engine.perform("abort", ["id": id]) } }
            .keyboardShortcut(".")
            .disabled(state?.busy != true)
            .help(state?.busy == true ? "Stop the run and everything it started" : "Nothing is running in this conversation.")
        Button("Continue") { if let id { engine.perform("continue", ["id": id]) } }
            .disabled(state?.failure == nil || state?.busy == true)
            .help(state?.busy == true ? "The conversation is answering." : state?.failure == nil ? "There is no stopped run to continue." : "Resume the run from where it stopped")
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
            #if PI2_DEVELOPMENT
            model.openSettingsWindow = { openSettings() }
            model.openOutputWindow = { openWindow(id: BackgroundOutputScene.id, value: $0) }
            #endif
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
