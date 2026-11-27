import AppKit
import EngineKit
import PiModels
import SwiftUI

// Commands agents left running in the background, as the person keeps an eye on them: a window with a command's output,
// and the strip above a conversation's message field that names the ones it has running. See docs/background.md.

/// The Mac's name for EngineKit's `BackgroundOutputFollower`, the one loop the Mac's output window and the phone's
/// command's output screen follow a background command's output with: what it asks, how it waits and how it joins the
/// parts are told there.
typealias BackgroundOutputFeed = BackgroundOutputFollower

/// How the follower asks this app's engine, and hears whether it is connected.
extension BackgroundOutputFollower {
    /// Follows the command until it ends or the task is cancelled (the window closed).
    func follow(_ engine: EngineClient) async {
        await follow(
            { from, wait in
                let result = try await engine.call("background.output", ["id": self.id, "from": from, "wait": wait])
                return try JSONDecoder().decode(BackgroundOutput.self, from: JSONEncoder().encode(result))
            },
            connected: { engine.status == .connected })
    }
}

/// A command's output, in a window of its own: the command, whose it is, how it stands, and what it printed.
struct BackgroundOutputWindow: View {
    let model: AppModel
    let id: String
    @State private var feed: BackgroundOutputFeed
    @State private var stopping = false
    private var engine: EngineClient { model.engine }

    init(model: AppModel, id: String) {
        self.model = model
        self.id = id
        _feed = State(initialValue: BackgroundOutputFeed(id: id))
    }

    /// The command as the Activity row has it, until the engine first answers.
    private var listed: BackgroundCommand? { engine.backgroundCommands.first { $0.id == id } }
    private var commandText: String { feed.latest?.command ?? listed?.command ?? "" }
    private var conversationId: Int? { feed.latest?.conversationId ?? listed?.conversationId }
    private var rootConversationId: Int? { feed.latest?.rootConversationId ?? listed?.rootConversationId }
    private var running: Bool { feed.problem == nil && (feed.latest?.running ?? (listed != nil)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
            Divider().overlay(Theme.line)
            output
        }
        .background(Theme.window)
        .navigationTitle(oneLine(commandText).isEmpty ? id : oneLine(commandText))
        .navigationSubtitle(commandText.isEmpty ? "" : id)
        .task(id: id) { await feed.follow(engine) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(commandText)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.tx)
                    .lineLimit(4).truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(commandText)
                if running {
                    Button("Stop", systemImage: "stop.fill") { stop() }
                        .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
                        .disabled(stopping || feed.latest?.stopping == true)
                        .fixedSize()
                        .help("Stop this command and everything it started")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) { status }
                .font(.system(size: 12))
            HStack(spacing: 6) {
                if let conversationId, let root = rootConversationId {
                    Button(source(conversationId)) {
                        model.openConversation(root)
                        model.showMainWindow()
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.acc)
                    .lineLimit(1).truncationMode(.tail)
                    .help("Open the conversation that started it")
                }
                if let cwd = feed.latest?.cwd ?? listed?.cwd {
                    Text("·").foregroundStyle(Theme.tx3)
                    Text(engine.folderName(cwd)).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.middle)
                        .help(cwd)
                }
            }
            .font(.system(size: 12))
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Running, with how long; or how it ended.
    @ViewBuilder private var status: some View {
        if let problem = feed.problem {
            Tag("not available", .warn)
            Text(problem).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
        } else if let ended = feed.latest?.ended {
            // One the engine's stop cut off is not said to have failed: nothing of it went wrong that pi² saw.
            let failed = ended.failed && feed.latest?.kept == true
            Tag(failed ? "failed" : "ended", failed ? .bad : .neutral).fixedSize()
            Text("It \(ended.how).").foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
        } else if stopping || feed.latest?.stopping == true {
            Tag("stopping", .warn).fixedSize()
        } else if let startedAt = feed.latest?.startedAt ?? listed?.startedAt {
            Tag("running", .acc).fixedSize()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("for \(runningTime(since: startedAt, until: context.date))").monospacedDigit().foregroundStyle(Theme.tx2)
            }
            .fixedSize()
        } else {
            Tag("loading", .neutral).fixedSize()
        }
    }

    /// What the output area does not show, said above it.
    private var note: String? {
        guard let latest = feed.latest else { return nil }
        if !latest.kept { return "Its output was in pi²’s engine when it stopped, and was not kept." }
        if feed.notShown > 0 {
            return "The first \(feed.notShown.formatted()) characters it printed are not shown: pi² keeps only the last 128 KB of a command’s output."
        }
        return nil
    }

    @ViewBuilder private var output: some View {
        if let latest = feed.latest, feed.text.isEmpty {
            Text(!latest.kept ? "" : latest.running ? "It has printed nothing yet." : "It printed nothing.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.tx3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            OutputText(text: feed.text, replaced: feed.replaced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func source(_ conversationId: Int) -> String {
        let conversation = engine.conversations.first { $0.id == conversationId }
        let title = conversation?.title ?? ""
        let agent = engine.agent(conversation?.agentId)?.name
        return [title.isEmpty ? "New conversation" : title, agent].compactMap(\.self).joined(separator: " · ")
    }

    private func stop() {
        stopping = true
        Task {
            do { try await engine.call("background.stop", ["id": id]) } catch {
                // Already over: the next answer says how.
                stopping = false
            }
        }
    }
}

/// The command on one line, for a title or a row.
func oneLine(_ command: String) -> String {
    command.split(whereSeparator: \.isNewline).joined(separator: " ")
}

/// "0:42", "12:05", "2h 5m": how long since `start` (milliseconds since 1970).
func runningTime(since start: Double, until now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince1970 - start / 1000))
    if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Output as plain text, in a text view that can be selected and copied from, and that follows the end as more arrives
