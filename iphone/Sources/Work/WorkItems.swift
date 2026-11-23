import EngineKit
import Foundation
import PiModels

// What the Work screens read of the engine's state: the `work` event's list kept by pi², or the `github` event's issues
// and pull requests for a project with a repository attached (docs/projects.md, 3.11 and 4.3). The readings themselves
// are shared in `PiModels` (Work.swift, GitHubWork.swift, #828): the limit a start past the project's limit carries is
// read by the shared `WorkLimit` below. `WorkItem`, `WorkPull`, `WorkUnknownWrite` and their container `WorkListing`
// stay the phone's own, because they read a missing time as the distant past where the shared readings take 0 ms since
// 1970 — a difference only a malformed event could show, kept as it is until one reading is chosen for both (#828).

/// One piece of work, or one issue of an attached repository, as the Mac's `WorkPiece` reads it.
struct WorkItem: Identifiable, Equatable {
    struct Note: Equatable {
        let at: Date
        /// The agent that wrote it; nil for the person.
        let agentId: String?
        let text: String
    }

    let id: Int
    let title: String
    let text: String
    /// Where it is (the state table's word), and who has it: what a change on its way shows at once (`showing`).
    private(set) var state: String
    /// The class of model it needs, "local" or "cloud"; nil when not classified.
    let modelClass: String?
    /// The agent working on it, and the sub-chat it works in; nil when nobody has it.
    private(set) var holderAgentId: String?
    private(set) var holderConversation: Int?
    let notes: [Note]
    /// What finishing it said was done.
    let result: String?
    let updatedAt: Date
    /// An issue's address on GitHub.
    let url: String?
    /// An issue of which only what its row shows was read, until it is read whole (`github.show`).
    let partial: Bool

    init?(_ value: JSONValue?) {
        guard let value, let id = value["id"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        let taken = value["takenBy"]
        self.id = id
        self.title = title
        text = value["text"]?.stringValue ?? ""
        state = value["state"]?.stringValue ?? "open"
        modelClass = value["class"]?.stringValue
        holderAgentId = taken?["agentId"]?.stringValue
        holderConversation = taken?["conversationId"]?.intValue
        notes = (value["notes"]?.arrayValue ?? []).compactMap { note in
            guard let text = note["text"]?.stringValue else { return nil }
            return Note(at: WorkTime.date(note["at"]) ?? .distantPast, agentId: note["by"]?["agentId"]?.stringValue, text: text)
        }
        result = value["result"]?.stringValue
        updatedAt = WorkTime.date(value["updatedAt"]) ?? .distantPast
        url = value["url"]?.stringValue
        partial = value["partial"] == .bool(true)
    }

    /// Nobody has it, and it is open: what can be given to an agent from its row.
    var givable: Bool { state == "open" && holderAgentId == nil }
    /// An agent holds it, working or not.
    var held: Bool { WorkState.held.contains(state) }
    var closed: Bool { WorkState.closed.contains(state) }

    /// The item as it will be once the change on its way is made, shown at once until the engine says how it went.
    func showing(_ change: WorkChange?) -> WorkItem {
        guard let change, let state = change.state else { return self }
        var shown = self
        shown.state = state
        if change.letsGo {
            shown.holderAgentId = nil
            shown.holderConversation = nil
        } else if let agent = change.holderAgentId {
            shown.holderAgentId = agent
            shown.holderConversation = nil
        }
        return shown
    }
}

/// The state table's states (docs/projects.md, 3.11), in its order, with the words the Mac's Work tab shows for each.
enum WorkState {
    static let all: [(state: String, name: String)] = [
        ("open", "Open"), ("in_progress", "In progress"), ("waiting", "Waiting"),
        ("blocked", "Blocked"), ("done", "Done"), ("dropped", "Dropped"),
    ]
    static let held: Set<String> = ["in_progress", "waiting", "blocked"]
    static let closed: Set<String> = ["done", "dropped"]

    /// The word for a state; one the phone does not know reads as the engine sent it.
    static func name(_ state: String) -> String {
        all.first { $0.state == state }?.name ?? state
    }
}

/// A change the person asked for that the engine has not answered yet, as the Mac's `WorkPending`: the words that say so
/// where the item shows, and the state it takes the item to, shown at once.
struct WorkChange: Equatable {
    /// "Closing", "Giving to Forge".
    let word: String
    var state: String?
    /// The agent it is given to.
    var holderAgentId: String?
    /// It goes back to nobody.
    var letsGo = false

