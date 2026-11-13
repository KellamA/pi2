import SwiftUI

/// What the main window is showing.
enum Selection: Hashable {
    case inbox
    case activity
    case usage
    case archive
    case agent(String)
    case conversation(Int)
}

#if DEBUG
extension Selection {
    /// What a development build was asked to open on, in `PI2_SHOW`: "inbox", "activity", "usage", "agent:<id>", or
    /// a conversation's number or title. For taking pictures of the app; see docs/development.md.
    init?(launch value: String?, conversations: [ConversationSummary]) {
        guard let value, !value.isEmpty else { return nil }
        switch value {
        case "inbox": self = .inbox
        case "activity": self = .activity
        case "usage": self = .usage
        case "archive": self = .archive
        default:
            if value.hasPrefix("agent:") {
                self = .agent(String(value.dropFirst("agent:".count)))
            } else if let found = conversations.first(where: { String($0.id) == value || $0.title == value }) {
                self = .conversation(found.id)
            } else {
                return nil
            }
        }
    }
}
#endif

/// App-level UI state.
@MainActor
@Observable
final class AppModel {
    let engine = EngineClient()
    var selection: Selection?
    var showingPalette = false
    /// Conversations whose sub-chats are folded away in the sidebar.
    var collapsed: Set<Int> = []

