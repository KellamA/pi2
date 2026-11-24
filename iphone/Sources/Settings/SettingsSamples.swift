#if DEBUG
import Foundation
import PiModels
import SwiftUI

/// A debug build's sample values, for drawing and picturing the states the recorded session lacks (it has no schedule,
/// no plan read, no spending, and its projects have no repository) before the demo mode (#684) or a Mac can send them.
/// None of it is compiled into a release build, and nothing here answers: a control drawn over a sample sends its real
/// request through the session's client, which the recording refuses, and the screen shows that refusal. The screens say
/// the samples are there.
///
/// `PI2_SETTINGS_SAMPLES=all`, or a list of `schedules,plan,spend,project,archived`, read at launch (`xcrun simctl
/// launch` passes `SIMCTL_CHILD_<NAME>` as `<NAME>`):
///
/// - `schedules`: five schedules over the recording's agents, one held, one off, one an agent set.
/// - `plan`: two plan windows read, one of them most used.
/// - `spend`: today's spending of each project.
/// - `project`: every project with a repository attached, a daily limit, and reports waking the orchestrator.
/// - `archived`: every project archived, its folder gone.
///
/// `PI2_SETTINGS_SCROLL=<section>` opens a settings screen scrolled to that section (`phone`, `mac`, `chat`, `commits`,
/// `more`, `onlyMac`; `project`, `repository`, `orchestrator`, `switches`, `reports`, `limits`, `schedules`,
/// `lifecycle`), for a picture of what is below the screen. `PI2_SETTINGS_PRESS=<row>` makes one change once the screen
/// has drawn, as a tap would, so that the engine's answer to it can be pictured: `awake` (Settings), `reports` (a
/// project's), `run` (the first schedule, on Schedules), `live-activity` (a project's Live Activity switch, turned on; with
/// `PI2_LIVE_ACTIVITY_SWITCH=off-in-ios`, drawn as while iOS has Live Activities off).
struct SettingsSamples {
    let names: Set<String>

    static let current: SettingsSamples? = {
        guard let value = ProcessInfo.processInfo.environment["PI2_SETTINGS_SAMPLES"], !value.isEmpty else { return nil }
        let all: Set<String> = ["schedules", "plan", "spend", "project"]
        let names = value == "all" ? all : Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return SettingsSamples(names: names)
    }()

    static let scroll: String? = ProcessInfo.processInfo.environment["PI2_SETTINGS_SCROLL"]
    static let press: String? = ProcessInfo.processInfo.environment["PI2_SETTINGS_PRESS"]
    /// `PI2_SETTINGS_OPEN=new` or a schedule's id: the schedule sheet, opened on Schedules once it has drawn.
    static let open: String? = ProcessInfo.processInfo.environment["PI2_SETTINGS_OPEN"]
    /// Whether `press` was done, and `open`: each once a launch.
    @MainActor static var pressed = false
    @MainActor static var opened = false

    /// Whether to make the change named `row` now: once a launch, once its screen has what it changes.
    @MainActor
    static func shouldPress(_ row: String) -> Bool {
        guard press == row, !pressed else { return false }
        pressed = true
        return true
    }

    func lay(over source: inout SettingsSource) {
        let now = Date()
        if names.contains("schedules") {
            source.schedules += Self.schedules(agents: source.agents, projects: source.projects, now: now)
            source.samples.append("schedules")
        }
        if names.contains("plan") {
            source.plan = Self.plan(now: now)
            source.samples.append("plan windows")
        }
        if names.contains("spend") {
            source.spentToday = Dictionary(source.projects.enumerated().map { ($0.element.id, [3.42, 0.87][$0.offset % 2]) }, uniquingKeysWith: { a, _ in a })
            source.samples.append("today's spending")
        }
        if names.contains("project") || names.contains("archived") {
            let archived = names.contains("archived")
            source.projects = source.projects.compactMap { Self.project($0, archived: archived, now: now) }
            source.samples.append(archived ? "archived projects" : "project settings")
        }
    }

