import SwiftUI

/// App-level UI state: which conversation is on screen.
@MainActor
@Observable
final class AppModel {
    let engine = EngineClient()
    var selection: Int?
    /// The conversation whose rename prompt is showing.
    var renaming: ConversationSummary?
    var newTitle = ""

    var selectedConversation: ConversationSummary? {
        engine.conversations.first { $0.id == selection }
    }

    func beginRename(_ conversation: ConversationSummary) {
        newTitle = conversation.title
        renaming = conversation
    }

    /// The conversation whose delete confirmation is showing.
    var deleting: ConversationSummary?

    func delete(_ conversation: ConversationSummary) {
        deleting = conversation
    }

    func confirmDelete() {
        if let deleting { engine.perform("conversation.archive", ["id": deleting.id]) }
        deleting = nil
    }

    func newConversation() {
        Task {
            if let id = await engine.createConversation() { selection = id }
        }
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
                .frame(minWidth: 760, minHeight: 480)
                .tint(.piAccent)
                .onAppear {
                    delegate.engine = model.engine
                    model.engine.start()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.newConversation() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Conversation") {
                ConversationCommands(model: model)
            }
            CommandMenu("Debug") {
                Button("Kill Engine (Simulate Crash)") { model.engine.killEngine() }
                    .keyboardShortcut("k", modifiers: [.command, .option, .shift])
            }
        }

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.stopEngine() }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            if let id = model.selection, engine.conversations.contains(where: { $0.id == id }) || engine.open[id] != nil {
                ChatView(engine: engine, id: id)
                    .id(id)
            } else {
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
        .onChange(of: model.selection) { _, id in
            if let id { engine.openConversation(id) }
        }
        .onChange(of: engine.hasLoadedLibrary) { _, loaded in
            // On launch, land on the most recent conversation.
            if loaded, model.selection == nil, let first = engine.conversations.first { model.selection = first.id }
        }
        .onChange(of: engine.conversations) { _, list in
            if let id = model.selection, !list.contains(where: { $0.id == id }) { model.selection = list.first?.id }
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
            Section("Conversations") {
                ForEach(engine.conversations) { conversation in
                    HStack(spacing: 8) {
                        if conversation.busy {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Working")
                        }
                        Text(conversation.title.isEmpty ? "New conversation" : conversation.title)
                            .lineLimit(1)
                            .foregroundStyle(conversation.title.isEmpty ? .secondary : .primary)
                    }
                    .tag(conversation.id)
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
    private var state: ConversationState? { model.selection.flatMap { engine.open[$0]?.state } }

    var body: some View {
        let id = model.selection
        Picker("Tool Access", selection: Binding(
            get: { state?.agent.access ?? "none" },
            set: { value in if let id { engine.setAccess(value, for: id) } }
        )) {
            Text("Tools Off").tag("none")
            Text("Read Files").tag("read")
            Text("Full Access").tag("full")
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
