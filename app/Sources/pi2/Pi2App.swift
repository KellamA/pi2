import SwiftUI

/// What the main window is showing.
enum Selection: Hashable {
    case inbox
    case activity
    case agent(String)
    case conversation(Int)
}

/// App-level UI state.
@MainActor
@Observable
final class AppModel {
    let engine = EngineClient()
    var selection: Selection?
    /// The conversation whose rename prompt is showing.
    var renaming: ConversationSummary?
    var newTitle = ""
    /// The conversation whose delete confirmation is showing.
    var deleting: ConversationSummary?
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
        deleting = conversation
    }

    func confirmDelete() {
        if let deleting { engine.perform("conversation.archive", ["id": deleting.id]) }
        deleting = nil
    }
}

extension Color {
    static let piAccent = Color(red: 0.49, green: 0.47, blue: 0.96)
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
                    QuickAsk.shared.install(model: model)
                }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
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
                Button("Quick Ask (⌃⌥Space anywhere)") { QuickAsk.shared.show(model: model) }
            }
            CommandGroup(after: .sidebar) {
                Button("Show Inbox") { model.selection = .inbox }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Show Activity") { model.selection = .activity }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("Conversation") {
                ConversationCommands(model: model)
            }
            CommandMenu("Debug") {
                Button("Kill Engine (Simulate Crash)") { model.engine.killEngine() }
                    .keyboardShortcut("k", modifiers: [.command, .option, .shift])
            }
        }

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
        NSApp.activate()
    }

    /// Closing the window leaves pi² in the menu bar, so agents keep working and can still reach the person.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting stops the engine cleanly unless the person asked for agents to keep running.
        let keep = UserDefaults.standard.bool(forKey: BackgroundSettings.keepEngineKey) || EngineLoginItem.installed
        if !keep { MainActor.assumeIsolated { engine?.stopEngine() } }
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
            case .agent(let id):
                AgentEditor(model: model, agentID: id)
                    .id(id)
            case .conversation(let id):
                ChatView(engine: engine, id: id)
                    .id(id)
            case nil:
                ContentUnavailableView {
                    Label("No conversation selected", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a new conversation, or pick one from the sidebar.")
                } actions: {
                    Button("New Conversation") { model.newConversation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.status != .connected)
                }
            }
        }
        .background(WindowOpener(model: model))
        .onChange(of: model.selection) { _, selection in
            if case .conversation(let id) = selection { engine.openConversation(id) }
        }
        .onChange(of: engine.hasLoadedLibrary) { _, loaded in
            // On launch, land on the most recent conversation.
            if loaded, model.selection == nil, let first = engine.conversations.first { model.selection = .conversation(first.id) }
        }
        .onChange(of: engine.conversations) { _, list in
            // The conversation on screen was deleted: move to the next one.
            if let id = model.selectedConversationID, engine.hasLoadedLibrary, !list.contains(where: { $0.id == id }) {
                model.selection = list.first.map { .conversation($0.id) }
            }
        }
        .confirmationDialog(
            "Delete “\(model.deleting.map { $0.title.isEmpty ? "New conversation" : $0.title } ?? "")”?",
            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleting = nil }
        } message: {
            Text("Any work it is running will be stopped. This cannot be undone from the app.")
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
            Label {
                HStack {
                    Text("Inbox")
                    Spacer()
                    if !engine.inbox.isEmpty {
                        Text("\(engine.inbox.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(.orange, in: .capsule)
                            .foregroundStyle(.white)
                            .accessibilityLabel("\(engine.inbox.count) waiting")
                    }
                }
            } icon: {
                Image(systemName: engine.inbox.isEmpty ? "tray" : "tray.full")
            }
            .tag(Selection.inbox)

            Label {
                HStack {
                    Text("Activity")
                    Spacer()
                    if engine.recovery != nil {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.green)
                            .help("The engine restarted after stopping unexpectedly")
                            .accessibilityLabel("Engine restarted")
                    }
                    if !engine.activity.isEmpty {
                        Text("\(engine.activity.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                            .accessibilityLabel("\(engine.activity.count) running")
                    }
                }
            } icon: {
                Image(systemName: "waveform.path.ecg")
            }
            .tag(Selection.activity)

            Section {
                ForEach(engine.agents) { agent in
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent)
                        Text(agent.name).lineLimit(1)
                        Spacer()
                        Button("New conversation with \(agent.name)", systemImage: "plus.bubble") {
                            model.newConversation(agentId: agent.id)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New conversation with \(agent.name)")
                    }
                    .tag(Selection.agent(agent.id))
                }
            } header: {
                HStack {
                    Text("Agents")
                    Spacer()
                    Button("New Agent", systemImage: "plus") { model.newAgent() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New agent (⇧⌘N)")
                }
            }

            Section("Conversations") {
                ForEach(engine.conversations) { conversation in
                    HStack(spacing: 8) {
                        if conversation.busy {
                            ProgressView().controlSize(.small)
                                .frame(width: 16)
                                .accessibilityLabel("Working")
                        } else {
                            AgentAvatar(agent: engine.agent(conversation.agentId), size: 16)
                        }
                        Text(conversation.title.isEmpty ? "New conversation" : conversation.title)
                            .lineLimit(1)
                            .foregroundStyle(conversation.title.isEmpty ? .secondary : .primary)
                        Spacer(minLength: 0)
                        if engine.inbox.contains(where: { $0.rootConversationId == conversation.id }) {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                                .accessibilityLabel("Needs you")
                        }
                    }
                    .tag(Selection.conversation(conversation.id))
                    .contextMenu {
                        Button("Rename…") { model.beginRename(conversation) }
                        Button("Delete", role: .destructive) { model.delete(conversation) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }
            .accessibilityElement(children: .contain)
            .padding(.horizontal, 14).padding(.vertical, 10)
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

    private var statusText: String {
        switch engine.status {
        case .connecting: "Starting engine…"
        case .connected: "Engine running"
        case .restarting: "Engine stopped — restarting…"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .connecting: .gray
        case .connected: .green
        case .restarting: .orange
        }
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
        Button("Rename…") { if let conversation = model.selectedConversation { model.beginRename(conversation) } }
            .disabled(model.selectedConversation == nil)
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

/// Hands the app model a way to reopen the main window, from a view that has the environment to do it.
private struct WindowOpener: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear { model.showMainWindow = { openWindow(id: "main") } }
    }
}
