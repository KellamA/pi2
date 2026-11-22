#if DEBUG
import Foundation
import PiModels
import SwiftUI

/// Plainly sample values for Usage, for a debug build's pictures of the states the recorded session does not reach (it
/// has no subscription signed in, no cost and no budget): `PI2_USAGE_SAMPLE=1` draws the page from them, with a line at
/// its top saying so, and `PI2_USAGE_SAMPLE=over` the same with the day's budget used up. They are fed to the view
/// directly, never through the engine's client, and its buttons still send their requests to the engine, which answers as
/// it does. Unit tests use them too. None of it is compiled into a release build.
enum UsageSample {
    static let kind = ProcessInfo.processInfo.environment["PI2_USAGE_SAMPLE"]
    static var isOn: Bool { kind != nil }

    /// The sample reading the environment asks for, or nil to draw the engine's.
    static func reading(now: Date = .now) -> UsageReading? {
        guard let kind else { return nil }
        return reading(over: kind == "over", now: now)
    }

    static func reading(over: Bool, now: Date = .now, calendar: Calendar = .current) -> UsageReading {
        let ms = now.timeIntervalSince1970 * 1000
        let hour = 3_600_000.0
        func day(_ back: Int) -> String {
            UsageReading.key(calendar.date(byAdding: .day, value: -back, to: now) ?? now, calendar: calendar)
        }
        let todayCost = over ? 6.2 : 3.1
        let usage = """
            {"models": [
               {"key": "anthropic/claude-sonnet", "tokens": 1840000, "cost": 0, "subscription": true},
               {"key": "openai/gpt-5", "tokens": 412000, "cost": 9.84},
               {"key": "ollama/llama3.3", "tokens": 96000, "cost": 0, "unpriced": true},
               {"key": "pictures/one", "tokens": 0, "cost": 0.4, "unpriced": true, "pictureName": "OpenAI · Pictures"}],
             "agents": [
               {"agentId": "sample-orchestrator", "cost": 4.1, "tokens": 1210000},
               {"agentId": "sample-forge", "cost": 3.7, "tokens": 820000},
               {"agentId": "sample-scout", "cost": 2.44, "tokens": 318000}],
             "projects": [
               {"id": "sample-garden", "today": {"cost": \(todayCost - 1.2), "tokens": 390000}},
               {"id": "sample-taxes", "today": {"cost": 1.2, "tokens": 120000}},
               {"id": "sample-quiet", "today": {"cost": 0, "tokens": 0}}],
             "conversations": [
               {"id": 9001, "title": "Plan the watering schedule", "cost": 4.1, "tokens": 1210000},
               {"id": 9002, "title": "Fix the sensor readings", "cost": 3.7, "tokens": 820000},
               {"id": 9003, "title": "", "cost": 0.3, "tokens": 41000}],
             "total": {"cost": \(todayCost + 21.4), "tokens": 3120000},
             "today": {"cost": \(todayCost), "tokens": 510000},
             "days": [
               {"day": "\(day(12))", "cost": 0.4, "tokens": 120000},
               {"day": "\(day(9))", "cost": 1.1, "tokens": 260000},
               {"day": "\(day(6))", "cost": 0.8, "tokens": 310000},
               {"day": "\(day(5))", "cost": 0.0, "tokens": 180000},
               {"day": "\(day(3))", "cost": 2.4, "tokens": 420000},
               {"day": "\(day(2))", "cost": 1.6, "tokens": 300000},
               {"day": "\(day(1))", "cost": 0.84, "tokens": 248000},
               {"day": "\(day(0))", "cost": \(todayCost), "tokens": 510000}],
             "budget": {"daily": 5},
             "overBudget": \(over)}
            """
        let limits = """
            {"providers": [
               {"id": "anthropic", "name": "Anthropic", "plan": "Max", "reports": "usage", "source": "usage", "fetchedAt": \(ms - 0.2 * hour),
                "windows": [
                  {"id": "five-hour", "label": "5-hour window", "usedPercent": 62, "resetsAt": \(ms + 2.25 * hour)},
                  {"id": "week", "label": "This week", "usedPercent": 91.4, "resetsAt": \(ms + 76 * hour)}]},
               {"id": "openai", "name": "OpenAI", "plan": "Pro", "reports": "usage", "source": "usage", "fetchedAt": \(ms - 3 * hour),
                "error": "Could not read the limits: the provider did not answer.", "errorAt": \(ms - 0.1 * hour),
                "windows": [
                  {"id": "week", "label": "Weekly", "usedPercent": 100, "resetsAt": \(ms - 0.5 * hour)}]},
               {"id": "codex", "name": "Codex", "plan": null, "reports": "responses", "windows": []},
               {"id": "gemini", "name": "Google Gemini", "plan": null, "reports": "none"}],
             "notices": []}
            """
        let models = """
            [{"provider": "anthropic", "providerName": "Anthropic", "id": "claude-sonnet", "name": "Claude Sonnet", "thinkingLevels": []},
             {"provider": "openai", "providerName": "OpenAI", "id": "gpt-5", "name": "GPT-5", "thinkingLevels": []}]
            """
        func agent(_ id: String, _ name: String, _ color: String, project: String) -> String {
            """
            {"id": "\(id)", "name": "\(name)", "description": "", "color": "\(color)", "instructions": "", "access": "full",
             "delegates": [], "createdAt": 0, "projectId": "\(project)"}
            """
        }
        let agents = "[\(agent("sample-orchestrator", "Orchestrator", "green", project: "sample-garden")), \(agent("sample-forge", "Forge", "orange", project: "sample-garden")), \(agent("sample-scout", "Scout", "blue", project: "sample-taxes")), \(agent("sample-taxes-orchestrator", "Orchestrator", "pink", project: "sample-taxes"))]"
        func project(_ id: String, _ name: String, orchestrator: String, limit: String) -> String {
            """
            {"id": "\(id)", "name": "\(name)", "folder": null, "repository": null, "orchestratorId": "\(orchestrator)",
             "conversation": null, "archivedAt": null, "deletedAt": null, "lastWords": null, "ruleTokens": null,
             "settings": {"withoutAsking": null, "wakeOnReports": false, "limits": {"planShare": null, "dailySpend": \(limit)}}}
            """
        }
        let projects = "[\(project("sample-garden", "Garden sensors", orchestrator: "sample-orchestrator", limit: "4")), \(project("sample-taxes", "Taxes 2026", orchestrator: "sample-taxes-orchestrator", limit: "null")), \(project("sample-quiet", "Quiet project", orchestrator: "sample-orchestrator", limit: "null"))]"

        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
            try? decoder.decode(type, from: Data(text.utf8))
        }
        return UsageReading(
            usage: decode(UsageSummary.self, usage),
            providers: UsageLimits.providers(decode(JSONValue.self, limits)),
            models: decode([ModelInfo].self, models) ?? [],
            agents: decode([AgentProfile].self, agents) ?? [],
            projects: decode([ProjectRow].self, projects) ?? []
        )
    }
}

