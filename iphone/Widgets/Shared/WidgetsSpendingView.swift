import PiModels
import SwiftUI
import WidgetKit

/// Today's spending against the plan's windows (docs/design/iphone.md, "What a phone adds"): what today has cost, the
/// daily budget when one is set, and how full each subscription's windows are, as the Mac's Usage shows them. It opens
/// Usage.
struct WidgetsSpendingView: View {
    let spending: WidgetsSnapshot.Spending
    let heardAt: Date
    let family: WidgetFamily
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.widgetsAreHidden) private var hidden

    private var top: WidgetsSnapshot.PlanWindow? { spending.windows.first }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline:
                Label(inlineWords, systemImage: WidgetsKind.spending.symbol).widgetsPrivate()
            case .systemSmall: small
            default: list(rows: WidgetsRows.count(family, typeSize))
            }
        }
        .widgetURL(WidgetsKind.spending.link.url)
    }

    /// What today has cost: "$4.12", or the tokens when nothing was priced (a subscription's use has no price).
    static func amount(_ spending: WidgetsSnapshot.Spending) -> String {
        spending.todayCost == 0 && spending.todayTokens > 0 ? "\(Formats.tokens(spending.todayTokens)) tokens" : Formats.cost(spending.todayCost)
    }

    /// The line under the amount: over the budget, of the budget, or the tokens beside a cost.
    static func budgetWords(_ spending: WidgetsSnapshot.Spending) -> String? {
        if spending.overBudget, let budget = spending.dailyBudget { return "Over the \(Formats.cost(budget)) a day budget" }
        if spending.overBudget { return "Over the daily budget" }
        if let budget = spending.dailyBudget { return "of \(Formats.cost(budget)) a day" }
        if spending.todayCost > 0 { return "\(Formats.tokens(spending.todayTokens)) tokens" }
        return nil
    }

    /// "62% of 5-hour window".
    static func windowWords(_ window: WidgetsSnapshot.PlanWindow) -> String {
        "\(Int(window.usedPercent.rounded()))% of \(window.label.prefix(1).lowercased() + window.label.dropFirst())"
    }

    private var inlineWords: String {
        let today = "\(Self.amount(spending)) today"
        return top.map { "\(today) · \(Int($0.usedPercent.rounded()))%" } ?? today
    }

    /// How full the fullest window is, or the budget, for a gauge; nil when there is neither.
    private var fraction: Double? {
        if let top { return top.usedPercent / 100 }
        if let budget = spending.dailyBudget, budget > 0 { return min(1, spending.todayCost / budget) }
        return nil
    }

    @ViewBuilder
    private var circular: some View {
        if let fraction {
            Gauge(value: hidden ? 0 : fraction) {
                Image(systemName: WidgetsKind.spending.symbol)
            } currentValueLabel: {
                Text("\(Int((fraction * 100).rounded()))").monospacedDigit().widgetsPrivate()
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
            .accessibilityLabel(top.map(Self.windowWords) ?? "\(Int((fraction * 100).rounded()))% of the daily budget")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Text(Self.amount(spending))
                    .font(.caption.weight(.semibold)).minimumScaleFactor(0.5).lineLimit(1).padding(4)
                    .widgetsPrivate()
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Today \(Self.amount(spending))", systemImage: WidgetsKind.spending.symbol)
                .font(.headline).lineLimit(1).widgetAccentable().widgetsPrivate()
            if let top {
                Text(Self.windowWords(top)).font(.caption).lineLimit(1).widgetsPrivate()
                WidgetsBar(fraction: top.usedPercent / 100).frame(height: 5).widgetsPrivate()
            } else if let words = Self.budgetWords(spending) {
                Text(words).font(.caption).lineLimit(1).widgetsPrivate()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetsHeader(kind: .spending, title: "Today")
            WidgetsFigure(text: Self.amount(spending), size: .system(size: 32, weight: .semibold, design: .rounded))
            if let words = Self.budgetWords(spending) {
                Text(words).font(.caption).foregroundStyle(spending.overBudget ? Color.orange : Color.secondary)
                    .lineLimit(2).widgetsPrivate()
            }
            Spacer(minLength: 0)
            if let top {
                window(top, compact: true)
            }
            WidgetsUpdated(heardAt: heardAt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func list(rows: Int) -> some View {
        let shown = Array(spending.windows.prefix(rows))
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetsHeader(kind: .spending)
                WidgetsFigure(text: Self.amount(spending), size: .system(size: 32, weight: .semibold, design: .rounded))
                if let words = Self.budgetWords(spending) {
                    Text(words).font(.caption).foregroundStyle(spending.overBudget ? Color.orange : Color.secondary)
                        .lineLimit(2).widgetsPrivate()
                }
                if family == .systemLarge {
                    Divider().padding(.vertical, 6)
                    windows(shown)
                }
                Spacer(minLength: 0)
                WidgetsUpdated(heardAt: heardAt)
            }
            .frame(maxWidth: family == .systemMedium ? 130 : .infinity, maxHeight: .infinity, alignment: .topLeading)
            if family == .systemMedium {
                windows(shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func windows(_ shown: [WidgetsSnapshot.PlanWindow]) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            if shown.isEmpty {
                Text("No plan reports its windows.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(shown) { window($0, compact: false) }
            }
        }
    }

    private func window(_ window: WidgetsSnapshot.PlanWindow, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(compact ? window.label : "\(window.provider), \(window.label.prefix(1).lowercased() + window.label.dropFirst())")
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(Int(window.usedPercent.rounded()))%").monospacedDigit()
            }
            .font(.caption.weight(.medium))
            WidgetsBar(fraction: window.usedPercent / 100)
                .frame(height: 5)
            if !compact, let resets = window.resetsAt {
                Text("Resets \(WidgetsUpdated.words(resets, now: heardAt))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .widgetsPrivate()
        .accessibilityElement(children: .combine)
    }
}

/// How full a window is: above 80% it is marked, as the Mac's Usage marks it.
struct WidgetsBar: View {
    let fraction: Double
    @Environment(\.widgetsAreHidden) private var hidden

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if !hidden {
                    Capsule()
                    .fill(fraction > 0.8 ? Color.orange : WidgetsColor.accent)
                        .frame(width: max(geometry.size.height, geometry.size.width * min(1, max(0, fraction))))
                        .widgetAccentable()
                }
            }
        }
        .accessibilityHidden(true)
    }
}
