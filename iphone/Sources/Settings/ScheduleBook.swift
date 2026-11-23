import Foundation
import PiModels

/// The schedules, read as the Mac reads them (app/Sources/pi2/ScheduleViews.swift; docs/schedules.md, and in a project
/// docs/projects.md 3.13): which agent each runs as, which project it belongs to, and the words of its row. Built from
/// plain values so that a test can give it any.
struct ScheduleBook {
    let schedules: [Schedule]
    /// Every agent, the projects' own included.
    let agents: [AgentProfile]
    let projects: [ProjectRow]
    /// The conversations the Mac lists now, by id: a schedule's last run is offered only while it is there.
    let conversations: Set<Int>

    /// The schedules of one place: a project's, or with no project the templates'.
    struct Group: Identifiable, Equatable {
        /// The project's id, or nil for the templates'.
        let projectID: String?
        let title: String
        let schedules: [Schedule]
        var id: String { projectID ?? "" }
    }

    func agent(_ id: String?) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    /// The agent a schedule runs as, by the engine's rule (`scheduleRunsAs`): the project's copy it was carried to while
    /// that copy can still be used, else its own agent.
    func runsAs(_ schedule: Schedule) -> String {
        guard let id = schedule.projectAgentId, let copy = agent(id), copy.removedAt == nil else { return schedule.agentId }
        if let project = copy.projectId, projects.first(where: { $0.id == project })?.deletedAt != nil { return schedule.agentId }
        return id
    }

    /// A project's schedules: those whose agent, as they run, is one of its agents (3.13).
    func schedules(ofProject id: String) -> [Schedule] {
        schedules.filter { agent(runsAs($0))?.projectId == id }
    }

    /// Every schedule, by place: each project that has some, in the order the Mac lists the projects, then the
    /// templates' and those whose agent is gone.
    var groups: [Group] {
        var groups = projects.filter { $0.deletedAt == nil }.compactMap { project -> Group? in
            let own = schedules(ofProject: project.id)
            return own.isEmpty ? nil : Group(projectID: project.id, title: project.name, schedules: own)
        }
        let placed = Set(groups.flatMap { $0.schedules.map(\.id) })
        let rest = schedules.filter { !placed.contains($0.id) }
        if !rest.isEmpty { groups.append(Group(projectID: nil, title: "Templates", schedules: rest)) }
        return groups
    }

    /// The agents a new schedule in a project may be given: the orchestrator first, then the rest as made.
    func agents(ofProject id: String) -> [AgentProfile] {
        let orchestrator = projects.first { $0.id == id }?.orchestratorId
        return agents
            .filter { $0.projectId == id && $0.removedAt == nil }
            .sorted { ($0.id == orchestrator ? 0 : 1, $0.createdAt) < ($1.id == orchestrator ? 0 : 1, $1.createdAt) }
    }

    /// The agents a schedule may be given anywhere: each project's, then the templates.
    var everyAgent: [AgentProfile] {
        projects.filter { $0.deletedAt == nil && $0.archivedAt == nil }.flatMap { agents(ofProject: $0.id) }
            + agents.filter { $0.projectId == nil && $0.removedAt == nil }
    }

    /// The conversation its last run started, while the Mac still lists it.
    func lastRun(_ schedule: Schedule) -> Int? {
        schedule.lastConversationId.flatMap { conversations.contains($0) ? $0 : nil }
    }

    /// Whether it will run by itself: on, and held by nothing.
    func isActive(_ schedule: Schedule) -> Bool {
        schedule.enabled && schedule.holdReason == nil
    }

    /// "Forge · Every day at 07:00 · next 22 Nov 2026 at 07:00 · set by Forge", as the Mac's row says it.
    func detail(_ schedule: Schedule) -> String {
        let agent = agent(runsAs(schedule))?.name ?? "Unknown agent"
        // The person approved an agent's schedule once, perhaps long ago; this tells it apart from the ones they made.
        let setBy = schedule.createdBy.map { " · set by \(self.agent($0.agentId)?.name ?? "a deleted agent")" } ?? ""
        if let reason = schedule.holdReason { return "\(agent) · Held: \(reason)\(setBy)" }
        guard schedule.enabled, let next = schedule.nextRunAt else { return "\(agent) · \(schedule.repeat.summary) · off\(setBy)" }
        let when = Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened)
        return "\(agent) · \(schedule.repeat.summary) · next \(when)\(setBy)"
    }
}
