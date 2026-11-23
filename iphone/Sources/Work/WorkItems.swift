import EngineKit
import Foundation
import PiModels

// What the Work screens read of the engine's state is the shared reading in `PiModels` (#828, #868): the `work` event's
// list kept by pi² as `ProjectWork` holding `WorkPiece`s, the `github` event's issues and pull requests as `GitHubWork`
// holding `GitHubPull`s and `GitHubUnknownWrite`s. What stays here is only the phone's own: what a piece of work can be
// given and where a change on its way takes it, on `WorkPiece`; the word on a pull request's row, on `GitHubPull`; the
// list's shape as the screen shows it (`WorkListing`); and the phone's words for a state, a time and a start the
// project's limit held.

extension WorkPiece {
    /// Nobody has it, and it is open: what can be given to an agent from its row.
    var givable: Bool { state == "open" && holderAgentId == nil }
    /// An agent holds it, working or not.
    var held: Bool { WorkState.held.contains(state) }
    var closed: Bool { WorkState.closed.contains(state) }

    /// The piece as it will be once the change on its way is made, shown at once until the engine says how it went.
    /// `WorkChange` is this app's own view state, so the reading that takes it stays here with it.
    func showing(_ change: WorkChange?) -> WorkPiece {
        guard let change, let state = change.state else { return self }
        return showing(state: state, holderAgentId: change.holderAgentId, letsGo: change.letsGo)
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

/// A change the person asked for that the engine has not answered yet: the words that say so where the item shows, and
/// the state it takes the item to, shown at once.
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

extension GitHubPull {
    /// The word on its row's tag: where it stands, as the design's "PR · ready". Its own screen (#695) has its own
    /// words for the same reading (`PullRequestListing.swift`).
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
}

/// A project's work as the phone shows it: the list pi² keeps, or an attached repository's issues and pull requests,
/// with how its last read went. The reading itself is shared (`ProjectWork`, `GitHubWork`); this is the shape the two
/// screens draw — which event the list came from, whether it has come, and the segments the list is shown in.
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
    let items: [WorkPiece]
    let pulls: [GitHubPull]
    let unknown: [GitHubUnknownWrite]
    /// GitHub only: "ok", "loading", "signed_out", "unreachable" or "rate_limited".
    let state: String
    let error: String?
    let readAt: Date?
    /// A read under way behind the list.
    let reading: Bool

    init(source: Source, arrived: Bool, items: [WorkPiece], pulls: [GitHubPull] = [], unknown: [GitHubUnknownWrite] = [],
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

    /// The list pi² keeps, from the `work` event (`nil` until it has come), as the shared `ProjectWork` reads it.
    static func kept(_ event: JSONValue?, project: String) -> WorkListing {
        WorkListing(source: .kept, arrived: event != nil,
                    items: ProjectWork(event?["projects"]?[project]).items)
    }

    /// An attached repository's, from the `github` event (`nil` until it has come), as the shared `GitHubWork` reads it.
    static func github(_ event: JSONValue?, project: String, repository: String) -> WorkListing {
        let work = GitHubWork(event?["projects"]?[project])
        return WorkListing(
            source: .github(repository), arrived: event != nil,
            items: work.issues,
            pulls: work.pulls,
            unknown: work.unknown,
            state: work.state,
            error: work.error,
            readAt: work.readAt,
            reading: work.reading
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

    func item(_ id: Int) -> WorkPiece? { items.first { $0.id == id } }

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
    case item(WorkPiece)
    case pull(GitHubPull)

    var id: String {
        switch self {
        case .item(let item): "item:\(item.id)"
        case .pull(let pull): "pull:\(pull.number)"
        }
    }
}

/// A start the project's limit refused, held until the person confirms that one start or leaves it (8.3). The piece is
/// the shared reading (`WorkPiece`) and the limit the shared `WorkLimit` (both `PiModels`, #828); the words of the
/// question are the phone's.
struct WorkHeldStart: Equatable, Identifiable {
    let item: WorkPiece
    let agent: AgentProfile
    let limit: WorkLimit

    var id: String { "\(item.id)|\(agent.id)|\(limit.id)" }

    /// The Mac's words for it (`HeldStartCard`).
    var title: String { "Past the project's \(limit.name)" }
    var message: String {
        "Starting \(agent.name) on “\(item.title)” goes past it: \(limit.reason). Work already running carries on. Start it anyway?"
    }
}

/// How long ago a time was, in the Mac's words (`LimitsFormat.ago`).
enum WorkTime {
    /// "just now", "5 min ago", "3 h ago", "2 d ago".
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
