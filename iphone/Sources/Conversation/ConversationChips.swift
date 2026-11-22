import SwiftUI

/// The messages on their way and in the conversation's queue, in a row above the message field, as on the Mac: one
/// sent shows at once that it was taken; one queued can be taken back before the model reads it.
struct ConversationChips: View {
    let chips: [ConversationStatus.Chip]
    /// Takes back a queued message, by its submission.
    let withdraw: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    ConversationChip(chip: chip, withdraw: withdraw)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }
}

private struct ConversationChip: View {
    let chip: ConversationStatus.Chip
    let withdraw: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                switch chip.kind {
                case .sending:
                    ProgressView()
                        .controlSize(.mini)
                case .sent:
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                case .queued:
                    EmptyView()
                }
                Text(chip.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(chip.summary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(chip.label): \(chip.summary)")
            if case .queued(let submission) = chip.kind {
                Button {
                    withdraw(submission)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take back")
                .accessibilityHint("Removes this message before it is sent to the model.")
            }
        }
        .font(.footnote)
        .padding(.leading, 10)
        .padding(.trailing, isQueued ? 2 : 10)
        .padding(.vertical, isQueued ? 0 : 6)
        .background(.fill.tertiary, in: Capsule())
    }

    private var isQueued: Bool {
        if case .queued = chip.kind { true } else { false }
    }
}
