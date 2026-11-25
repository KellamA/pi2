import EngineKit
import PiModels
import SwiftUI
import UIKit

/// A command's output, on a screen of its own (docs/design/iphone.md, "An agent's conversation": a long output, opened):
/// the command, whose it is, how it stands, and what it printed, followed as it prints, with Copy and Stop. The Mac's
/// output window (`BackgroundOutputWindow`), laid out for a phone.
struct BackgroundCommandsOutputPage: View {
    let id: String

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var feed: BackgroundCommandsFeed
    @State private var stopping = false
    @State private var stopProblem: String?
    @State private var copied = false

    init(id: String) {
        self.id = id
        #if DEBUG
        if let sample = ConversationsSample.current?.output(id) {
            _feed = State(initialValue: BackgroundCommandsFeed(id: id, showing: sample))
            return
        }
        #endif
        _feed = State(initialValue: BackgroundCommandsFeed(id: id))
    }

    private var engine: EngineSession<MessageField> { session.engine }

    private var isSample: Bool {
        #if DEBUG
        return ConversationsSample.current?.output(id) != nil
        #else
        return false
        #endif
    }

    /// The command as the list has it, until the engine first answers.
    private var listed: BackgroundCommand? { engine.backgroundCommands.first { $0.id == id } }
    private var commandText: String { feed.latest?.command ?? listed?.command ?? "" }
    private var conversationId: Int? { feed.latest?.conversationId ?? listed?.conversationId }
    private var rootConversationId: Int? { feed.latest?.rootConversationId ?? listed?.rootConversationId }
    private var running: Bool { feed.problem == nil && (feed.latest?.running ?? (listed != nil)) }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                // The header scrolls by itself past two fifths of the screen, so that the output always has the rest,
                // at the largest text sizes too.
                ScrollView {
                    header
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .frame(maxHeight: geometry.size.height * 0.4)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                output
            }
        }
        .navigationTitle(id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = feed.text
                    copied = true
                }
                .disabled(feed.text.isEmpty)
                if running {
                    Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                        .disabled(stopping || feed.latest?.stopping == true)
                        .tint(.red)
                }
            }
        }
        // Followed again when the client moves from the phone's last state, which refuses, to the Mac itself.
        .task(id: ConversationsReach(session, for: id)) {
            guard !isSample else { return }
            await feed.follow(engine)
        }
        #if DEBUG
        .task(id: id) {
            if await ConversationsSample.take("stop", in: session) { stop() }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSample {
                ConversationsSampleNote()
            }
            Text(commandText.isEmpty ? id : commandText)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Command: \(commandText)")
            status
                .font(.subheadline)
            if let conversationId, let root = rootConversationId {
                Button {
                    openRoute(.conversation(root))
                } label: {
                    Label(BackgroundCommandsRow.source(conversationId, conversations: engine.conversations, agents: engine.allAgents),
                          systemImage: "bubble.left")
                        .multilineTextAlignment(.leading)
                }
                .font(.subheadline)
                .accessibilityHint("Opens the conversation that started it")
            }
            if let cwd = feed.latest?.cwd ?? listed?.cwd {
                Label((cwd as NSString).lastPathComponent, systemImage: "folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Folder: \((cwd as NSString).lastPathComponent)")
            }
            if let note = feed.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stopProblem {
                ConversationsProblemRow(message: "It was not stopped: \(stopProblem)") { self.stopProblem = nil }
            }
        }
    }

    /// Running, with how long; or how it ended; or why it cannot be shown.
    @ViewBuilder private var status: some View {
        if let problem = feed.problem {
            BackgroundCommandsStatus(tag: "not available", tone: .orange, text: problem)
        } else if let ended = feed.latest?.ended {
            // One the engine's stop cut off is not said to have failed: nothing of it went wrong that pi² saw.
            let failed = ended.failed && feed.latest?.kept == true
            BackgroundCommandsStatus(tag: failed ? "failed" : "ended", tone: failed ? .red : .secondary, text: "It \(ended.how).")
        } else if stopping || feed.latest?.stopping == true {
            BackgroundCommandsStatus(tag: "stopping", tone: .orange, text: nil)
        } else if let startedAt = feed.latest?.startedAt ?? listed?.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                BackgroundCommandsStatus(tag: "running", tone: Color.pi2Accent,
                                         text: "for \(BackgroundCommandsClock.text(since: startedAt, until: context.date))",
                                         spoken: "running for \(BackgroundCommandsClock.spoken(since: startedAt, until: context.date))")
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Asking your Mac…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var output: some View {
        if let latest = feed.latest, feed.text.isEmpty {
            Text(!latest.kept ? "" : latest.running ? "It has printed nothing yet." : "It printed nothing.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feed.latest == nil, feed.problem != nil {
            ContentUnavailableView(
                "No output to show", systemImage: "terminal",
                description: Text("Your Mac did not send this command's output. It may have ended and been forgotten, or the connection may not carry it yet.")
            )
        } else {
            BackgroundCommandsOutputText(text: feed.text, replaced: feed.replaced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Output")
        }
    }

    private func stop() {
        stopping = true
        Task {
            if let failure = await ConversationsRequests.stopCommand(engine, command: id) {
                // Already over, or refused: the next answer says how it stands.
                stopping = false
                stopProblem = failure
            }
        }
    }
}

/// How a command stands: a word in a tag, and a line beside it.
private struct BackgroundCommandsStatus: View {
    let tag: String
    let tone: Color
    let text: String?
    var spoken: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tag)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tone.opacity(0.18), in: Capsule())
                .foregroundStyle(tone)
                .fixedSize()
            if let text {
                Text(text)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? [tag, text].compactMap(\.self).joined(separator: ", "))
    }
}

/// Output as plain text, in a text view that can be selected and copied from, and that follows the end as more arrives
/// while it is scrolled to the end. Nothing in it is interpreted: it is whatever a program printed. Its monospaced font
/// follows the person's text size.
private struct BackgroundCommandsOutputText: UIViewRepresentable {
    let text: String
    let replaced: Int

    final class Coordinator {
        var replaced = -1
        /// How much of `text` is in the view, in UTF-16 units.
        var shown = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let units = text.utf16.count
        // Whether the end is in sight: then it stays in sight as more comes. The first output shows its end, as a
        // running command's newest lines are what the person came for.
        let atEnd = coordinator.shown == 0 || view.contentOffset.y + view.bounds.height >= view.contentSize.height - 24
        if coordinator.replaced != replaced || units < coordinator.shown {
            view.text = text
        } else if units > coordinator.shown {
            let start = text.utf16.index(text.utf16.startIndex, offsetBy: coordinator.shown)
            view.textStorage.append(NSAttributedString(string: String(text[start...]), attributes: [.font: Self.font, .foregroundColor: UIColor.label]))
        } else {
            return
        }
        coordinator.replaced = replaced
        coordinator.shown = units
        if atEnd, units > 0 {
            // Once the text is laid out at the view's size, which the first time is after this pass.
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
                view.setContentOffset(CGPoint(x: 0, y: max(-view.adjustedContentInset.top, bottom)), animated: false)
            }
        }
    }

    private static var font: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }
}
