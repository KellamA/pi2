import SwiftUI

/// Where the tokens and money went, and the daily budget.
struct UsageView: View {
    @Bindable var model: AppModel
    @State private var budgetText = ""
    private var engine: EngineClient { model.engine }

    var body: some View {
        ScrollView {
            if let usage = engine.usage {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        tile("Today", usage.today.costText, "\(usage.today.tokensText) tokens")
                        tile("All time", usage.total.costText, "\(usage.total.tokensText) tokens")
                        tile("Models used", "\(usage.models.count)", usage.models.first.map { "most: \($0.key)" } ?? "none yet")
                    }
                    budget(usage)
                    bars("By model", usage.models.map { ($0.key, $0.tokens, $0.subscription == true ? "\(Formats.tokens($0.tokens)) tokens · subscription" : Formats.usage(tokens: $0.tokens, cost: $0.cost), Color.piAccent) })
                    bars("By agent", usage.agents.map { row in
                        let agent = engine.agent(row.agentId)
                        return (agent?.name ?? "Deleted agent", row.tokens, Formats.usage(tokens: row.tokens, cost: row.cost), AgentColor.color(agent?.color))
                    })
                    days(usage)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conversations that used the most").font(.headline)
                        if usage.conversations.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(usage.conversations) { row in
                            HStack {
                                Button(row.title.isEmpty ? "New conversation" : row.title) { model.selection = .conversation(row.id) }
                                    .buttonStyle(.link)
                                    .lineLimit(1)
                                Spacer()
                                Text(Formats.usage(tokens: row.tokens, cost: row.cost)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Cost is an estimate for models you pay for by use, such as an API key. Models used through a subscription sign-in, and local models, count tokens only and do not count towards the budget.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle("Usage")
        .onAppear { budgetText = engine.usage?.budget.daily.map { String(format: "%.2f", $0) } ?? "" }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
    }

    private func budget(_ usage: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily budget").font(.headline)
            HStack {
                Text("$")
                TextField("No limit", text: $budgetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit(saveBudget)
                    .accessibilityLabel("Daily budget in dollars")
                Button("Set") { saveBudget() }
                if usage.budget.daily != nil {
                    Button("Remove Limit") {
                        budgetText = ""
                        engine.perform("usage.setBudget", ["daily": NSNull()])
                    }
                }
                Spacer()
            }
            if let daily = usage.budget.daily {
                ProgressView(value: min(usage.today.cost, daily), total: daily)
                    .tint(usage.overBudget ? .red : .piAccent)
                Text(usage.overBudget
                    ? "Today's budget is used up. New messages and scheduled runs wait until you raise it or tomorrow comes. Work already running carries on."
                    : "\(usage.today.costText) of \(Formats.cost(daily)) used today.")
                    .font(.callout)
                    .foregroundStyle(usage.overBudget ? .red : .secondary)
            } else {
                Text("With a limit, new messages and scheduled runs are held once the day's spend reaches it.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func saveBudget() {
        let cleaned = budgetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard let value = Double(cleaned), value >= 0.01 else {
            engine.lastError = "Enter an amount of at least $0.01, or use Remove Limit."
            return
        }
        engine.perform("usage.setBudget", ["daily": value])
    }

    private func bars(_ title: String, _ rows: [(name: String, value: Int, detail: String, color: Color)]) -> some View {
        let most = max(rows.map(\.value).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if rows.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.name).lineLimit(1).frame(width: 190, alignment: .leading)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(row.color.gradient)
                            .frame(width: max(3, geometry.size.width * CGFloat(row.value) / CGFloat(most)))
                    }
                    .frame(height: 10)
                    Text(row.detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func days(_ usage: UsageSummary) -> some View {
        let most = max(usage.days.map(\.tokens).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 14 days").font(.headline)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(usage.days) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.piAccent.gradient)
                            .frame(width: 22, height: max(3, 80 * CGFloat(day.tokens) / CGFloat(most)))
                        Text(String(day.day.suffix(2))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .help("\(day.day): \(Formats.tokens(day.tokens)) tokens, \(Formats.cost(day.cost))")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.day): \(Formats.tokens(day.tokens)) tokens, \(Formats.cost(day.cost))")
                }
            }
            .frame(height: 100, alignment: .bottom)
        }
    }
}
