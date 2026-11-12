import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The menu bar popover: what needs the person, what is running, what is next, and a quick way to ask.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @Environment(\.openWindow) private var openWindow
    private var engine: EngineClient { model.engine }

    private var nextSchedule: Schedule? {
        engine.schedules.filter { $0.enabled && $0.nextRunAt != nil }.min { ($0.nextRunAt ?? 0) < ($1.nextRunAt ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask \(engine.agents.first?.name ?? "an agent")…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)
                .disabled(engine.status != .connected)

            if !engine.inbox.isEmpty {
                section("Needs you")
                ForEach(engine.inbox) { InboxCard(engine: engine, item: $0, showsSource: true) }
            }

            section("Running")
            if engine.activity.isEmpty {
                Text("Nothing is running.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(engine.activity.filter { $0.parent == nil }) { run in
                Button {
                    show(.conversation(run.conversationId))
                } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: engine.agent(run.agentId), size: 16)
                        Text(run.title.isEmpty ? "New conversation" : run.title).lineLimit(1)
                        Spacer()
                        Text(run.status == "waiting" ? "waiting" : "working").font(.caption).foregroundStyle(run.status == "waiting" ? Theme.warn : Theme.tx2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if let next = nextSchedule, let at = next.nextRunAt {
                section("Next up")
                HStack {
                    Text(next.title).lineLimit(1)
                    Spacer()
                    Text(Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Button("Open pi²") { show(nil) }
                Button("Quick Ask") { QuickAsk.shared.show(model: model) }
                Spacer()
                Circle().fill(engine.status == .connected ? Theme.ok : Theme.warn).frame(width: 8, height: 8)
                    .accessibilityLabel(engine.status == .connected ? "Engine running" : "Engine not running")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.showMainWindow = { openWindow(id: "main") } }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func show(_ selection: Selection?) {
        if let selection { model.selection = selection }
        openWindow(id: "main")
        NSApp.activate()
    }

    private func ask() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            guard let id = await engine.createConversation() else { return }
            await engine.submit(text, to: id, steer: false)
            show(.conversation(id))
        }
    }
}

// MARK: - Quick Ask

/// A small floating prompt, opened from anywhere with a global shortcut. The answer streams in place.
@MainActor
final class QuickAsk {
    static let shared = QuickAsk()
    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?

    /// Registers ⌃⌥Space system-wide.
    func install(model: AppModel) {
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggle(model: model)
        }
    }

    func toggle(model: AppModel) {
        if panel?.isVisible == true { close() } else { show(model: model) }
    }

    func show(model: AppModel) {
        if panel == nil {
            let panel = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 120),
                styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.title = "Quick Ask"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: QuickAskView(model: model) { [weak self] in self?.close() }.tint(.piAccent))
            self.panel = panel
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        panel?.orderOut(nil)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickAskView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @State private var draft = ""
    @State private var conversationID: Int?
    @FocusState private var focused: Bool
    private var engine: EngineClient { model.engine }

    private var data: ConversationData? { conversationID.flatMap { engine.open[$0] } }
    /// The newest answer, finished or still streaming.
    private var answer: String? {
        if let partial = data?.state?.partial?.text, !partial.isEmpty { return partial + " ▍" }
        return data?.items.last { $0.kind == "assistant" && !$0.text.isEmpty }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentAvatar(agent: engine.agents.first, size: 22)
                TextField(conversationID == nil ? "Ask anything…" : "Follow up…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(send)
                    .accessibilityIdentifier("quick-ask-field")
                if data?.state?.busy == true { ProgressView().controlSize(.small) }
            }
            if let conversationID {
                Divider()
                ForEach(engine.inbox.filter { $0.rootConversationId == conversationID }) {
                    InboxCard(engine: engine, item: $0, showsSource: false)
                }
                ScrollView {
                    Group {
                        if let answer { MessageText(text: answer) } else { Text("Thinking…").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .defaultScrollAnchor(.bottom)
                HStack {
                    Button("Open in pi²") {
                        model.selection = .conversation(conversationID)
                        model.showMainWindow()
                        NSApp.activate()
                        close()
                    }
                    Button("New Question") {
                        self.conversationID = nil
                        draft = ""
                    }
                    Spacer()
                    Text("esc to close").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        // The panel has no visible title bar; use the space it would take.
        .ignoresSafeArea()
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.status == .connected else { return }
        draft = ""
        Task {
            if conversationID == nil { conversationID = await engine.createConversation() }
            if let conversationID, await !engine.submit(text, to: conversationID, steer: false), draft.isEmpty { draft = text }
        }
    }
}

/// A system-wide keyboard shortcut. Needs no special permission.
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    @MainActor private static var action: (() -> Void)?

    @MainActor
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x7069_3251), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }
}

// MARK: - Starting the engine at login

/// A per-user launchd agent that starts the engine at login and restarts it if it crashes, so schedules and long
/// runs keep going without the app open.
enum EngineLoginItem {
    static let label = "dev.pi2.engine"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func install(node: String, main: String, home: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [node, main],
            "EnvironmentVariables": ["PI2_HOME": home],
            "RunAtLoad": true,
            // Restart after a crash, but not after a clean stop or when another engine is already running.
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": home + "/engine.log",
            "StandardErrorPath": home + "/engine.log",
            "ProcessType": "Background",
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func remove() {
        try? launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }
}
