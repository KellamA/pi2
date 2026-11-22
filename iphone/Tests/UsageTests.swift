import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// Usage on a phone (#697): what it reads of the engine's `usage` and `limits` events, as the Mac's Usage window reads them,
/// and its two requests, each as the Mac makes it.
@MainActor
struct UsageTests {
    /// Waits for `condition`, polling, for at most `seconds`.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-11-22 15:00 UTC, the recorded session's day.
    private let now = Date(timeIntervalSince1970: 1_795_359_600)

    @Test func readsTheRecordedSessionAsTheMacDoes() async throws {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.usage?.agents.count == 10 && engine.projects.count == 2 && !engine.allAgents.isEmpty })
        let reading = UsageReading(engine)

        // Nothing metered: the amounts are tokens, the same today, this week and in all.
        let amounts = reading.amounts(now: now, calendar: utc)
        #expect(amounts.map(\.title) == ["Today", "Last 7 days", "All time"])
        #expect(amounts.allSatisfy { $0.value == "194k" && $0.detail == "tokens · nothing metered" })
        #expect(reading.budget == nil)
        // No subscription is signed in, so there are no plan windows.
        #expect(reading.providers.isEmpty)

        // The model is named as its provider lists it, not by its key.
        #expect(reading.modelRows.count == 1)
        #expect(reading.modelRows[0].name != "demo/demo-1")
        #expect(reading.modelRows[0].name.hasSuffix(engine.allModels.first { $0.provider == "demo" }?.name ?? "?"))
        // Every agent is a project's, so each says which.
        #expect(reading.agentRows.count == 10)
        #expect(reading.agentRows.allSatisfy { ["Demo project", "Demo project 2"].contains($0.note ?? "") })
        // Each project that spent today, opening its settings; each conversation opening itself.
        #expect(Set(reading.projectRows.map(\.name)) == ["Demo project", "Demo project 2"])
        #expect(reading.projectRows.allSatisfy { $0.route == .projectSettings($0.id) && !$0.over })
        #expect(reading.conversationRows.first?.route == .conversation(139))
        #expect(reading.conversationRows.count == 8)

        // The day the engine counted is the chart's last.
        let days = reading.chartDays(now: now, calendar: utc)
        #expect(days.count == 14)
        #expect(days.last?.key == "2026-11-22")
        #expect(days.last?.tokens == 194_012)
        #expect(days.dropLast().allSatisfy { $0.tokens == 0 })
    }

    @Test func theRecordingRefusesUsagesRequestsAndSaysSo() async throws {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        #expect(try await eventually { session.engine.usage != nil })
        let budget = try #require(await UsageRequests.setBudget(session.engine, daily: 5))
        #expect(budget.contains("usage.setBudget"))
        let refresh = try #require(await UsageRequests.refreshLimits(session.engine, provider: "anthropic"))
        #expect(refresh.contains("limits.refresh"))
    }

    @Test func sampleSpendingIsMoneyWithItsWeekAndBudget() throws {
        let reading = UsageSample.reading(over: false, now: now, calendar: utc)
        let amounts = reading.amounts(now: now, calendar: utc)
        #expect(amounts[0] == UsageReading.Amount(title: "Today", value: "$3.10", detail: "510k tokens"))
        // The seven days ending today: today, and 1, 2, 3, 5 and 6 days back; not 9 or 12.
        let week = reading.lastWeek(now: now, calendar: utc)
        #expect(abs(week.cost - (3.1 + 0.84 + 1.6 + 2.4 + 0.0 + 0.8)) < 0.001)
        #expect(week.tokens == 510_000 + 248_000 + 300_000 + 420_000 + 180_000 + 310_000)
        #expect(amounts[1].value == "$8.74")

        let budget = try #require(reading.budget)
        #expect(budget.line == "$3.10 of $5.00 used today.")
        #expect(abs(budget.fraction - 0.62) < 0.001)
        let over = try #require(UsageSample.reading(over: true, now: now, calendar: utc).budget)
        #expect(over.over)
        #expect(over.fraction == 1)
        #expect(over.line.hasPrefix("Today's budget is used up."))
    }

    @Test func listsAreTheMacsRows() throws {
        let reading = UsageSample.reading(over: true, now: now, calendar: utc)

        // Models: by the name their provider gives, or the key of one no longer connected; and why one has no cost.
        #expect(reading.modelRows.map(\.name) == ["Anthropic · Claude Sonnet", "OpenAI · GPT-5", "ollama/llama3.3", "OpenAI · Pictures"])
        #expect(reading.modelRows.map(\.detail) == ["1.8M tokens · subscription", "412k · $9.84", "96k · price unknown", "0 · $0.40 (partial)"])

        // Agents: with their project, since every orchestrator is "Orchestrator".
        #expect(reading.agentRows.map(\.name) == ["Orchestrator", "Forge", "Scout"])
        #expect(reading.agentRows.map(\.note) == ["Garden sensors", "Garden sensors", "Taxes 2026"])
        #expect(reading.agentRows[0].mark?.color == "green")

        // Projects: those that spent today, the most first, against a daily limit where there is one; one that spent
        // nothing and has no limit is left out.
        #expect(reading.projectRows.map(\.name) == ["Garden sensors", "Taxes 2026"])
        #expect(reading.projectRows[0].detail == "$5.00 of $4.00")
        #expect(reading.projectRows[0].over)
        #expect(reading.projectRows[1].detail == "120k · $1.20")
        #expect(!reading.projectRows[1].over)
        #expect(reading.projectRows[0].route == .projectSettings("sample-garden"))

        // Conversations: an untitled one is named as the Mac names it.
        #expect(reading.conversationRows.map(\.name) == ["Plan the watering schedule", "Fix the sensor readings", "New conversation"])
        #expect(reading.conversationRows[2].route == .conversation(9003))
    }

    @Test func chartFillsTheDaysAndSaysThemInASentence() {
        let reading = UsageSample.reading(over: false, now: now, calendar: utc)
        let days = reading.chartDays(now: now, calendar: utc)
        #expect(days.count == 14)
        #expect(days.first?.key == "2026-11-09")
        #expect(days.last?.key == "2026-11-22")
        #expect(days.filter { $0.tokens > 0 }.count == 8)
        let summary = UsageReading.chartSummary(days)
        #expect(summary.contains("in the last 14 days, on 8 days"))
        #expect(summary.contains("The most on"))
        #expect(UsageReading.chartSummary(UsageReading(usage: nil, providers: [], models: [], agents: [], projects: []).chartDays(now: now, calendar: utc))
            == "Nothing used in the last 14 days.")

        // The Mac's clock a day ahead of the phone's: the chart ends on the engine's day.
        let ahead = reading.chartDays(now: now.addingTimeInterval(-86_400), calendar: utc)
        #expect(ahead.last?.key == "2026-11-22")
    }

    @Test func limitsAreReadAsTheMacReadsThem() throws {
        let reading = UsageSample.reading(over: false, now: now, calendar: utc)
        let providers = reading.providers
        #expect(providers.map(\.id) == ["anthropic", "openai", "codex", "gemini"])
        #expect(providers[0].title == "Anthropic Max")
        #expect(providers[2].title == "Codex")

        let windows = try #require(providers[0].windows).map { UsageWindowState($0, now: now) }
        #expect(windows[0].percentText == "62%")
        #expect(windows[0].level == .normal)
        #expect(windows[0].resetText == "resets in 2 h 15 min")
        #expect(windows[1].percentText == "91.4%")
        #expect(windows[1].level == .high)
        #expect(windows[1].spoken == "This week: 91.4 percent used, resets in 3 d 4 h")
        let used = UsageWindowState(try #require(providers[1].windows?.first), now: now)
        #expect(used.level == .full)
        #expect(used.percentText == "Used up")
        #expect(used.stale)
        #expect(used.resetText == "reset 30 min ago")

        #expect(UsageLimits.checkedText(providers[0], now: now) == "checked 12 min ago")
        #expect(UsageLimits.failureText("Could not read the limits.", provider: providers[1]).hasPrefix("Could not read the limits ("))
        #expect(UsageLimits.emptyText(providers[2], asking: false) == "Shows after the next request on this subscription.")
        // Only a subscription pi² can ask, whose figures are over an hour old: OpenAI, read three hours ago but failed
        // six minutes ago, is not.
        #expect(UsageLimits.stale(providers, now: now).isEmpty)
        #expect(UsageLimits.stale(providers, now: now.addingTimeInterval(2 * 3600)) == ["anthropic", "openai"])
        #expect(UsageLimits.providers(nil).isEmpty)
    }

    @Test func budgetIsReadAsTheMacTakesIt() throws {
        #expect(try UsageRequests.budgetAmount("5").get() == 5)
        #expect(try UsageRequests.budgetAmount(" $2.50 ").get() == 2.5)
        #expect(try UsageRequests.budgetAmount("2,50").get() == 2.5)
        #expect(throws: UsageRequests.BudgetProblem.self) { try UsageRequests.budgetAmount("0").get() }
        #expect(throws: UsageRequests.BudgetProblem.self) { try UsageRequests.budgetAmount("abc").get() }
        #expect(throws: UsageRequests.BudgetProblem.self) { try UsageRequests.budgetAmount("").get() }
        #expect(UsagePage.budgetField(5) == "5.00")
        #expect(UsagePage.budgetField(nil) == "")
    }

    @Test func timesAreWordedAsTheMacWordsThem() {
        #expect(UsageTime.duration(30) == "1 min")
        #expect(UsageTime.duration(0) == "less than a minute")
        #expect(UsageTime.duration(2 * 3600) == "2 h")
        #expect(UsageTime.duration(3 * 86_400 + 4 * 3600) == "3 d 4 h")
        #expect(UsageTime.percent(62) == "62")
        #expect(UsageTime.percent(97.14) == "97.1")
        #expect(UsageTime.ago(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(UsageTime.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
    }

    @Test func requestsAreTheMacsAndARefusalIsSaid() async throws {
        let transport = UsageRecordingTransport(refusal: "Refused for the test.")
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.status == .connected })

        #expect(await UsageRequests.setBudget(engine, daily: 5) == "Refused for the test.")
        #expect(await UsageRequests.setBudget(engine, daily: nil) == "Refused for the test.")
        #expect(await UsageRequests.refreshLimits(engine, provider: "anthropic") == "Refused for the test.")

        let sent = transport.sent
        #expect(sent.map(\.method) == ["usage.setBudget", "usage.setBudget", "limits.refresh"])
        #expect(sent[0].params["daily"] as? Double == 5)
        #expect(sent[1].params["daily"] is NSNull)
        #expect(sent[2].params["id"] as? String == "anthropic")

        // Taken, each answers nil.
        transport.refusal = nil
        #expect(await UsageRequests.setBudget(engine, daily: 7.5) == nil)
        #expect(await UsageRequests.refreshLimits(engine, provider: "openai") == nil)
    }
}

/// A stand-in for a Mac that sends nothing, keeps every request a screen sends it, and answers each with `refusal` as the
/// engine's error, or with an empty result when it is nil.
@MainActor
final class UsageRecordingTransport: EngineTransport {
    struct Request {
        let method: String
        let params: [String: Any]
    }

    var refusal: String?
    private(set) var sent: [Request] = []
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    init(refusal: String?) {
        self.refusal = refusal
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        Task { @MainActor [weak self] in self?.handler?(.ready) }
    }

    func send(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        // What the session says by itself on connecting, which no screen sends, is answered and not kept.
        if method != "conversations.shown" {
            sent.append(Request(method: method, params: object["params"] as? [String: Any] ?? [:]))
        }
        let answer: [String: Any] = refusal.map { ["id": id, "error": $0] } ?? ["id": id, "result": [String: Any]()]
        var line = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        line.append(0x0A)
        Task { @MainActor [weak self] in self?.handler?(.received(line)) }
    }

    func cancel() {
        handler = nil
    }
}
