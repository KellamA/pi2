
import PiModels
import SwiftUI

/// A project's row: its mark, its name and badge, the orchestrator's last words and when they came. As the Mac's sidebar
/// row, laid out for the phone (docs/design/iphone.md, "The projects list").
struct HomeProjectRow: View {
    let project: HomeProject
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var markSide: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HomeMark(name: project.name, color: project.color, side: markSide)
            VStack(alignment: .leading, spacing: 3) {
                let top = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
                top {
                    HStack(spacing: 4) {
                        Text(project.name).font(.headline).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        if project.folderMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Folder missing")
                        }
                    }
                    .layoutPriority(1)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                    HomeProjectBadge(project: project)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(project.lastWords ?? String(localized: "Nothing said yet"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let at = project.lastWordsAt, !typeSize.isAccessibilitySize {
                        Text(HomeTime.short(at)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let at = project.lastWordsAt, typeSize.isAccessibilitySize {
                    Text(HomeTime.short(at)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

/// A project's badge, as the Mac's sidebar has it: how many things need the person, else how many agents work (with the
/// orchestrator's state, which the Mac shows in the mark's place), else idle.
struct HomeProjectBadge: View {
    let project: HomeProject

    var body: some View {
        switch project.badge {
        case .needs(let count):
            Text("\(count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(.orange, in: Capsule())
                .accessibilityLabel(count == 1 ? "1 thing needs you" : "\(count) things need you")
        case .working(let count):
            HStack(spacing: 5) {
                if project.orchestratorAtLimit {
                    Image(systemName: "hourglass").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(workingLabel(count))
        case .idle:
            Text("idle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func workingLabel(_ count: Int) -> String {
        let agents = count == 1 ? String(localized: "1 agent working") : String(localized: "\(count) agents working")
        if project.orchestratorAtLimit { return agents + String(localized: "; the orchestrator waits for a limit") }
        return agents
    }
}

/// A project's mark: its first letter on its orchestrator's colour, the soft pastels with dark lettering the Mac uses
/// (`AgentColor`, `ProjectMark`), which read the same in light and dark. Decoration: the row says the name.
struct HomeMark: View {
    let name: String
    let color: String?
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(Self.color(color))
            .frame(width: side, height: side)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: side * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.11))
            }
            .accessibilityHidden(true)
    }

    /// The Mac's agent colours (`AgentColor` in the Mac app), by name.
    static func color(_ name: String?) -> Color {
        let hex: UInt32 = switch name {
        case "blue": 0x9FC5FF
        case "teal": 0x7FD8C4
        case "green": 0xA8E39A
        case "yellow": 0xF5D77A
        case "orange": 0xFFB37A
        case "pink": 0xFFA8C8
        case "gray": 0xC3C5D0
        default: 0xB9A6FF
        }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A chat's row: its title, pinned or answering, and when it was last used.
struct HomeChatRow: View {
    let chat: ConversationSummary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the largest sizes the time goes under the title: beside it, both were cut ("Trip", "4:35 P").
        let large = typeSize.isAccessibilitySize
        HStack(alignment: large ? .firstTextBaseline : .center, spacing: 10) {
            Image(systemName: chat.isPinned ? "pin.fill" : "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
                .frame(minWidth: 22)
                .accessibilityHidden(true)
            let stack = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 10))
            stack {
                Text(chat.title.isEmpty ? String(localized: "New chat") : chat.title)
                    .lineLimit(large ? 4 : 2)
                    .foregroundStyle(chat.title.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chat.busy {
                    ProgressView().controlSize(.small).accessibilityLabel("Answering")
                } else {
                    Text(HomeTime.short(HomeTime.date(chat.updatedAt))).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(chat.isPinned ? Text("Pinned") : Text(""))
    }
}

/// A row of More: what it is, and what the engine says of it now.
struct HomeMoreRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 10) {
            // At the largest sizes the icon gives its room to the words, which would otherwise break inside themselves.
            if typeSize.isAccessibilitySize {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: icon).foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
