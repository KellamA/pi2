import SwiftUI

/// Everything under the transcript: what went wrong with the last request, what the run is doing, what waits for the
/// person, the chips, and the message field (or, for an archived conversation, the way back).
struct ConversationFooter: View {
    let status: ConversationStatus
    let draft: MessageField?
    let pictures: ConversationPictures
    @Binding var steer: Bool
    let connected: Bool
    /// What the engine said when it refused the screen's last request.
    @Binding var problem: String?
    let send: () -> Void
    let stop: () -> Void
    let withdraw: (Int) -> Void
    let carryOn: () -> Void
    /// Restores the conversation (nil) or the archived one it is a sub-chat of.
    let restore: (Int?) -> Void
    /// Opens Needs you, where what waits is answered.
    let openNeeds: () -> Void

    /// How tall the lines above the chips are; past `notesLimit` they scroll, so that at the largest text sizes the
    /// transcript keeps its room.
    @State private var notesHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var notesLimit: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasNotes {
                ScrollView {
                    notes
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { notesHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(notesHeight, min(notesLimit, 260)))
            }
            if !status.chips.isEmpty {
                ConversationChips(chips: status.chips, withdraw: withdraw)
            }
            if let archived = status.archived {
                archivedBar(archived)
            } else if let draft {
                ConversationComposer(draft: draft, pictures: pictures, status: status, steer: $steer, connected: connected, send: send, stop: stop)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var arrival: String? {
        guard status.busy, status.archived == nil else { return nil }
        return steer ? status.arrivalSteered : status.arrivalQueued
    }

    private var hasNotes: Bool {
        problem != nil || !status.banners.isEmpty || status.failure != nil || !status.waiting.isEmpty || arrival != nil
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                ConversationNote(text: problem, symbol: "exclamationmark.circle.fill", tint: .red, besideOnly: true) {
                    Button("Dismiss", systemImage: "xmark") { self.problem = nil }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(.rect)
                }
            }
            ForEach(status.banners) { banner in
                ConversationNote(text: banner.text, symbol: banner.symbol, tint: banner.tone == .accent ? Color.conversationAccent : .orange) { EmptyView() }
            }
            if let failure = status.failure {
                ConversationNote(text: failure.message, symbol: failure.stopped ? "stop.circle" : "exclamationmark.triangle.fill", tint: failure.stopped ? .secondary : .red) {
                    if failure.canContinue {
                        Button("Continue", systemImage: "play.fill", action: carryOn)
                            .buttonStyle(.bordered)
                            .accessibilityHint("Resumes the run from where it stopped, without a new message.")
                    }
                }
            }
            if !status.waiting.isEmpty {
                waiting
            }
            if let arrival {
                // While it works: what happens to a message sent now, so the person knows before sending.
                Text(arrival)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// What waits for the person in this conversation: answered under Needs you, never in the page (section 8).
    private var waiting: some View {
        Button(action: openNeeds) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.waiting[0].text)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if status.waiting.count > 1 {
                        Text("and \(status.waiting.count - 1) more")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text("Answer")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.conversationAccent)
            }
            .font(.subheadline)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .accessibilityLabel(status.waiting.map(\.text).joined(separator: ". "))
        .accessibilityHint("Opens Needs you, to answer.")
    }

    private func archivedBar(_ archived: ConversationStatus.Archived) -> some View {
        let text: String
        let root: Int?
        switch archived {
        case .itself:
            text = status.isSubChat ? "This sub-chat is archived. You can read it; restore it to carry on." : "This conversation is archived. You can read it; restore it to carry on."
            root = nil
        case .parent(let id):
            text = "This sub-chat belongs to an archived conversation. Restore that conversation to carry on."
            root = id
        }
        return ConversationNote(text: text, symbol: "archivebox", tint: .secondary) {
            Button("Restore") { restore(root) }
                .buttonStyle(.borderedProminent)
                .tint(Color.conversationAccent)
        }
    }
}

/// A line above the message field, with its icon and what can be done about it.
struct ConversationNote<Trailing: View>: View {
    let text: String
    let symbol: String
    let tint: Color
    /// A small control, such as Dismiss, that stays beside the text however long it is.
    var besideOnly = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Group {
            if besideOnly {
                HStack(alignment: .top, spacing: 10) {
                    label
                    Spacer(minLength: 0)
                    trailing()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        label
                        Spacer(minLength: 0)
                        trailing()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        label
                        trailing()
                    }
                }
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var label: some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}
