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
                        spendTile("Today", usage.today)
                        spendTile("All time", usage.total)
                        tile("Models used", "\(usage.models.count)", usage.models.first.map { "most: \(modelName($0.key))" } ?? "none yet")
                    }
                    LimitsSection(engine: engine)
                    budget(usage)
                    bars("By model", usage.models.map { (modelName($0.key), $0.tokens, $0.subscription == true ? "\(Formats.tokens($0.tokens)) tokens · subscription" : Formats.usage(tokens: $0.tokens, cost: $0.cost), Color.piAccent) })
                    bars("By agent", usage.agents.map { row in
                        let agent = engine.agent(row.agentId)
                        return (agent?.name ?? "Deleted agent", row.tokens, Formats.usage(tokens: row.tokens, cost: row.cost), AgentColor.color(agent?.color))
                    })
                    days(usage)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conversations that used the most").font(.system(size: 13, weight: .semibold))
                        if usage.conversations.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(usage.conversations) { row in
                            HStack {
                                Button(row.title.isEmpty ? "New conversation" : row.title) { model.selection = .conversation(row.id) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.acc)
                                    .lineLimit(1)
                                Spacer()
                                Text(Formats.usage(tokens: row.tokens, cost: row.cost)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Cost is an estimate for models you pay for by use, such as an API key. Models used through a subscription sign-in, and local models, count tokens only and do not count towards the budget.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView().padding(40)
            }
        }
        .background(Theme.window)
        .navigationTitle("Usage")
        .onAppear { budgetText = engine.usage?.budget.daily.map { String(format: "%.2f", $0) } ?? "" }
    }

    /// "Ollama · Llama 3.3" for the engine's "custom-ollama/llama3.3"; the key itself for a model no longer connected.
    private func modelName(_ key: String) -> String {
        guard let model = engine.allModels.first(where: { "\($0.provider)/\($0.id)" == key }) else { return key }
        return "\(model.providerName) · \(model.name)"
    }

    /// Money when some of the use was metered; otherwise the tokens, since a subscription or a local model has no bill.
    private func spendTile(_ title: String, _ spend: Spend) -> some View {
        spend.cost > 0
            ? tile(title, spend.costText, "\(spend.tokensText) tokens")
            : tile(title, spend.tokensText, spend.tokens > 0 ? "tokens · nothing metered" : "tokens")
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).sectionLabel()
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).tracking(-0.3)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.tx3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .panel()
        .accessibilityElement(children: .combine)
    }

    private func budget(_ usage: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily budget").font(.system(size: 13, weight: .semibold))
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
                    .tint(usage.overBudget ? Theme.bad : Theme.acc)
                Text(usage.overBudget
                    ? "Today's budget is used up. New messages and scheduled runs wait until you raise it or tomorrow comes. Work already running carries on."
                    : "\(usage.today.costText) of \(Formats.cost(daily)) used today.")
                    .font(.callout)
                    .foregroundStyle(usage.overBudget ? Theme.bad : Theme.tx2)
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
            Text(title).font(.system(size: 13, weight: .semibold))
            if rows.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.name).lineLimit(1).frame(width: 190, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(Theme.line)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(row.color)
                                .frame(width: max(4, geometry.size.width * CGFloat(row.value) / CGFloat(most)))
                        }
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
            Text("Last 14 days").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(usage.days) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Theme.acc, Theme.acc.opacity(0.55)], startPoint: .top, endPoint: .bottom))
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
