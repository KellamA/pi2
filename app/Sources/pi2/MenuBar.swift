import AppKit
import Carbon.HIToolbox
import ComposeKit
import LoginItemKit
import SwiftUI
import WindowKit

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
            TextField("Ask \(engine.agents.first?.name ?? "an agent")…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .sendsOnReturn(ask)
                .disabled(engine.status != .connected)

            if !engine.inbox.isEmpty {
                section("Needs you")
                ForEach(engine.inbox) { InboxCard(engine: engine, item: $0, showsSource: true) }
            }

            section("Running")
            if engine.activity.isEmpty && engine.backgroundCommands.isEmpty && engine.localRunning.isEmpty {
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
                        let atLimit = engine.subChatLimitWaits[run.conversationId]?.count ?? 0
                        let status = run.status == "waiting" ? "waiting" : run.limit?.tag ?? (atLimit > 0 ? "working · \(atLimit) sub-chat\(atLimit == 1 ? "" : "s") at limit" : "working")
                        Text(status).font(.caption).lineLimit(1).foregroundStyle(run.status == "waiting" || run.limit != nil || atLimit > 0 ? Theme.warn : Theme.tx2)
                            .help(run.limit?.sentence ?? LimitWait.subChatsLine(engine.subChatLimitWaits[run.conversationId] ?? []) ?? "")
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            // Models loaded on this Mac: each with Stop, and Activity for the rest.
            ForEach(engine.localRunning) { server in
                LocalServerMenuRow(engine: engine, server: server) { show(.activity) }
            }
            // Commands agents left running in the background: each opens its output.
            ForEach(engine.backgroundCommands) { command in
                Button {
                    openWindow(id: BackgroundOutputScene.id, value: command.id)
                    NSApp.activate()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.tx2).frame(width: 16)
                        Text(oneLine(command.command)).font(Theme.mono).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text("in the background").font(.caption).foregroundStyle(Theme.tx2).fixedSize()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show its output: \(command.command)")
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
                Circle().fill(engine.status == .connected ? Theme.ok : engine.startProblem != nil ? Theme.bad : Theme.warn).frame(width: 8, height: 8)
                    .accessibilityLabel(engine.status == .connected ? "Engine running" : engine.startProblem != nil ? "Engine could not start" : "Engine not running")
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
    private var height: PanelHeight?

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
            let host = NSHostingView(rootView: QuickAskView(
                model: model, close: { [weak self] in self?.close() },
                heightChanged: { [weak self] in self?.height?.want($0) }
            ).tint(.piAccent))
            host.sizingOptions = []
            // Never the panel's content view: a hosting view there sizes the window itself after each layout (#589).
            let content = PanelContent()
            panel.contentView = content
            content.hold(host)
            self.panel = panel
            let engine = model.engine
            let watch = SizeWatch(threshold: SizeWatch.panelThreshold) { [weak engine] in engine?.note($0) }
            watch.start(panel)
            height = PanelHeight(panel: panel, watch: watch)
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
    let heightChanged: (CGFloat) -> Void
    @State private var draft = ""
    @State private var conversationID: Int?
    @FocusState private var focused: Bool
    private var engine: EngineClient { model.engine }

    private var data: OpenConversation? { conversationID.flatMap { engine.open[$0] } }
    /// The newest answer, finished or still streaming.
    private var answer: String? {
        if let partial = data?.state?.partial?.text, !partial.isEmpty { return partial + " ▍" }
        return data?.items.last { $0.kind == "assistant" && !$0.text.isEmpty }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentAvatar(agent: engine.agents.first, size: 22)
                TextField(conversationID == nil ? "Ask anything…" : "Follow up…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...6)
                    .focused($focused)
                    .sendsOnReturn(send)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
        .background(.regularMaterial)
        // The panel has no visible title bar; use the space it would take.
        .ignoresSafeArea()
        .onAppear { focused = true }
        .onExitCommand(perform: close)
        // Kept coming from the engine although no pane shows it, while this panel has it.
        .onChange(of: conversationID, initial: true) { _, id in engine.quickAskConversation = id }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.status == .connected else { return }
        draft = ""
        Task {
            if conversationID == nil { conversationID = await engine.createConversation() }
            if let conversationID, await engine.submit(text, to: conversationID, steer: false) == .refused, draft.isEmpty { draft = text }
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

extension EngineLoginItem {
    static let label = "dev.pi2.engine"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static var current: Item? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let environment = plist["EnvironmentVariables"] as? [String: String]
        return Item(arguments: plist["ProgramArguments"] as? [String] ?? [], home: environment?["PI2_HOME"], processType: plist["ProcessType"] as? String)
    }

    /// The installed item, or nil if there is none. An item that cannot be read serves no data folder.
    static var installedItem: Item? {
        guard installed else { return nil }
        return current ?? Item(arguments: [], home: nil)
    }

    struct Refused: LocalizedError {
        let errorDescription: String?
    }

    /// Throws, saying why, unless `mayChange` allows a copy on `home` to change the item installed now.
    private static func check(home: String) throws {
        if case .unavailable(let why) = switchState(installedItem, home: home) { throw Refused(errorDescription: why) }
    }

    /// Starts the engine through launchd, if it is not running already. False if launchd does not have the item, or
    /// the item starts the engine for another data folder than `home`.
    static func start(home: String) -> Bool {
        guard current?.serves(home: home) == true else { return false }
        return (try? launchctl(["kickstart", "gui/\(getuid())/\(label)"])) == 0
    }

    /// Installs the item for the data folder `home`, replacing the one there if it serves the same folder. Refuses
    /// when this copy may not change the item (see `mayChange`).
    static func install(node: String, main: String, home: String) throws {
        try check(home: home)
        if installed { _ = try? launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [node, main],
            "EnvironmentVariables": ["PI2_HOME": home],
            "RunAtLoad": true,
            // Restart after a crash, but not after a clean stop or when another engine is already running.
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": home + "/engine.log",
            "StandardErrorPath": home + "/engine.log",
            "ProcessType": processType,
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// Removes the item, which stops the engine it started. Refuses unless the item serves the data folder `home`.
    static func remove(home: String) throws {
        guard installed else { return }
        try check(home: home)
        _ = try? launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
