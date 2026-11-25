import PiModels
import SwiftUI

/// One of Spending's rows: what it counts, the amount large, and under it what the amount is of.
struct UsageAmountRow: View {
    let amount: UsageReading.Amount
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(amount.title)
                Text(amount.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(amount.value)
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(amount.title)
        .accessibilityValue("\(amount.value), \(amount.detail)")
    }
}

/// A row of one of the lists: its mark, its name (and an agent's project after it), what it spent, and a bar against the
/// list's largest. A row that opens something ends in a chevron.
struct UsageBarRow: View {
    let row: UsageReading.Row
    let most: Int
    let opens: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            // At the largest sizes the name needs the row's width more than its mark, which only repeats the bar's colour.
            if let mark = row.mark, !typeSize.isAccessibilitySize {
                AgentMark(name: mark.name, color: mark.color, size: 28)
            }
            VStack(alignment: .leading, spacing: 6) {
                // The name and its amount on one line where they fit, else the amount under the name, never cut.
                ViewThatFits(in: .horizontal) {
                    if !typeSize.isAccessibilitySize {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            name.lineLimit(1)
                            Spacer(minLength: 4)
                            detail.fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        name.lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                        detail
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ProgressView(value: Double(row.value), total: Double(max(most, 1)))
                    .tint(tint)
            }
            if opens {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.note.map { "\(row.name), \($0)" } ?? row.name)
        .accessibilityValue(row.over ? "\(row.detail), over its daily limit" : row.detail)
    }

    private var detail: some View {
        Text(row.detail)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(row.over ? Color.red : Color.secondary)
    }

    /// The name, and after it in small grey its note, as one text so that they wrap together.
    private var name: Text {
        guard let note = row.note else { return Text(row.name) }
        return Text("\(row.name)  \(Text(note).font(.footnote).foregroundStyle(.secondary))")
    }

    private var tint: Color {
        if row.over { return .red }
        if let mark = row.mark { return AgentColor.color(mark.color) }
        return .pi2Accent
    }
}

/// One subscription's card in Plan limits, as the Mac's Usage draws it (`LimitsSection.card`): its name and plan, when
/// its figures were read, Check Now, a bar for each window, and what went wrong when the last check failed.
struct UsagePlanCard: View {
    let provider: PlanLimits.Provider
    let now: Date
    let asking: Bool
    /// What the engine said when Check Now was refused.
    let problem: String?
    /// False while the Mac cannot be reached: Check Now waits for it.
    var canCheck = true
    let check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if provider.reports == "none" {
                Text("Does not report its limits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let windows = provider.windows ?? []
                ForEach(windows) { window in
                    UsageWindowRow(state: UsageWindowState(window, now: now))
                }
                if windows.isEmpty, let empty = UsageLimits.emptyText(provider, asking: asking) {
                    Text(empty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = provider.error {
                    UsageProblem(text: UsageLimits.failureText(error, provider: provider))
                }
            }
            if let problem {
                UsageProblem(text: problem)
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let checked = UsageLimits.checkedText(provider, now: now) {
                    Text(checked)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if provider.reports == "usage" {
                if asking || provider.refreshing == true {
                    ProgressView()
                        .accessibilityLabel("Checking \(provider.name)'s limits")
                } else {
                    Button("Check Now", systemImage: "arrow.clockwise", action: check)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!canCheck)
                        .accessibilityLabel("Check \(provider.name)'s limits now")
                }
            }
        }
    }
}

/// One window of a subscription: its name and how much is used, a bar, and when it resets. Above 80% the amount is marked,
/// and a window whose reset has passed since it was read is dimmed until it is read again.
struct UsageWindowRow: View {
    let state: UsageWindowState
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                Text(state.label)
                    .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                HStack(spacing: 4) {
                    if state.level != .normal {
                        Image(systemName: state.level == .full ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(tint)
                    }
                    Text(state.percentText)
                        .fontWeight(state.level == .normal ? .regular : .semibold)
                        .monospacedDigit()
                }
            }
            ProgressView(value: state.used, total: 100)
                .tint(tint)
                .opacity(state.stale ? 0.45 : 1)
            if !state.resetText.isEmpty {
                Text(state.resetText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.spoken)
    }

    private var tint: Color {
        switch state.level {
        case .full: .red
        case .high: .orange
        case .normal: .pi2Accent
        }
    }
}

/// The last fourteen days as bars, today's on the right, with the first day and today named under them. VoiceOver reads it
/// as one sentence, and its chart description lets an audio graph and the rotor read each day.
struct UsageDaysChart: View {
    let days: [UsageReading.Day]
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 96

    var body: some View {
        let most = max(days.map(\.tokens).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    let fraction = CGFloat(day.tokens) / CGFloat(most)
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                        .fill(day.tokens > 0 ? Color.pi2Accent : Color.secondary.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: day.tokens > 0 ? max(3, min(height, 160) * fraction) : 2)
                }
            }
            .frame(height: min(height, 160), alignment: .bottom)
            HStack {
                if let first = days.first {
                    Text(first.date.formatted(.dateTime.day().month(.abbreviated)))
                }
                Spacer()
                Text("Today")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last \(days.count) days")
        .accessibilityValue(UsageReading.chartSummary(days))
        .accessibilityChartDescriptor(UsageDaysDescriptor(days: days))
    }
}

/// The days chart for VoiceOver's audio graph: tokens by day.
struct UsageDaysDescriptor: AXChartDescriptorRepresentable {
    let days: [UsageReading.Day]

    func makeChartDescriptor() -> AXChartDescriptor {
        let names = days.map { $0.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        let most = Double(max(days.map(\.tokens).max() ?? 0, 1))
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: names)
        let yAxis = AXNumericDataAxisDescriptor(title: "Tokens", range: 0...most, gridlinePositions: []) { value in
            "\(Formats.tokens(Int(value))) tokens"
        }
        let series = AXDataSeriesDescriptor(name: "Tokens used", isContinuous: false, dataPoints: zip(names, days).map { name, day in
            AXDataPoint(x: name, y: Double(day.tokens), label: Formats.usage(tokens: day.tokens, cost: day.cost))
        })
        return AXChartDescriptor(title: "Last \(days.count) days", summary: UsageReading.chartSummary(days), xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}

/// What the engine said when it did not take a request, or why a subscription's figures could not be read.
struct UsageProblem: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A quiet line where a section has nothing to say.
struct UsageQuietLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
