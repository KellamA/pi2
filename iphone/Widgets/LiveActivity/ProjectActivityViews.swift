import SwiftUI
import WidgetKit

/// How a followed project's Live Activity looks (docs/design/iphone-drafts.html, "What a phone adds"): on the Lock
/// Screen, the project's mark and name, how old the numbers are, and the three numbers in a line; in the Dynamic Island,
/// the mark and the numbers that matter most when it is compact, one number when it is minimal, and all of it when it is
/// expanded. Every view draws only the project's name, set on the phone, and the three numbers with their time: nothing
/// else reaches an activity. `ProjectActivityWidget` puts them together; the tests draw each to a picture.
enum ProjectActivityStyle {
    /// The needs' colour, the design's amber: what waits for the person stands out from what is merely going on. Darker
    /// on a light Lock Screen, where the design's amber would be too faint to read; the island is always dark.
    static let needs = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF0 / 255, green: 0xB2 / 255, blue: 0x4A / 255, alpha: 1)
            : UIColor(red: 0xA8 / 255, green: 0x62 / 255, blue: 0x00 / 255, alpha: 1)
    })

    static let workingSymbol = "circle.lefthalf.filled"
    static let needsSymbol = "exclamationmark.circle.fill"
    static let finishedSymbol = "checkmark.circle.fill"

    /// A count in full, as the Lock Screen and the expanded island show it: "1,204".
    static func count(_ value: Int) -> String {
        max(0, value).formatted(.number)
    }

    /// A count where there is room for two or three characters, compact and minimal: "99+" past 99.
    static func short(_ value: Int) -> String {
        value > 99 ? "99+" : String(max(0, value))
    }

    /// "as of 9:40": when the Mac counted the numbers, so that numbers the relay has not updated for a while say so.
    /// A day ago or more, with the day.
    static func asOf(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "as of \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "as of \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    /// The numbers in words, for VoiceOver wherever a form shows them as symbols.
    static func spoken(_ state: ProjectActivityAttributes.ContentState) -> String {
        "\(state.working) working, \(state.needs) \(state.needs == 1 ? "needs" : "need") you, \(state.finished) finished"
    }
}

/// The project's mark: π on the app's accent, as the design's activity draws it.
struct ProjectActivityMark: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(WidgetsColor.accent)
            .frame(width: size, height: size)
            .overlay {
                Text("π")
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// "3 working · 1 needs you · 2 finished", the needs in amber when there are any.
struct ProjectActivityLine: View {
    let state: ProjectActivityAttributes.ContentState

    var body: some View {
        let dot = Text(" · ").foregroundStyle(.secondary)
        let needs = Text("\(ProjectActivityStyle.count(state.needs)) \(state.needs == 1 ? "needs" : "need") you")
            .foregroundStyle(state.needs > 0 ? AnyShapeStyle(ProjectActivityStyle.needs) : AnyShapeStyle(.primary))
        Text("\(Text("\(ProjectActivityStyle.count(state.working)) working"))\(dot)\(needs)\(dot)\(Text("\(ProjectActivityStyle.count(state.finished)) finished"))")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// The Lock Screen's activity (and the banner on a phone without a Dynamic Island).
struct ProjectActivityLockView: View {
    let name: String
    let state: ProjectActivityAttributes.ContentState
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProjectActivityMark()
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ProjectActivityStyle.asOf(state.date, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            ProjectActivityLine(state: state)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(ProjectActivityStyle.spoken(state)), \(ProjectActivityStyle.asOf(state.date, now: now))")
    }
}

/// The compact island's left: the mark, and the project's name as far as it fits.
struct ProjectActivityCompactLeading: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            ProjectActivityMark(size: 20)
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 56, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The compact island's right: who is working, and what needs the person when anything does; with nothing going on,
/// what finished.
struct ProjectActivityCompactTrailing: View {
    let state: ProjectActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            if state.isIdle {
                figure(state.finished, ProjectActivityStyle.finishedSymbol, .secondary)
            } else {
                figure(state.working, ProjectActivityStyle.workingSymbol, .primary)
                if state.needs > 0 {
                    figure(state.needs, ProjectActivityStyle.needsSymbol, ProjectActivityStyle.needs)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectActivityStyle.spoken(state))
    }

    private func figure(_ value: Int, _ symbol: String, _ style: some ShapeStyle) -> some View {
        HStack(spacing: 2) {
            Text(ProjectActivityStyle.short(value))
            Image(systemName: symbol).imageScale(.small)
        }
        .foregroundStyle(style)
    }
}

/// The minimal island, when another app's activity shares it: one number, the one that matters most. What needs the
/// person, if anything does; else who is working; else a check.
struct ProjectActivityMinimal: View {
    let state: ProjectActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.needs > 0 {
                Text(ProjectActivityStyle.short(state.needs)).foregroundStyle(ProjectActivityStyle.needs)
            } else if state.working > 0 {
                Text(ProjectActivityStyle.short(state.working))
            } else {
                Image(systemName: ProjectActivityStyle.finishedSymbol).foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.bold))
        .monospacedDigit()
        .minimumScaleFactor(0.6)
        .accessibilityLabel(ProjectActivityStyle.spoken(state))
    }
}

/// The expanded island's left: the mark and the project's name.
struct ProjectActivityExpandedLeading: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            ProjectActivityMark(size: 24)
            Text(name)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The expanded island's right: how old the numbers are.
struct ProjectActivityExpandedTrailing: View {
    let state: ProjectActivityAttributes.ContentState
    var now = Date()

    var body: some View {
        Text(ProjectActivityStyle.asOf(state.date, now: now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// The expanded island's bottom: the three numbers, each with its word.
struct ProjectActivityExpandedBottom: View {
    let state: ProjectActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            column(state.working, "working", .primary)
            column(state.needs, "\(state.needs == 1 ? "needs" : "need") you",
                   state.needs > 0 ? AnyShapeStyle(ProjectActivityStyle.needs) : AnyShapeStyle(.primary))
            column(state.finished, "finished", .primary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectActivityStyle.spoken(state))
    }

    private func column(_ value: Int, _ word: String, _ style: some ShapeStyle) -> some View {
        VStack(spacing: 2) {
            Text(ProjectActivityStyle.count(value))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(style)
            Text(word)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
