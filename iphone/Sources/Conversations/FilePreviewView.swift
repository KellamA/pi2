
import EngineKit
import PiModels
import SwiftUI
import UIKit

/// A text file a conversation's agent linked to, shown on the phone (docs/iphone.md 4.2 and 5.7: `files.preview`), opened
/// from a file link in the conversation's transcript, where the Mac shows the file in Finder. The phone cannot browse the
/// Mac's disk: it names the conversation and the link's target as the answer wrote it, and the engine decides whether
/// that file may be shown (linked from one of the agent's answers, under the conversation's folder once links are
/// followed, not ignored by git, UTF-8 text of at most 256 KB). When it refuses, the screen says why in the engine's own
/// words, which never hold a path.
struct FilePreviewView: View {
    /// The conversation whose answer linked to the file, as `ConversationSummary.id`.
    let conversationID: Int
    /// The link's target as the answer wrote it: a path relative to the conversation's folder, an absolute one, `~/…`
    /// or a `file:` address. The engine makes it whole.
    let path: String

    init(conversationID: Int, path: String) {
        self.conversationID = conversationID
        self.path = path
    }

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var preview: FilePreviewState = .asking
    @State private var copied = false

    private var engine: EngineSession<MessageField> { session.engine }

    var body: some View {
        Group {
            if engine.status != .connected, case .asking = preview {
                ConversationsWaiting()
            } else {
                content
            }
        }
        .navigationTitle(FilePreview.name(of: path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .shown(let file) = preview {
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = file.text
                        copied = true
                    }
                    .disabled(file.text.isEmpty)
                }
            }
        }
        // Asked once the client is connected, and again when it moves from the phone's last state (the Mac out of reach,
        // which refuses) to the Mac itself, while nothing is shown.
        .task(id: ConversationsReach(session)) {
            guard engine.status == .connected else { return }
            if case .shown = preview { return }
            await ask()
        }
    }

    @ViewBuilder private var content: some View {
        switch preview {
        case .asking:
            ProgressView("Asking your Mac for the file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let why):
            ScrollView {
                VStack(spacing: 16) {
                    ContentUnavailableView {
                        Label("Not shown on your iPhone", systemImage: "doc.badge.ellipsis")
                    } description: {
                        Text(why)
                    }
                    Text(path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityLabel("Link: \(path)")
                    HStack(spacing: 12) {
                        Button("Try Again") { Task { await ask() } }
                            .buttonStyle(.bordered)
                            .disabled(engine.status != .connected)
                        Button("Open the Conversation") { openRoute(.conversation(conversationID)) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        case .shown(let file):
            VStack(alignment: .leading, spacing: 0) {
                header(file)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if file.text.isEmpty {
                    Text("The file is empty.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FilePreviewText(text: file.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Contents of \(FilePreview.name(of: path))")
                }
            }
        }
    }

    private func header(_ file: FilePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Link: \(path)")
            Text(file.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ask() async {
        preview = .asking
        copied = false
        switch await ConversationsRequests.preview(engine, conversation: conversationID, path: path) {
        case .success(let file): preview = .shown(file)
        case .failure(let failure): preview = .refused(failure.message)
        }
    }
}

/// What `files.preview` answers: the file's text and its size in bytes (`engine/src/folders.ts`, `previewFile`).
struct FilePreview: Decodable, Equatable {
    let text: String
    let size: Int

    /// "12 lines · 1.4 KB, as it is on your Mac now".
    var detail: String {
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(lines == 1 ? "1 line" : "\(lines) lines") · \(bytes), as it is on your Mac now"
    }

    /// The last name of a link's target, for the screen's title: `notes/plan.md` is "plan.md".
    static func name(of path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("file:"), let url = URL(string: text) { text = url.path }
        let name = text.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "File" : name
    }
}

/// The file while it is asked for, as shown, or why it is not.
enum FilePreviewState: Equatable {
    case asking
    case shown(FilePreview)
    case refused(String)
}

/// A file's text, plain and selectable, in a monospaced font that follows the person's text size, from its top. Nothing
/// in it is interpreted: no link, no Markdown, no data detector.
private struct FilePreviewText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.text = text
    }
}
