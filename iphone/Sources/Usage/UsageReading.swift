import EngineKit
import Foundation
import PiModels

/// Everything Usage draws, read from the engine's state as the Mac's Usage window reads it (app/Sources/pi2/UsageView.swift
/// and LimitsView.swift): the `usage` event, the `limits` event, and the models, agents and projects that name its rows.
/// A value, so that the page draws the same from the session or, in tests and a debug build's preview, from sample values.
struct UsageReading {
    var usage: UsageSummary?
    var providers: [PlanLimits.Provider]
    var models: [ModelInfo]
    var agents: [AgentProfile]
    var projects: [ProjectRow]

    init(usage: UsageSummary?, providers: [PlanLimits.Provider], models: [ModelInfo], agents: [AgentProfile], projects: [ProjectRow]) {
        self.usage = usage
        self.providers = providers
        self.models = models
        self.agents = agents
        self.projects = projects
    }

    @MainActor
    init(_ engine: EngineSession<MessageField>) {
        self.init(
            usage: engine.usage, providers: PlanLimits(engine.extras["limits"])?.providers ?? [],
            models: engine.allModels, agents: engine.allAgents, projects: engine.projects
        )
    }

    private func agent(_ id: String?) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    // MARK: - Spending

    /// An amount as the Mac's tiles give it: money when some of it was metered, otherwise tokens, since a subscription
    /// or a local model has no bill.
    struct Amount: Equatable {
        let title: String
        let value: String
        let detail: String
    }

    static func amount(_ title: String, cost: Double, tokens: Int) -> Amount {
        cost > 0
            ? Amount(title: title, value: Formats.cost(cost), detail: "\(Formats.tokens(tokens)) tokens")
            : Amount(title: title, value: Formats.tokens(tokens), detail: tokens > 0 ? "tokens · nothing metered" : "tokens")
    }

    /// Today, the last seven days (today among them), and all time.
    func amounts(now: Date = .now, calendar: Calendar = .current) -> [Amount] {
        guard let usage else { return [] }
        let week = lastWeek(now: now, calendar: calendar)
        return [
            Self.amount("Today", cost: usage.today.cost, tokens: usage.today.tokens),
            Self.amount("Last 7 days", cost: week.cost, tokens: week.tokens),
            Self.amount("All time", cost: usage.total.cost, tokens: usage.total.tokens),
        ]
    }

    /// What was spent on the seven days ending today, from the engine's days (each a day of the Mac's calendar, which
    /// keeps the last fourteen that had any use).
    func lastWeek(now: Date = .now, calendar: Calendar = .current) -> (cost: Double, tokens: Int) {
        let days = chartDays(count: 7, now: now, calendar: calendar)
        return (days.reduce(0) { $0 + $1.cost }, days.reduce(0) { $0 + $1.tokens })
    }

    // MARK: - The days

    /// One day of the chart: a day of the calendar, with what was spent on it (none on a day the engine does not list).
    struct Day: Equatable, Identifiable {
        /// "2026-11-22", as the engine keys its days.
        let key: String
        let date: Date
        let cost: Double
        let tokens: Int
        var id: String { key }
    }

