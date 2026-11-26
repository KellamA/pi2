import EngineKit
import Foundation
import PiModels

/// One change the settings screens send, made exactly as the Mac app makes it (each names the Mac's view it mirrors), so
/// that it works the day a real transport carries it. Everything a phone sends goes through the session's client; the
/// engine decides, and what it refuses is shown under the control that sent it.
struct SettingsRequest {
    let method: String
    let params: [String: Any]
    /// Said before the engine's refusal when the row it shows under does not name what was refused: on a list of
    /// schedules, which one ("“Morning brief” did not start: Past the project's limit…").
    var lead: String?

    init(method: String, params: [String: Any], lead: String? = nil) {
        self.method = method
        self.params = params
        self.lead = lead
    }

    // MARK: A project (ProjectSettingsTab.swift; the switches: ProjectAgentsTab.swift)

    static func rename(project: String, to name: String) -> SettingsRequest {
        SettingsRequest(method: "projects.rename", params: ["id": project, "name": name])
    }

    /// One part of a project's settings; the engine keeps every part it is not sent.
    static func projectSettings(_ project: String, _ part: [String: Any]) -> SettingsRequest {
        SettingsRequest(method: "projects.set", params: ["id": project, "settings": part])
    }

    static func wakeOnReports(project: String, on: Bool) -> SettingsRequest {
        projectSettings(project, ["wakeOnReports": on])
    }

    /// What the orchestrator may do without asking (docs/projects.md 8.1), one switch at a time.
    static func withoutAsking(project: String, _ name: String, on: Bool) -> SettingsRequest {
        projectSettings(project, ["withoutAsking": [name: on]])
    }

    /// The plan limit, a whole percent from 1 to 100; nil for none.
    static func planShare(project: String, _ percent: Int?) -> SettingsRequest {
        projectSettings(project, ["limits": ["planShare": percent.map { $0 as Any } ?? NSNull()]])
    }

    /// The daily spending limit, in dollars; nil for none.
    static func dailySpend(project: String, _ dollars: Double?) -> SettingsRequest {
        projectSettings(project, ["limits": ["dailySpend": dollars.map { $0 as Any } ?? NSNull()]])
    }

    /// Attaches a GitHub repository, `owner/name`, or with none the one the project's folder points at.
    static func attach(project: String, repository: String?) -> SettingsRequest {
        var params: [String: Any] = ["projectId": project]
        if let repository, !repository.isEmpty { params["repository"] = repository }
        return SettingsRequest(method: "github.attach", params: params)
    }

    static func detach(project: String) -> SettingsRequest {
        SettingsRequest(method: "github.detach", params: ["projectId": project])
    }

    static func archive(project: String) -> SettingsRequest {
        SettingsRequest(method: "projects.archive", params: ["id": project])
    }

    static func restore(project: String) -> SettingsRequest {
        SettingsRequest(method: "projects.unarchive", params: ["id": project])
    }

    static func delete(project: String) -> SettingsRequest {
        SettingsRequest(method: "projects.delete", params: ["id": project])
    }

    // MARK: The orchestrator's agent (HubConversationMenu.swift `setModel`, CompactionSettings.swift)

    /// The engine keeps every setting of the agent it is not sent, and the agent's project.
    static func agentModel(_ agent: AgentProfile, _ model: ModelRef) -> SettingsRequest {
        SettingsRequest(method: "agents.save", params: ["agent": ["id": agent.id, "name": agent.name, "model": ["provider": model.provider, "modelId": model.modelId]]])
    }

    /// nil uses the default for all agents; 0 is off.
    static func agentCompaction(_ agent: AgentProfile, _ tokens: Int?) -> SettingsRequest {
        SettingsRequest(method: "agents.save", params: ["agent": ["id": agent.id, "name": agent.name, "compactionTokens": tokens.map { $0 as Any } ?? NSNull()]])
    }

    // MARK: The app's settings (AwakeSettings, ArchiveViews, CompactionSettings, CoauthorSettings, ChatSettings)

    static func awake(keep: Bool, battery: Bool) -> SettingsRequest {
        SettingsRequest(method: "settings.setAwake", params: ["keep": keep, "battery": battery])
    }

    /// nil or 0 for never.
    static func autoArchive(days: Int?) -> SettingsRequest {
        SettingsRequest(method: "settings.setAutoArchive", params: ["days": days.flatMap { $0 == 0 ? nil : $0 as Any } ?? NSNull()])
    }

    static func compaction(_ tokens: Int?) -> SettingsRequest {
        SettingsRequest(method: "settings.setCompaction", params: ["defaultCompactionTokens": tokens.map { $0 as Any } ?? NSNull()])
    }

    static func coauthor(enabled: Bool) -> SettingsRequest {
        SettingsRequest(method: "coauthor.set", params: ["enabled": enabled])
    }

    static func coauthor(line: String) -> SettingsRequest {
        SettingsRequest(method: "coauthor.set", params: ["line": line])
    }

    static func chatInstructions(_ text: String) -> SettingsRequest {
        SettingsRequest(method: "chat.set", params: ["instructions": text])
    }

    /// nil for the model chosen last in a chat.
    static func chatModel(_ model: ModelRef?) -> SettingsRequest {
        SettingsRequest(method: "chat.set", params: ["defaultModel": model.map { ["provider": $0.provider, "modelId": $0.modelId] as Any } ?? NSNull()])
    }

    static func chatWeb(_ on: Bool) -> SettingsRequest {
        SettingsRequest(method: "chat.set", params: ["web": on])
    }

    static func chatMemory(_ on: Bool) -> SettingsRequest {
        SettingsRequest(method: "chat.set", params: ["memory": on])
    }

    // MARK: Schedules (ScheduleViews.swift)

    static func saveSchedule(_ schedule: Schedule, isNew: Bool) -> SettingsRequest {
        SettingsRequest(method: "schedules.save", params: ["schedule": schedule.payload(isNew: isNew)])
    }

    /// A schedule switched on or off, everything else as it is.
    static func setSchedule(_ schedule: Schedule, enabled: Bool) -> SettingsRequest {
        var changed = schedule
        changed.enabled = enabled
        var request = saveSchedule(changed, isNew: false)
        request.lead = "“\(schedule.title)” was not turned \(enabled ? "on" : "off")"
        return request
    }

    static func deleteSchedule(_ id: String, title: String? = nil) -> SettingsRequest {
        SettingsRequest(method: "schedules.delete", params: ["id": id], lead: title.map { "“\($0)” was not deleted" })
    }

    /// Never with `confirmLimit`: a run held by a limit is refused, and the refusal says so.
    static func runSchedule(_ id: String, title: String? = nil) -> SettingsRequest {
        SettingsRequest(method: "schedules.runNow", params: ["id": id], lead: title.map { "“\($0)” did not start" })
    }

    // MARK: Sending

    /// Sends it through the session's client. Nil when the engine took it; else the engine's words, or why it could not
    /// be sent.
    @MainActor
    func send(through engine: EngineSession<MessageField>) async -> String? {
        do {
            _ = try await engine.call(method, params)
            return nil
        } catch {
            return Self.refusal(error.localizedDescription, lead: lead)
        }
    }

    /// The engine's words, after the lead if there is one.
    static func refusal(_ words: String, lead: String?) -> String {
        guard let lead else { return words }
        return "\(lead): \(words)"
    }
}