    /// What an action of the state table shows while it is on its way.
    static func of(_ action: String, as closing: String? = nil) -> WorkChange {
        switch action {
        case "close": WorkChange(word: "Closing", state: closing == "dropped" ? "dropped" : "done", letsGo: true)
        case "reopen": WorkChange(word: "Reopening", state: "open", letsGo: true)
        case "release": WorkChange(word: "Releasing", state: "open", letsGo: true)
        case "resume": WorkChange(word: "Resuming", state: "in_progress")
        case "classify": WorkChange(word: "Classifying")
        case "edit": WorkChange(word: "Saving")
        case "note": WorkChange(word: "Adding a note")
        default: WorkChange(word: "Working")
        }
    }
}

/// A pull request of the attached repository, with what its row in the list shows: the Mac's `GitHubPull`, read only as
/// far as the list needs. Its own screen (#695) reads it whole.
struct WorkPull: Identifiable, Equatable {
    struct Finding: Equatable {
        let agentName: String
        /// "approve", "changes" or "comment".
        let verdict: String
        let at: Date
    }

    let number: Int
    let title: String
    /// "open", "merged" or "closed".
    let state: String
    let draft: Bool
    /// "passing", "failing", "pending" or "none".
    let checks: String
    let failingChecks: Int
    /// "yes", "no" or "unknown".
    let mergeable: String
    /// What a reviewing agent last found.
    let newestFinding: Finding?
    /// The work item it fixes, from "Fixes #N" in its text.
    let work: Int?

    var id: Int { number }

    init?(_ value: JSONValue?) {
        guard let value, let number = value["number"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        self.number = number
        self.title = title
        state = value["state"]?.stringValue ?? "open"
        draft = value["draft"] == .bool(true)
        checks = value["checks"]?.stringValue ?? "none"
        failingChecks = value["failingChecks"]?.arrayValue?.count ?? 0
        mergeable = value["mergeable"]?.stringValue ?? "unknown"
        newestFinding = (value["findings"]?.arrayValue ?? []).compactMap { finding -> Finding? in
            guard let agentName = finding["agentName"]?.stringValue else { return nil }
            return Finding(agentName: agentName, verdict: finding["verdict"]?.stringValue ?? "comment",
                           at: WorkTime.date(finding["at"]) ?? .distantPast)
        }.max { $0.at < $1.at }
        work = value["work"]?.intValue
    }

    /// "Checks passing", "2 checks failing", "Checks running", "No checks": as the Mac's `checksWords`.
    var checksWords: String {
        switch checks {
        case "passing": "Checks passing"
        case "failing": "\(failingChecks) \(failingChecks == 1 ? "check" : "checks") failing"
        case "pending": "Checks running"
        default: "No checks"
        }
    }

    /// The word on its row's tag: where it stands, as the design's "PR · ready".
    var standing: String {
        switch state {
        case "merged": "merged"
        case "closed": "closed"
        default:
            if draft { "draft" }
            else if checks == "failing" { "checks failing" }
            else if checks == "pending" { "checks running" }
            else if newestFinding?.verdict == "changes" { "changes asked" }
            else if mergeable == "no" { "conflicts" }
            else { "ready" }
        }
    }

    /// "approved", "asked for changes" or "left a finding": the Mac's words for a verdict.
    static func verdictWords(_ verdict: String) -> String {
        switch verdict {
        case "approve": "approved"
        case "changes": "asked for changes"
        default: "left a finding"
        }
    }
}

/// A write of pi²'s to GitHub whose outcome could not be told (docs/projects.md, 3.11), for the person to settle: the
/// Mac's `GitHubUnknownWrite`.
struct WorkUnknownWrite: Identifiable, Equatable {
    let intent: String
    let summary: String
    let at: Date

    var id: String { intent }