    /// What the screen says while samples are shown.
    @MainActor @ViewBuilder
    static func note(_ source: SettingsSource) -> some View {
        if !source.samples.isEmpty {
            Label("Debug build: sample \(source.samples.joined(separator: ", ")) drawn over the Mac's (PI2_SETTINGS_SAMPLES). Changes go to the engine like any other.", systemImage: "hammer")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Scrolls to `PI2_SETTINGS_SCROLL`'s section once the screen has drawn.
    @MainActor
    static func scroll(_ proxy: ScrollViewProxy) async {
        guard let scroll else { return }
        try? await Task.sleep(for: .seconds(1))
        proxy.scrollTo(scroll, anchor: .top)
    }

    static func plan(now: Date) -> [SettingsPlanWindow] {
        [
            SettingsPlanWindow(providerName: "Anthropic", plan: "Max", label: "5 hours", usedPercent: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
            SettingsPlanWindow(providerName: "Anthropic", plan: "Max", label: "week", usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ]
    }

    static func schedules(agents: [AgentProfile], projects: [ProjectRow], now: Date) -> [Schedule] {
        let ms = now.timeIntervalSince1970 * 1000
        let calendar = Calendar.current
        /// The next moment on the clock that matches, in milliseconds, as the engine works out `nextRunAt`.
        func next(_ components: DateComponents) -> Double? {
            calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime).map { $0.timeIntervalSince1970 * 1000 }
        }
        let first = projects.first
        let orchestrator = first?.orchestratorId
        let scout = agents.first { $0.projectId == first?.id && $0.name == "Scout" }?.id
        let forge = agents.first { $0.projectId == first?.id && $0.name == "Forge" }?.id
        let second = projects.dropFirst().first?.orchestratorId
        let template = agents.first { $0.projectId == nil }?.id
        var schedules: [Schedule] = []
        if let orchestrator {
            schedules.append(Schedule(id: "sample-morning", title: "Morning brief", agentId: orchestrator,
                                      prompt: "Read what finished overnight and say what needs me first.",
                                      repeat: Repeat(kind: "daily", hour: 7, minute: 30), enabled: true, nextRunAt: next(DateComponents(hour: 7, minute: 30)), lastConversationId: 9))
        }
        if let scout {
            schedules.append(Schedule(id: "sample-links", title: "Check the site's links", agentId: scout,
                                      prompt: "Run the link checker over the built site and file work for each broken link.",
                                      repeat: Repeat(kind: "weekly", hour: 9, minute: 0, weekday: 1), enabled: true, nextRunAt: next(DateComponents(hour: 9, minute: 0, weekday: 2)),
                                      createdBy: orchestrator.flatMap { Self.creator(agentID: $0, conversation: 9) }))
        }
        if let forge {
            schedules.append(Schedule(id: "sample-deps", title: "Update dependencies", agentId: forge,
                                      prompt: "Update the site's dependencies on a branch and open a pull request if the tests pass.",
                                      repeat: Repeat(kind: "interval", minutes: 360), enabled: false))
        }
        if let second {
            schedules.append(Schedule(id: "sample-held", title: "Nightly walkthrough", agentId: second,
                                      prompt: "Go through the walkthrough and note what changed.",
                                      repeat: Repeat(kind: "daily", hour: 22, minute: 0), enabled: true,
                                      holdReason: "the project's daily limit of $5 is reached"))
        }
        if let template {
            schedules.append(Schedule(id: "sample-once", title: "Draft the release notes", agentId: template,
                                      prompt: "Draft the release notes from the merged pull requests.",
                                      repeat: Repeat(kind: "once", at: ms + 2 * 86_400_000), enabled: true, nextRunAt: ms + 2 * 86_400_000))
        }
        return schedules
    }

    /// An agent's mark on a schedule it set, as the `schedules` event sends it.
    static func creator(agentID: String, conversation: Int) -> Schedule.Creator? {
        try? JSONDecoder().decode(Schedule.Creator.self, from: Data(#"{"agentId":"\#(agentID)","conversationId":\#(conversation)}"#.utf8))
    }

    /// A project as the `projects` event would send it, with a repository, limits and reports set, or archived.
    static func project(_ project: ProjectRow, archived: Bool, now: Date) -> ProjectRow? {
        var object: [String: Any] = [
            "id": project.id, "name": project.name, "orchestratorId": project.orchestratorId,
            "folder": project.folder as Any? ?? NSNull(),
            "repository": ["owner": "demo", "name": project.name.lowercased().replacingOccurrences(of: " ", with: "-")],
            "settings": [
                "wakeOnReports": true,
                "withoutAsking": ["startAgents": true, "fileWork": true, "closeWork": true, "makeAgents": false, "addRules": true,
                                  "merge": false, "release": false, "passLimits": false],
                "limits": ["planShare": 80, "dailySpend": 5],
            ],
        ]
        if let conversation = project.conversation { object["conversation"] = conversation }
        if archived {
            object["archivedAt"] = now.timeIntervalSince1970 * 1000
            object["folderMissing"] = true
            object["repository"] = NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ProjectRow.self, from: data)
    }
}
#endif