/// What a debug build's environment asks Usage to do once it shows, so that a state reached by a tap can be pictured in
/// the simulator without one (docs/iphone-app.md, "Drawing a screen and picturing it"). Each sends the real request,
/// through the same client, and shows what the engine answers: against the recorded session, its refusal.
///
/// - `PI2_USAGE_ACT=budget:<amount>`: types the amount in the budget's field and taps Set Budget. `remove`: taps Remove
///   Limit. `refresh` or `refresh:<id>`: taps Check Now on the first subscription, or the one of that id.
/// - `PI2_USAGE_SCROLL=<section>`: scrolls to `spending`, `plans`, `budget`, `budget-problem`, `days`, `projects`,
///   `models`, `agents`, `conversations` or `note`.
enum UsageDebug {
    static let act = ProcessInfo.processInfo.environment["PI2_USAGE_ACT"]
    static let scrollTarget = ProcessInfo.processInfo.environment["PI2_USAGE_SCROLL"]

    @MainActor private static var done: Set<String> = []

    /// What follows `name:` (empty when nothing does) if `name` was asked for and not done yet; marks it done.
    @MainActor static func take(_ name: String) -> String? {
        guard let act, act == name || act.hasPrefix(name + ":"), !done.contains(name) else { return nil }
        done.insert(name)
        return act == name ? "" : String(act.dropFirst(name.count + 1))
    }

    /// Scrolls the page to the section `PI2_USAGE_SCROLL` names, once an act has had a moment to be answered.
    @MainActor static func scroll(_ scroller: ScrollViewProxy) async {
        guard let scrollTarget else { return }
        // Long enough for the engine's events and an act's answer to be drawn; a picture aid, not a test.
        try? await Task.sleep(for: .seconds(1.5))
        scroller.scrollTo(scrollTarget, anchor: .top)
    }
}
#endif