    init?(_ value: JSONValue?) {
        guard let value, let intent = value["intent"]?.stringValue else { return nil }
        self.intent = intent
        summary = value["summary"]?.stringValue ?? "a write"
        at = WorkTime.date(value["at"]) ?? .distantPast
    }
}

/// A project's work as the phone shows it: the list pi² keeps, or an attached repository's issues and pull requests,
/// with how its last read went.
struct WorkListing: Equatable {
    /// Where the list comes from.
    enum Source: Equatable {
        /// The list pi² itself keeps for the project.
        case kept
        /// An attached repository, as "owner/name".
        case github(String)
    }

    let source: Source
    /// Whether the event that carries the list has come yet.
    let arrived: Bool
    let items: [WorkItem]
    let pulls: [WorkPull]
    let unknown: [WorkUnknownWrite]
    /// GitHub only: "ok", "loading", "signed_out", "unreachable" or "rate_limited".
    let state: String
    let error: String?
    let readAt: Date?
    /// A read under way behind the list.
    let reading: Bool

    init(source: Source, arrived: Bool, items: [WorkItem], pulls: [WorkPull] = [], unknown: [WorkUnknownWrite] = [],
         state: String = "ok", error: String? = nil, readAt: Date? = nil, reading: Bool = false) {
        self.source = source
        self.arrived = arrived
        self.items = items
        self.pulls = pulls
        self.unknown = unknown
        self.state = state
        self.error = error
        self.readAt = readAt
        self.reading = reading
    }

    /// The list pi² keeps, from the `work` event (`nil` until it has come).
    static func kept(_ event: JSONValue?, project: String) -> WorkListing {
        WorkListing(source: .kept, arrived: event != nil,
                    items: (event?["projects"]?[project]?.arrayValue ?? []).compactMap(WorkItem.init))
    }

    /// An attached repository's, from the `github` event (`nil` until it has come), as the Mac's `GitHubWork` reads it.
    static func github(_ event: JSONValue?, project: String, repository: String) -> WorkListing {
        let value = event?["projects"]?[project]
        return WorkListing(
            source: .github(repository), arrived: event != nil,
            items: (value?["issues"]?.arrayValue ?? []).compactMap(WorkItem.init),
            pulls: (value?["pulls"]?.arrayValue ?? []).compactMap(WorkPull.init),
            unknown: (value?["unknown"]?.arrayValue ?? []).compactMap(WorkUnknownWrite.init),
            state: value?["state"]?.stringValue ?? "loading",
            error: value?["error"]?.stringValue,
            readAt: WorkTime.date(value?["readAt"]).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil },
            reading: value?["reading"] == .bool(true)
        )
    }

    var onGitHub: Bool { source != .kept }
    /// What the list calls a piece: "work" or "issue".
    var noun: String { onGitHub ? "issue" : "work" }
    /// What it calls a note on one: "note" or "comment".
    var noteWord: String { onGitHub ? "comment" : "note" }

    /// GitHub's last read left something wrong: the list stays as it was read, and nothing can be changed until it is
    /// read again.
    var troubled: Bool { ["signed_out", "unreachable", "rate_limited"].contains(state) }

    /// Nothing to show yet: the event has not come, or the repository's first read is under way.
    var firstRead: Bool { !arrived || (onGitHub && readAt == nil && !troubled) }

    /// What went wrong with GitHub's last read, and what the list under it holds, in the Mac's words; nil when nothing did.
    func troubleWords(now: Date = .now) -> String? {
        guard troubled else { return nil }
        let read = readAt.map { "The last read, \(WorkTime.ago($0, now: now)), is below" } ?? "Nothing has been read yet"
        switch state {
        case "unreachable":
            return "GitHub cannot be reached. \(read); nothing here can change until it answers."
        case "signed_out":
            return (error ?? "").localizedCaseInsensitiveContains("not found")
                ? "GitHub's command-line tool gh is not installed on the Mac. \(read); nothing here can change until it is."
                : "gh is not signed in to GitHub on the Mac. \(read); nothing here can change until it is."
        default:
            return "GitHub's rate limit is reached. \(read); nothing here can change until the hour is up."
        }
    }

    func item(_ id: Int) -> WorkItem? { items.first { $0.id == id } }

