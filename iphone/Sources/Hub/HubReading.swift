import EngineKit
import Foundation
import PiModels

// What a project's hub and the Dashboard's pages read of the engine's state (docs/design/iphone.md, "A project's hub"
// and "The Dashboard on a phone"): the same readings the Mac's Now tab and Dashboard columns make
// (app/Sources/pi2/ProjectNowTab.swift, DashboardView.swift), from `session.engine`. Nothing here is kept: each is read
// again as the engine's events change it.

extension EngineSession {
    /// A project the phone can show: in the `projects` event, and not deleted (the Mac's `EngineClient.project(_:)`).
    func hubProject(_ id: String) -> ProjectRow? {
        projects.first { $0.id == id && $0.deletedAt == nil }
    }

    /// The projects the Mac's sidebar lists, in its order: not archived, not deleted.
    var hubListedProjects: [ProjectRow] {
        projects.filter { $0.archivedAt == nil && $0.deletedAt == nil }
    }

    /// What waits for the person in one project, as the `needs` event lists it.
    func hubNeeds(_ project: String) -> [NeedItem] {
        needs.filter { $0.projectId == project }
    }

    /// The project's runs, its orchestrator's and its sub-chats' included, oldest first as the engine lists them; chats
    /// are left out, as on the Mac's Now tab.
    func hubRuns(_ project: String) -> [ActivityRun] {
        activity.filter { $0.projectId == project && $0.chat != true }
    }

    /// What finished in the project since midnight, newest first, from the `reports` event (docs/projects.md, 3.10).
    func hubReports(_ project: String, now: Date = .now) -> [HubReport] {
        HubReport.today(extras["reports"]?["projects"]?[project], now: now)
    }

    /// The name of the model an agent runs on: its own, else the default; by the name its provider gives, else its id.
    func hubModelName(agent id: String?) -> String? {
        guard let ref = agent(id)?.model ?? defaultModel else { return nil }
        return allModels.first { $0.ref == ref }?.name ?? ref.modelId
    }

    /// The branch the project's orchestrator's folder is on, when it works in a git repository.
    func hubBranch(_ project: ProjectRow) -> String? {
        project.conversation.flatMap { branches[$0]?.branch }
    }

    /// Whether the orchestrator is answering now.
    func hubOrchestratorBusy(_ project: ProjectRow) -> Bool {
        guard let id = project.conversation else { return false }
        return conversations.first { $0.id == id }?.busy == true
    }

    /// The plan's week, as the busiest subscription that reports one says it (the `limits` event); nil when none does.
    /// The event is read once for both apps, as the shared `PlanLimits` (#861).
    func hubPlanWeek(now: Date = .now) -> HubPlanWeek? {
        HubPlanWeek.read(PlanLimits(extras["limits"]), now: now)
    }
}

/// One report as the engine's `reports` event sends it (docs/projects.md, 3.10): how a run the orchestrator handed out
/// ended, and whether the orchestrator has been given it yet. The Mac reads it as `ProjectReport`.
struct HubReport: Identifiable, Equatable {
    let submissionId: Int
    let agentId: String
    let title: String
    /// Nil while the run goes on.
    let endedAt: Date?
    /// "answered", "failed" or "stopped".
    let outcome: String?
    /// How the orchestrator was given it ("wake", "wait" or "read"); nil while it waits to be read.
    let deliveredBy: String?
    var id: Int { submissionId }

    init?(_ item: JSONValue) {
        guard let submissionId = item["submissionId"]?.intValue,
              let agentId = item["agentId"]?.stringValue,
              let title = item["title"]?.stringValue else { return nil }
        self.submissionId = submissionId
        self.agentId = agentId
        self.title = title
        if case .number(let milliseconds)? = item["ended"]?["at"] {
            endedAt = Date(timeIntervalSince1970: milliseconds / 1000)
        } else {
            endedAt = nil
        }
        outcome = item["ended"]?["outcome"]?.stringValue
        deliveredBy = item["delivered"]?["by"]?.stringValue
    }

    /// The reports of one project that ended since midnight, newest first.
    static func today(_ value: JSONValue?, now: Date, calendar: Calendar = .current) -> [HubReport] {
        let midnight = calendar.startOfDay(for: now)
        return (value?.arrayValue ?? []).compactMap(HubReport.init)
            .filter { $0.endedAt.map { $0 >= midnight } == true }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// How the run ended, in a word.
    var outcomeWord: String {
        switch outcome {
        case "answered": "done"
        case "failed": "failed"
        case "stopped": "stopped"
        default: outcome ?? "ended"
        }
    }
}

/// The plan's week for the hub's bar: a subscription's weekly window, as the `limits` event reports it. The numbers
/// come from the shared `PlanLimits` (#861); nil when there is no event that reads.
struct HubPlanWeek: Equatable {
    /// The subscription's name, such as "Anthropic Max".
    let plan: String
    /// 0 to 100.
    let usedPercent: Double

    /// The week window of the subscription that has used most of its week, among those whose window has not reset.
    static func read(_ limits: PlanLimits?, now: Date) -> HubPlanWeek? {
        var best: HubPlanWeek?
        for provider in limits?.providers ?? [] {
            let name = [provider.name, provider.plan].compactMap { $0 }.joined(separator: " ")
            for window in provider.windows ?? [] {
                guard window.label.lowercased().contains("week") else { continue }
                if let resets = window.resetsAt, LimitsFormat.date(resets) <= now { continue }
                let week = HubPlanWeek(plan: name, usedPercent: min(max(window.usedPercent, 0), 100))
                if week.usedPercent > best?.usedPercent ?? -1 { best = week }
            }
        }
        return best
    }
}

/// How long a run has gone on, as the Mac's working row's clock says it: "4:07", or "2h 05m" past an hour.
enum HubClock {
    static func text(since milliseconds: Double, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - milliseconds / 1000))
        return seconds < 3600
            ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : String(format: "%dh %02dm", seconds / 3600, seconds % 3600 / 60)
    }

    /// The same, in words for VoiceOver: "for 4 minutes", "for 2 hours 5 minutes".
    static func spoken(since milliseconds: Double, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - milliseconds / 1000)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds < 60 ? [.second] : [.hour, .minute]
        return formatter.string(from: seconds).map { "for \($0)" } ?? ""
    }
}
