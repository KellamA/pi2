import SwiftUI
import UIKit

/// pi²'s page in the share sheet (docs/design/iphone.md, "What a phone adds"): what is being shared, where it goes (a
/// project's orchestrator, an agent's conversation or a chat), a line of instructions, and Send, which hands the message
/// to the app to send (`ShareModel.send`). In this shared folder so that the app can draw it too.
struct SharePage: View {
    @Bindable var model: ShareModel
    /// Closes the share sheet: `true` once the message is kept for the app.
    let finish: (Bool) -> Void

    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            Form {
                if model.isSample {
                    Section {
                        Label("A sample, for a picture of this page: nothing here was shared by another app, and nothing came from your Mac.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                sharing
                if model.destinations?.destinations.isEmpty == false {
                    Section("Instructions") {
                        TextField("Add a line of instructions (optional)", text: $model.instructions, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($writing)
                            .accessibilityLabel("Instructions")
                    }
                }
                destination
                if let problem = model.sendProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Send to pi²")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        if model.send() { finish(true) }
                    }
                    .disabled(!model.canSend)
                    .accessibilityHint("Gives it to pi², which sends it to your Mac.")
                }
            }
        }
        .tint(.shareAccent)
    }

    // MARK: - What is shared

    @ViewBuilder
    private var sharing: some View {
        Section("Sharing") {
            switch model.loading {
            case .reading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading what was shared…")
                        .foregroundStyle(.secondary)
                }
            case .ready(let content):
                if content.pieces.isEmpty {
                    Label("Nothing was shared that pi² can send.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                ForEach(Array(content.pieces.enumerated()), id: \.offset) { _, piece in
                    SharePieceRow(piece: piece)
                }
            }
        }
    }

    // MARK: - Where it goes

    @ViewBuilder
    private var destination: some View {
        if let list = model.destinations?.destinations, !list.isEmpty {
            Section {
                ForEach(list) { place in
                    Button {
                        model.choice = place
                    } label: {
                        ShareDestinationRow(destination: place, chosen: model.choice == place)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.choice == place ? .isSelected : [])
                }
            } header: {
                Text(model.destinations?.macName.map { "To, on \($0)" } ?? "To")
            } footer: {
                Text(how)
            }
        } else {
            Section("To") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("pi² doesn’t know your Mac’s projects yet.")
                        .font(.headline)
                    Text("Open pi² while it can reach your Mac, then share this again.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// When it goes, said plainly: the extension writes it, the app sends it.
    private var how: String {
        let words = model.content.flatMap { ShareMessage.compose(instructions: model.instructions, content: $0) }
        let onlyWords = words.map { $0.attachments.isEmpty && $0.text.count <= ShareLimits.mailboxCharacters } ?? true
        return onlyWords
            ? "pi² sends it the next time you open it. If your Mac can’t be reached then, it waits in the Outbox until it can."
            : "pi² sends it the next time you open it. A photo or a file goes only while your Mac can be reached; until then it waits on this iPhone, for a day at most."
    }
}

/// One thing shared, as the page lists it.
struct SharePieceRow: View {
    let piece: ShareContent.Piece

    var body: some View {
        switch piece {
        case .link(let url, let title):
            row(symbol: "link", title: title ?? url.host() ?? url.absoluteString, detail: url.absoluteString)
        case .text(let text):
            row(symbol: "text.quote", title: String(text.prefix(300)), detail: ShareMessage.inline(text) ? nil : "Goes as an attachment: \(text.count.formatted()) characters", lines: 4)
        case .file(let name, let text):
            row(symbol: "doc.text", title: name, detail: "Its text, \(text.utf16.count.formatted()) characters")
        case .picture(let picture):
            HStack(spacing: 12) {
                if let image = UIImage(data: picture.thumbnail) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(picture.name)
                    Text("\(picture.width) × \(picture.height) · \(picture.data.count.formatted(.byteCount(style: .file)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .problem(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func row(symbol: String, title: String, detail: String?, lines: Int = 2) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(lines)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.shareAccent)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A place a share can go, with a check when it is the one chosen.
struct ShareDestinationRow: View {
    let destination: ShareDestination
    let chosen: Bool
    /// The symbol's column, growing with the text so that a large symbol does not run into the words.
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.shareAccent)
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.label)
                Text(destination.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if chosen {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.shareAccent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch destination.kind {
        case .orchestrator: "point.3.connected.trianglepath.dotted"
        case .agent: "person.crop.circle"
        case .chat: "bubble.left"
        }
    }
}

extension Color {
    /// pi²'s accent, as the app's root sets it (`Color.pi2Accent` in `App/Shared/`, which an extension cannot build): the
    /// two should become one, in a folder both build.
    static let shareAccent = Color(uiColor: UIColor { traits in
        let hex: UInt32 = traits.userInterfaceStyle == .dark ? 0x8B93FF : 0x5B62E8
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    })
}
