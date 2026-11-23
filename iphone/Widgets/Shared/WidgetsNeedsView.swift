import SwiftUI
import WidgetKit

/// Needs you: the count, and the newest things waiting by who asks (docs/design/iphone.md, "What a phone adds"). A
/// row opens Needs you at its card's project; the small widget, with no rows, opens the newest.
struct WidgetsNeedsView: View {
    let snapshot: WidgetsSnapshot
    let family: WidgetFamily
    @Environment(\.dynamicTypeSize) private var typeSize

    private var needs: WidgetsSnapshot.Needs { snapshot.needs }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: WidgetsKind.needs.symbol).font(.caption).widgetAccentable()
                    Text("\(needs.count)").font(.title2.weight(.semibold)).monospacedDigit().widgetsPrivate()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.countWords(needs.count))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(needs.count == 0 ? "Nothing waits" : "\(needs.count) waiting", systemImage: WidgetsKind.needs.symbol)
                    .font(.headline).widgetAccentable().widgetsPrivate()
                if let newest = needs.newest.first {
                    Text(newest.title).font(.caption).lineLimit(1).widgetsPrivate()
                    if let project = newest.projectName {
                        Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1).widgetsPrivate()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(Self.countWords(needs.count), systemImage: WidgetsKind.needs.symbol).widgetsPrivate()
        case .systemSmall:
            small
        default:
            list(rows: WidgetsRows.count(family, typeSize))
        }
    }

    /// "Nothing needs you", "1 thing needs you", "3 things need you".
    static func countWords(_ count: Int) -> String {
        switch count {
        case 0: "Nothing needs you"
        case 1: "1 thing needs you"
        default: "\(count) things need you"
        }
    }

    /// The link a need's row opens.
    static func link(_ need: WidgetsSnapshot.Need) -> WidgetsLink {
        .needs(project: need.projectID, need: need.id)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetsHeader(kind: .needs)
            if let newest = needs.newest.first {
                WidgetsFigure(text: "\(needs.count)", size: .system(size: 34, weight: .semibold, design: .rounded))
                Text(newest.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .widgetsPrivate()
                if let project = newest.projectName {
                    Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1).widgetsPrivate()
                }
            } else {
                Spacer(minLength: 0)
                nothing
            }
            Spacer(minLength: 0)
            WidgetsUpdated(heardAt: snapshot.heardAt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL((needs.newest.first.map(Self.link) ?? WidgetsKind.needs.link).url)
    }

    private var nothing: some View {
        Label("Nothing needs you.", systemImage: "checkmark.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func list(rows: Int) -> some View {
        let shown = Array(needs.newest.prefix(rows))
        let more = needs.count - shown.count
        HStack(alignment: .top, spacing: 14) {
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetsHeader(kind: .needs)
                    WidgetsFigure(text: "\(needs.count)")
                    Spacer(minLength: 0)
                    WidgetsUpdated(heardAt: snapshot.heardAt)
                }
                .frame(width: 92, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 8) {
                if family == .systemLarge {
                    HStack(alignment: .firstTextBaseline) {
                        WidgetsHeader(kind: .needs)
                        Spacer()
                        Text(Self.countWords(needs.count)).font(.caption).foregroundStyle(.secondary).widgetsPrivate()
                    }
                }
                if shown.isEmpty {
                    if family == .systemLarge { Spacer(minLength: 0) }
                    nothing
                } else {
                    ForEach(shown) { need in
                        Link(destination: Self.link(need).url) { row(need) }
                    }
                }
                Spacer(minLength: 0)
                if more > 0 {
                    Text("and \(more) more").font(.caption).foregroundStyle(.secondary).widgetsPrivate()
                }
                if family == .systemLarge {
                    WidgetsUpdated(heardAt: snapshot.heardAt)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(WidgetsKind.needs.link.url)
    }

    private func row(_ need: WidgetsSnapshot.Need) -> some View {
        HStack(spacing: 8) {
            WidgetsMark(name: need.agentName, color: need.agentColor).widgetsPrivate()
            VStack(alignment: .leading, spacing: 0) {
                Text(need.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary).lineLimit(1)
                Text(need.projectName ?? "Outside projects").font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
            }
            .widgetsPrivate()
            Spacer(minLength: 0)
            if family == .systemLarge {
                Text(WidgetsUpdated.words(need.createdAt))
                    .font(.caption2).foregroundStyle(Color.secondary).widgetsPrivate()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