/// while it is scrolled to the end. Nothing in it is interpreted: it is whatever a program printed.
private struct OutputText: NSViewRepresentable {
    let text: String
    let replaced: Int

    final class Coordinator {
        var replaced = -1
        /// How much of `text` is in the view, in UTF-16 units.
        var shown = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.importsGraphics = false
            view.allowsUndo = false
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 14, height: 12)
            view.isAutomaticLinkDetectionEnabled = false
            view.isAutomaticDataDetectionEnabled = false
            view.font = Self.font
            view.textColor = NSColor(Theme.tx)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let coordinator = context.coordinator
        let units = text.utf16.count
        // Whether the end is in sight: then it stays in sight as more comes.
        let atEnd = scroll.contentView.bounds.maxY >= view.frame.height - 24
        if coordinator.replaced != replaced || units < coordinator.shown {
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        } else if units > coordinator.shown {
            let start = text.utf16.index(text.utf16.startIndex, offsetBy: coordinator.shown)
            storage.append(NSAttributedString(string: String(text[start...]), attributes: Self.attributes))
        } else {
            return
        }
        coordinator.replaced = replaced
        coordinator.shown = units
        if atEnd { view.scrollToEndOfDocument(nil) }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor(Theme.tx)] }
}

/// The commands a conversation has running in the background, above its message field: each with a way to its output
/// and Stop. Nothing when there are none. A sub-chat's commands show in the conversation it belongs to as well.
struct BackgroundStrip: View {
    let engine: EngineClient
    let id: Int
    var inset: CGFloat = 28
    @Environment(\.openWindow) private var openWindow

    private var commands: [BackgroundCommand] {
        engine.backgroundCommands.filter { $0.conversationId == id || $0.rootConversationId == id }
    }

    var body: some View {
        let commands = commands
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(commands.count == 1 ? "Running in the background" : "\(commands.count) commands running in the background")
                    .font(Theme.label).foregroundStyle(Theme.tx3)
                    .textCase(.uppercase)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(commands) { command in
                            BackgroundStripRow(engine: engine, command: command, fromSubChat: command.conversationId != id) {
                                openWindow(id: BackgroundOutputScene.id, value: command.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 96)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .panel(radius: 10, fill: Theme.card, border: Theme.line2)
            .padding(.horizontal, inset).padding(.top, 8)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: commands)
        }
    }
}

private struct BackgroundStripRow: View {
    let engine: EngineClient
    let command: BackgroundCommand
    let fromSubChat: Bool
    let showOutput: () -> Void
    /// Set when Stop was pressed: the row stays until the engine says the command is gone.
    @State private var stopping = false

    private var subChat: String? {
        guard fromSubChat else { return nil }
        let title = engine.conversations.first { $0.id == command.conversationId }?.title ?? ""
        return title.isEmpty ? "a sub-chat" : "sub-chat “\(title)”"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.tx2)
            Text(oneLine(command.command))
                .font(Theme.mono).foregroundStyle(Theme.tx)
                .lineLimit(1).truncationMode(.tail)
                .help(subChat.map { "Started in \($0): \(command.command)" } ?? command.command)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subChat {
                Text("in \(subChat)").font(.system(size: 11.5)).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            Tag(stopping ? "stopping" : command.id, stopping ? .warn : .neutral).fixedSize()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(runningTime(since: command.startedAt, until: context.date))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tx2)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .fixedSize()
            Button("Output", action: showOutput)
                .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
                .help("Show what it has printed, as it prints it")
            Button("Stop", systemImage: "stop.fill") {
                stopping = true
                engine.perform("background.stop", ["id": command.id])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
            .disabled(stopping)
            .fixedSize()
            .help("Stop this command and everything it started")
        }
        .font(.system(size: 12.5))
    }
}

/// The window scene for a command's output, opened with `openWindow(id: BackgroundOutputScene.id, value: <command id>)`.
enum BackgroundOutputScene {
    static let id = "background-output"
}