    init() {
        engine.onNavigate = { [weak self] id in self?.selection = .conversation(id) }
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

    func confirmDelete() {
        if let deleting {
            if selectedConversationID == deleting.id { selection = nextAfter(deleting.id) }
            engine.perform("conversation.delete", ["id": deleting.id])
        }
        deleting = nil
    }

    /// Puts a conversation in the Archive. The window moves on to the next conversation, as it would in a mail app.
    func archive(_ conversation: ConversationSummary) {
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

    var body: some Scene {
        Window("pi²", id: "main") {
            RootView(model: model)
                .frame(minWidth: 820, minHeight: 480)
                .tint(.piAccent)
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
                Button("New Conversation") { model.newConversation() }
                    .keyboardShortcut("n")
                Menu("New Conversation With") {
                    ForEach(model.engine.agents) { agent in
                        Button(agent.name) { model.newConversation(agentId: agent.id) }
                    }
                }
                Button("New Agent") { model.newAgent() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Command Palette…") { model.showingPalette = true }
                    .keyboardShortcut("k")
                Button("Quick Ask (⌃⌥Space anywhere)") { QuickAsk.shared.show(model: model) }
            }
            CommandGroup(after: .sidebar) {
                Button("Show Inbox") { model.selection = .inbox }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Show Activity") { model.selection = .activity }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Usage") { model.selection = .usage }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Show Archive") { model.selection = .archive }
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
                .tint(.piAccent)
        }
        .defaultSize(width: 1100, height: 780)
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarView(model: model)
                .tint(.piAccent)
        } label: {
            // The count of things waiting, next to the icon, so it is visible without opening anything.
            Image(systemName: model.engine.inbox.isEmpty ? "circle.hexagongrid" : "circle.hexagongrid.fill")
            if !model.engine.inbox.isEmpty { Text("\(model.engine.inbox.count)") }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(engine: model.engine)
                .tint(.piAccent)
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
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            switch model.selection {
            case .inbox:
                InboxView(model: model)
            case .activity:
                ActivityView(model: model)
            case .usage:
                UsageView(model: model)
            case .archive:
                ArchiveView(model: model)
            case .agent(let id):
                AgentEditor(model: model, agentID: id)
                    .id(id)
            case .conversation(let id):
                ChatView(engine: engine, id: id)
                    .id(id)
            case nil:
                WelcomeView(model: model)
            }
        }
        .background(WindowOpener(model: model))
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
        .onChange(of: engine.hasLoadedLibrary) { _, loaded in
            guard loaded, model.selection == nil else { return }
            #if DEBUG
            if let asked = Selection(launch: ProcessInfo.processInfo.environment["PI2_SHOW"], conversations: engine.conversations) {
                model.selection = asked
                return
            }
            #endif
            // On launch, land on the most recent conversation.
            if let first = engine.rootConversations.first { model.selection = .conversation(first.id) }
        }
        .onChange(of: engine.conversations) { _, list in
            // The conversation on screen was deleted: move to the next one. An archived one may stay on screen: it can
            // still be read.
            if let id = model.selectedConversationID, engine.hasLoadedLibrary, !list.contains(where: { $0.id == id }), !model.isArchived(id) {
                model.selection = list.first { $0.parent == nil }.map { .conversation($0.id) }
            }
        }
        .confirmationDialog(
            "Delete “\(model.deleting.map { $0.title.isEmpty ? "New conversation" : $0.title } ?? "")”?",
            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleting = nil }
        } message: {
            Text("Any work it is doing is stopped, and pi² will not show it again or bring it back. Its text stays in pi²’s data on this Mac. To put it away but keep it, archive it instead.")
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
    @Environment(\.openWindow) private var openWindow
    private var engine: EngineClient { model.engine }

    var body: some View {
        List(selection: $model.selection) {
            navRow("Inbox", icon: engine.inbox.isEmpty ? "tray" : "tray.full", tag: .inbox) {
                if !engine.inbox.isEmpty {
                    Tag("\(engine.inbox.count)", .warn).accessibilityLabel("\(engine.inbox.count) waiting")
                }
            }
            navRow("Activity", icon: "waveform.path.ecg", tag: .activity) {
                if engine.recovery != nil {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Theme.ok)
                        .help("The engine restarted after stopping unexpectedly")
                        .accessibilityLabel("Engine restarted")
                }
                if !engine.activity.isEmpty {
                    Tag("\(engine.activity.count) running", .acc)
                }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 7) {
                Dot(color: statusColor)
                // The status keeps its one line; in a narrow sidebar the day's spend gives way first.
                Text(statusText).foregroundStyle(Theme.tx2).lineLimit(1).fixedSize()
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
        .toolbar {
            ToolbarItem {
                Button("New Conversation", systemImage: "square.and.pencil") { model.newConversation() }
                    .disabled(engine.status != .connected)
                    .help("New conversation (⌘N)")
            }
        }
        .alert("Rename conversation", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Title", text: $model.newTitle)
            Button("Rename") {
                if let renaming = model.renaming { engine.perform("conversation.rename", ["id": renaming.id, "title": model.newTitle]) }
                model.renaming = nil
            }
            Button("Cancel", role: .cancel) { model.renaming = nil }
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
        HStack(spacing: 8) {
            if conversation.busy {
                Spinner().frame(width: 16)
            } else {
                AgentAvatar(agent: engine.agent(conversation.agentId), size: 16)
            }
            Text(conversation.title.isEmpty ? "New conversation" : conversation.title)
                .lineLimit(1)
                .foregroundStyle(conversation.title.isEmpty ? Theme.tx2 : Theme.tx)
            Spacer(minLength: 0)
            let needsYou = conversation.parent == nil
                ? engine.inbox.contains { $0.rootConversationId == conversation.id }
                : engine.inbox.contains { $0.conversationId == conversation.id }
            if needsYou {
                Tag("needs you", .warn).accessibilityLabel("Needs you")
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
        .contextMenu {
            Button("Rename…") { model.beginRename(conversation) }
            // A sub-chat is archived with the conversation it belongs to.
            if conversation.parent == nil { Button("Archive") { model.archive(conversation) } }
            Button("Delete", role: .destructive) { model.delete(conversation) }
        }
    }

    private var statusText: String {
        switch engine.status {
        case .connecting: "Starting engine…"
        case .connected: "Engine running"
        case .restarting: "Engine stopped — restarting…"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .connecting: Theme.tx3
        case .connected: Theme.ok
        case .restarting: Theme.warn
        }
    }
}

/// An agent in the sidebar: its avatar and name, the model it runs, and a quick way to start a conversation with it.
private struct AgentRow: View {
    let model: AppModel
    let agent: AgentProfile
    @State private var hovering = false
    private var engine: EngineClient { model.engine }

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: agent, size: 20)
            Text(agent.name).lineLimit(1)
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
                Text(engine.shortModelName(agent.model)).font(.system(size: 11)).foregroundStyle(Theme.tx3).lineLimit(1)
                    // Kept for VoiceOver and keyboard users, who never hover.
                    .accessibilityAction(named: "New conversation with \(agent.name)") { model.newConversation(agentId: agent.id) }
            }
        }
        .onHover { hovering = $0 }
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
    private var state: ConversationState? { model.selectedConversationID.flatMap { engine.open[$0]?.state } }

    var body: some View {
        let id = model.selectedConversationID
        Picker("Tool Access", selection: Binding(
            get: { state?.agent.access ?? "none" },
            set: { value in if let id { engine.setAccess(value, for: id) } }
        )) {
            ForEach(AccessLevel.all, id: \.id) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(id == nil)
        Button("Choose Folder…") { if let id { engine.chooseFolder(for: id) } }
            .disabled(id == nil)
        Divider()
        Menu("Model") {
            ForEach(Dictionary(grouping: engine.models, by: \.providerName).sorted { $0.key < $1.key }, id: \.key) { group in
                Menu(group.key) {
                    ForEach(group.value) { item in
                        Button(item.name) {
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
        Button("Fork From Last Answer") {
            if let id, let last = engine.open[id]?.items.last(where: { $0.kind == "assistant" && $0.stop == "stop" }) { engine.fork(id, at: last.id) }
        }
        .disabled(id == nil)
        Menu("Export") {
            Button("As Markdown…") { if let conversation = model.selectedConversation { StorageActions.export(conversation, format: "markdown", engine: engine) } }
            Button("As JSON…") { if let conversation = model.selectedConversation { StorageActions.export(conversation, format: "json", engine: engine) } }
        }
        .disabled(model.selectedConversation == nil)
        Divider()
        Button("Rename…") { if let conversation = model.selectedConversation { model.beginRename(conversation) } }
            .disabled(model.selectedConversation == nil)
        // The same key as in Mail. A sub-chat is archived with the conversation it belongs to.
        Button("Archive Conversation") { if let conversation = model.selectedConversation { model.archive(conversation) } }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(model.selectedConversation == nil || model.selectedConversation?.parent != nil)
        Button("Delete Conversation") { if let conversation = model.selectedConversation { model.delete(conversation) } }
            .disabled(model.selectedConversation == nil)
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

    var body: some View {
        Color.clear.onAppear {
            model.showMainWindow = { openWindow(id: "main") }
            model.engine.browser.showWindow = { openWindow(id: "browser") }
        }
    }
}