    /// The list as one segment of the screen shows it: groups in the state table's order, each newest-changed first,
    /// with the empty ones left out; open pull requests lead the open work, and the merged or closed ones follow the
    /// closed work, as on the Mac.
    func sections(_ filter: WorkFilter) -> [WorkSection] {
        var sections: [WorkSection] = []
        let newest = pulls.sorted { $0.number > $1.number }
        if filter == .open {
            let open = newest.filter { $0.state == "open" }
            if !open.isEmpty { sections.append(WorkSection(id: "pulls", name: "Pull requests", rows: open.map(WorkRowEntry.pull))) }
        }
        for (state, name) in WorkState.all where filter.states.contains(state) {
            let inState = items.filter { $0.state == state }.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
            if !inState.isEmpty { sections.append(WorkSection(id: state, name: name, rows: inState.map(WorkRowEntry.item))) }
        }
        if filter == .done {
            let closed = newest.filter { $0.state != "open" }
            if !closed.isEmpty {
                sections.append(WorkSection(id: "closedPulls", name: "Pull requests merged or closed", rows: closed.map(WorkRowEntry.pull)))
            }
        }
        return sections
    }

    /// How many rows a segment holds, for its label.
    func count(_ filter: WorkFilter) -> Int {
        sections(filter).reduce(0) { $0 + $1.rows.count }
    }
}

/// The segments of the list (docs/design/iphone.md, "The Work tab"): what is still to be done, in every state an agent
/// can hold it in; what waits or is blocked, which often waits on the person; and what is closed.
enum WorkFilter: String, CaseIterable, Identifiable {
    case open, waiting, done

    var id: String { rawValue }

    var name: String {
        switch self {
        case .open: "Open"
        case .waiting: "Waiting"
        case .done: "Done"
        }
    }

    /// The states each holds.
    var states: Set<String> {
        switch self {
        case .open: ["open", "in_progress", "waiting", "blocked"]
        case .waiting: ["waiting", "blocked"]
        case .done: ["done", "dropped"]
        }
    }
}

/// One group of the list, under its heading.
struct WorkSection: Identifiable, Equatable {
    let id: String
    let name: String
    let rows: [WorkRowEntry]
}

/// One row of the list: a piece of work (or an issue), or a pull request.
enum WorkRowEntry: Identifiable, Equatable {
    case item(WorkItem)
    case pull(WorkPull)

    var id: String {
        switch self {
        case .item(let item): "item:\(item.id)"
        case .pull(let pull): "pull:\(pull.number)"
        }
    }
}

/// A start the project's limit refused, held until the person confirms that one start or leaves it (8.3). The limit
/// itself is the shared reading (`WorkLimit` in PiModels, from the refusal's `data.limit`, #828); the words of the
/// question are the phone's.
struct WorkHeldStart: Equatable, Identifiable {
    let item: WorkItem
    let agent: AgentProfile
    let limit: WorkLimit

    var id: String { "\(item.id)|\(agent.id)|\(limit.id)" }

    /// The Mac's words for it (`HeldStartCard`).
    var title: String { "Past the project's \(limit.name)" }
    var message: String {
        "Starting \(agent.name) on “\(item.title)” goes past it: \(limit.reason). Work already running carries on. Start it anyway?"
    }
}

/// The engine's times, milliseconds since 1970, and how long ago one was.
enum WorkTime {
    static func date(_ value: JSONValue?) -> Date? {
        guard case .number(let milliseconds)? = value else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago": the Mac's words (`LimitsFormat.ago`).
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) d ago"
    }
}

extension EngineSession {
    /// The project the Work screens show: in the `projects` event, and not deleted.
    func workProject(_ id: String) -> ProjectRow? {
        projects.first { $0.id == id && $0.deletedAt == nil }
    }

    /// The project's work: an attached repository's issues and pull requests, or the list pi² keeps.
    func workListing(_ project: ProjectRow) -> WorkListing {
        if let repository = project.repository {
            WorkListing.github(extras["github"], project: project.id, repository: "\(repository.owner)/\(repository.name)")
        } else {
            WorkListing.kept(extras["work"], project: project.id)
        }
    }

    /// The agents a piece of work can be given to, as the Mac's `workAgents`: the project's workers, not its orchestrator,
    /// which hands work out rather than takes it, and none an agent has removed, in the order the Agents tab shows them.
    func workAgents(_ project: ProjectRow) -> [AgentProfile] {
        allAgents
            .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}