    /// The `count` days of the calendar ending today, or on the engine's last day if that is later (the Mac's clock can
    /// be a day ahead of the phone's), each with what the engine counted for it.
    func chartDays(count: Int = 14, now: Date = .now, calendar: Calendar = .current) -> [Day] {
        let listed = Dictionary((usage?.days ?? []).map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        var end = calendar.startOfDay(for: now)
        if let last = usage?.days.map(\.day).max(), let lastDate = Self.date(last, calendar: calendar), lastDate > end {
            end = lastDate
        }
        return (0..<count).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: end) else { return nil }
            let key = Self.key(date, calendar: calendar)
            let day = listed[key]
            return Day(key: key, date: date, cost: day?.cost ?? 0, tokens: day?.tokens ?? 0)
        }
    }

    /// "2026-11-22" for a date, as the engine's `dayKey` makes it.
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// What VoiceOver says of the chart in one sentence: the total, the busiest day, and how many days had any use.
    static func chartSummary(_ days: [Day]) -> String {
        let used = days.filter { $0.tokens > 0 || $0.cost > 0 }
        guard let busiest = used.max(by: { $0.tokens < $1.tokens }) else { return "Nothing used in the last \(days.count) days." }
        let tokens = used.reduce(0) { $0 + $1.tokens }
        let cost = used.reduce(0) { $0 + $1.cost }
        let day = busiest.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let count = used.count == 1 ? "1 day" : "\(used.count) days"
        return "\(Formats.usage(tokens: tokens, cost: cost)) in the last \(days.count) days, on \(count). The most on \(day): \(Formats.usage(tokens: busiest.tokens, cost: busiest.cost))."
    }

    // MARK: - The budget

    /// What the daily budget says now: nil when there is none.
    struct Budget: Equatable {
        let daily: Double
        let spent: Double
        let over: Bool
        var fraction: Double { daily > 0 ? min(spent, daily) / daily : 0 }
        var line: String {
            over
                ? "Today's budget is used up. New messages and scheduled runs wait until you raise it or tomorrow comes. Work already running carries on."
                : "\(Formats.cost(spent)) of \(Formats.cost(daily)) used today."
        }
    }

    var budget: Budget? {
        guard let usage, let daily = usage.budget.daily else { return nil }
        return Budget(daily: daily, spent: usage.today.cost, over: usage.overBudget)
    }

    // MARK: - The lists

    /// A row of one of the lists: a name, what it spent, and a bar against the list's largest.
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        /// Said after the name in small grey: an agent's project.
        let note: String?
        /// Tokens, for the bar.
        let value: Int
        let detail: String
        /// The mark beside it: an agent's, or a project's orchestrator's; nil for a model.
        let mark: (name: String?, color: String?)?
        /// Over its own limit: a project past its daily spend.
        var over = false
        /// Where tapping it goes, if anywhere.
        var route: Route?

        static func == (left: Row, right: Row) -> Bool {
            left.id == right.id && left.name == right.name && left.note == right.note && left.value == right.value
                && left.detail == right.detail && left.mark?.name == right.mark?.name && left.mark?.color == right.mark?.color
                && left.over == right.over && left.route == right.route
        }
    }

    /// "Ollama · Llama 3.3" for the engine's "custom-ollama/llama3.3"; the key itself for a model no longer connected.
    func modelName(_ row: UsageSummary.ModelRow) -> String {
        if let pictureName = row.pictureName { return pictureName }
        if let lookName = row.lookName { return lookName }
        guard let model = models.first(where: { "\($0.provider)/\($0.id)" == row.key }) else { return row.key }
        return "\(model.providerName) · \(model.name)"
    }

    /// A model's tokens, and its cost when it has one; why it has none when that is not plain.
    static func modelDetail(_ row: UsageSummary.ModelRow) -> String {
        if row.subscription == true { return "\(Formats.tokens(row.tokens)) tokens · subscription" }
        if row.unpriced == true {
            if row.cost == 0 {
                return row.tokens == 0 ? "price unknown" : "\(Formats.tokens(row.tokens)) · price unknown"
            }
            if row.pictureName != nil || row.lookName != nil { return "\(Formats.usage(tokens: row.tokens, cost: row.cost)) (partial)" }
        }
        return Formats.usage(tokens: row.tokens, cost: row.cost)
    }

    var modelRows: [Row] {
        (usage?.models ?? []).map { row in
            Row(id: row.id, name: modelName(row), note: nil, value: row.tokens, detail: Self.modelDetail(row), mark: nil)
        }
    }

    /// Each agent's spend, with the project it belongs to: every project's orchestrator is "Orchestrator" unless renamed,
    /// so its name alone does not say which (the Mac's #752).
    var agentRows: [Row] {
        (usage?.agents ?? []).map { row in
            let agent = agent(row.agentId)
            return Row(
                id: row.agentId, name: agent?.name ?? "Deleted agent", note: projectName(of: agent), value: row.tokens,
                detail: Formats.usage(tokens: row.tokens, cost: row.cost), mark: (agent?.name, agent?.color)
            )
        }
    }

    /// The project an agent belongs to; nil for a template. A deleted project is still in the `projects` event by name;
    /// "Deleted project" only when there is no project of that id at all.
    private func projectName(of agent: AgentProfile?) -> String? {
        guard let id = agent?.projectId else { return nil }
        return projects.first { $0.id == id }?.name ?? "Deleted project"
    }

    /// Today's spend of each project that spent anything or has a daily limit, the most first, in its orchestrator's
    /// colour; against its daily limit when it has one, as the Mac's Dashboard line says it. Each opens the project's
    /// settings, where its limits are.
    var projectRows: [Row] {
        let rows = (usage?.projects ?? []).compactMap { row -> (UsageSummary.ProjectSpend, ProjectRow?)? in
            let project = projects.first { $0.id == row.id }
            let limit = project?.settings?.limits.dailySpend
            guard row.today.tokens > 0 || row.today.cost > 0 || limit != nil else { return nil }
            return (row, project)
        }
        return rows
            .sorted { $0.0.today.cost != $1.0.today.cost ? $0.0.today.cost > $1.0.today.cost : $0.0.today.tokens > $1.0.today.tokens }
            .map { row, project in
                let name = project.map { $0.archivedAt == nil ? $0.name : "\($0.name) (archived)" } ?? "Deleted project"
                let orchestrator = agent(project?.orchestratorId)
                let limit = project?.settings?.limits.dailySpend
                let spent = row.today.cost
                return Row(
                    id: row.id, name: name, note: nil, value: row.today.tokens,
                    detail: limit.map { "\(Formats.cost(spent)) of \(Formats.cost($0))" } ?? Formats.usage(tokens: row.today.tokens, cost: spent),
                    mark: (project?.name, orchestrator?.color), over: limit.map { spent >= $0 } ?? false,
                    route: project == nil || project?.deletedAt != nil ? nil : .projectSettings(row.id)
                )
            }
    }

    /// The conversations that used the most, each opening its conversation.
    var conversationRows: [Row] {
        (usage?.conversations ?? []).map { row in
            Row(
                id: String(row.id), name: row.title.isEmpty ? "New conversation" : row.title, note: nil, value: row.tokens,
                detail: Formats.usage(tokens: row.tokens, cost: row.cost), mark: nil, route: .conversation(row.id)
            )
        }
    }
}
