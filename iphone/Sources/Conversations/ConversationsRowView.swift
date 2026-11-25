import SwiftUI

/// One conversation in a list: its agent's mark (a chat's bubble for a chat), its title, who it is with and how it
/// stands, and when it last changed or a spinner while its agent works (the projects list's drawing: a row of the chats).
struct ConversationsRowView: View {
    let row: ConversationsRow
    /// The time on the right; nil to leave it out.
    var time: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ConversationsRowStack {
            ConversationsMark(chat: row.chat, name: row.agentName, color: row.agentColor)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if row.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(row.shownTitle)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                        .foregroundStyle(.primary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                }
            }
        } trailing: {
            if row.busy {
                ProgressView()
                    .accessibilityHidden(true)
            } else if let time, !typeSize.isAccessibilitySize {
                Text(time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityValue(time.map { "changed \($0)" } ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// A row's mark, its words and what goes on its right: side by side, or at the accessibility text sizes the mark and the
/// right-hand part on a line of their own above the words, which then have the row's whole width.
struct ConversationsRowStack<Leading: View, Content: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    leading
                    Spacer(minLength: 8)
                    trailing
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 12) {
                leading
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
        }
    }
}

/// An agent's mark, or for a chat the bubble chat mode's switch uses, since a chat has no agent.
struct ConversationsMark: View {
    let chat: Bool
    let name: String?
    let color: String?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    var body: some View {
        if chat {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: min(side, 42) * 0.45))
                .foregroundStyle(Color.pi2Accent)
                .frame(width: min(side, 42), height: min(side, 42))
                .background(Color.pi2Accent.opacity(0.15), in: RoundedRectangle(cornerRadius: min(side, 42) * 0.28, style: .continuous))
                .accessibilityHidden(true)
        } else {
            AgentMark(name: name, color: color)
        }
    }
}

/// A request's refusal or failure, said where it was asked, in the engine's own words, with a way to put it away.
struct ConversationsProblemRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problem: \(message)")
    }
}

/// When a screen that asks the Mac for something as it opens (the folders offered, a file) asks again: the client is
/// connected, and to the Mac itself or the demo rather than to the phone's last state. At launch a paired phone's client
/// starts on what the Mac last sent (`CachedTransport`), which refuses every request, and moves to the Mac once it is
/// reached, its status `connected` throughout.
struct ConversationsReach: Hashable {
    /// What else the screen's asking depends on, such as the command whose output it follows.
    var key = ""
    let connected: Bool
    let live: Bool

    /// Connected to the Mac itself, or the demo.
    var ready: Bool { connected && live }

    @MainActor init(_ session: AppSession, for key: String = "") {
        self.key = key
        connected = session.engine.status == .connected
        switch session.connection {
        case .connected, .demo: live = true
        case .notPaired, .connecting, .outOfReach: live = false
        }
    }
}

/// What a screen shows while the Mac's lists have not come yet.
struct ConversationsWaiting: View {
    var body: some View {
        ProgressView("Waiting for your Mac…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
