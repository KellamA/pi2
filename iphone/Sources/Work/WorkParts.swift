import PiModels
import SwiftUI

// The parts the list and a piece of work both draw: a state's tag, how long ago, a row of the list, the agent who has a
// piece, and the line that says what the engine refused. System components and semantic colours, as the design asks.

/// A state's tag, as the design's list draws it: the state's word on a tint of its colour, with a dot of it, so that
/// the word reads in both appearances and the colour is never the only sign.
struct WorkTag: View {
    let words: String
    let color: Color
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 6
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: dot, height: dot)
            Text(words)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: dot * 1.6, style: .continuous))
        // One line where it fits; at the largest sizes it may wrap rather than push the row past the screen's edge.
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
    }

    /// A state's tag: open grey, in progress the accent, waiting orange, blocked red, done green, dropped grey.
    init(state: String) {
        words = WorkState.name(state).lowercased()
        color = switch state {
        case "in_progress": .pi2Accent
        case "waiting": .orange
        case "blocked": .red
        case "done": .green
        default: .gray
        }
    }

    /// A pull request's tag: "PR · ready", "PR · checks failing", "PR · merged".
    init(pull: WorkPull) {
        words = "PR · \(pull.standing)"
        color = switch pull.standing {
        case "ready": .pi2Accent
        case "checks failing", "conflicts", "changes asked": .red
        case "checks running": .orange
        case "merged": .green
        default: .gray
        }
    }

    init(words: String, color: Color) {
        self.words = words
        self.color = color
    }
}

/// "5 min ago", kept current while the screen stays open.
struct WorkAgo: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(WorkTime.ago(date, now: context.date))
        }
    }
}

/// Side by side, or one under another at the largest text sizes, where a line cannot hold them.
struct WorkFlow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout { content }
    }
}

/// The agent who has a piece, by its mark and name; "Nobody has it" when nobody does.
struct WorkHolder: View {
    let agent: AgentProfile?
    let agentId: String?

    var body: some View {
        if let agentId {
            HStack(spacing: 5) {
                AgentMark(agent: agent, size: 16, maximum: 24, relativeTo: .footnote)
                Text(agent?.name ?? agentId)
            }
        } else {
            Text("Nobody has it")
        }
    }
}

/// One piece of work (or issue) in the list: its number and title, its state's tag, who has it or the change on its way,
/// and Give for one nobody has. Tapping it opens it.
struct WorkItemRow: View {
    let item: WorkItem
    let holder: AgentProfile?
    /// The change on its way, in a word ("Closing").
    let pending: String?
    let noun: String
    /// Whether Give shows: open, nobody has it, nothing on its way, and an agent to give it to.
    let canGive: Bool
    let open: () -> Void
    let give: () -> Void

    var body: some View {
        WorkFlow(spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    (Text("#\(item.id)  ").foregroundStyle(.secondary).monospacedDigit()
                        + Text(item.title).foregroundStyle(.primary).fontWeight(.medium))
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    WorkFlow {
                        WorkTag(state: item.state)
                        facts
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Opens this \(noun).")
            .accessibilityAddTraits(.isButton)
            if canGive {
                Button("Give", action: give)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Give \(noun) #\(item.id) to an agent")
            }
        }
        .accessibilityAction(named: "Give to an agent") { if canGive { give() } }
    }

    @ViewBuilder
    private var facts: some View {
        if let pending {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(pending)
            }
        } else if item.holderAgentId != nil {
            WorkHolder(agent: holder, agentId: item.holderAgentId)
        } else if let modelClass = item.modelClass {
            Text("\(modelClass) model")
        } else {
            WorkAgo(date: item.updatedAt)
        }
    }

    private var label: String {
        var words = ["\(noun.capitalized) #\(item.id)", item.title, WorkState.name(item.state)]
        if let pending { words.append(pending) }
        else if let id = item.holderAgentId { words.append("\(holder?.name ?? id) has it") }
        else if let modelClass = item.modelClass { words.append("needs a \(modelClass) model") }
        return words.joined(separator: ", ")
    }
}

/// One pull request in the list: its number and title, where it stands, and what a reviewing agent last found. Tapping
/// it opens its own screen (#695).
struct WorkPullRow: View {
    let pull: WorkPull
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    (Text("#\(pull.number)  ").foregroundStyle(.secondary).monospacedDigit()
                        + Text(pull.title).foregroundStyle(.primary).fontWeight(.medium))
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    WorkFlow {
                        WorkTag(pull: pull)
                        if let finding = pull.newestFinding {
                            Text("\(finding.agentName) \(WorkPull.verdictWords(finding.verdict))")
                        } else if pull.state == "open" {
                            Text(pull.checksWords)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Opens this pull request.")
        .accessibilityAddTraits(.isButton)
    }

    private var label: String {
        var words = ["Pull request #\(pull.number)", pull.title, pull.standing]
        if pull.state == "open" { words.append(pull.checksWords) }
        if let finding = pull.newestFinding { words.append("\(finding.agentName) \(WorkPull.verdictWords(finding.verdict))") }
        return words.joined(separator: ", ")
    }
}

/// What the engine answered when it refused something the person asked for here, at the foot of the screen until it is
/// put away or the next request goes through.
struct WorkProblemBar: View {
    let words: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(words)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not done: \(words)")
    }
}

/// A write whose outcome pi² could not tell, as the Mac's card says it: the person looks at the repository, then says
/// whether it happened. Saying it did not lets pi² try the write again (docs/iphone.md, 4.2).
struct WorkUnknownCard: View {
    let write: WorkUnknownWrite
    let busy: Bool
    let settle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("pi² does not know whether this reached GitHub", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .symbolRenderingMode(.multicolor)
            Text("Its gh was cut off while it was \(write.summary), \(WorkTime.ago(write.at)). Look at the repository: if it is there, say it happened; if not, say it did not, and pi² will try the write again. Nothing is written again until you say.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WorkFlow(spacing: 8) {
                Button("It Happened") { settle(true) }
                    .buttonStyle(.bordered)
                Button("It Did Not") { settle(false) }
                    .buttonStyle(.bordered)
                if busy { ProgressView() }
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }
}
