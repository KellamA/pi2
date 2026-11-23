import Foundation

// The work of a project (docs/projects.md, 3.11 and 4.3): what the app reads of the engine's `work` event, and of the
// issues in it when the work is an attached GitHub repository's. The Mac's Work tab reads it (ProjectWorkTab.swift,
// ProjectWorkGitHub.swift); the iPhone app's Work screens (#694) are to read the same, so a field the engine adds is
// read once.

/// One piece of work as the engine's `work` event sends it (docs/projects.md, 3.11): a task for the project, in the list
/// pi² itself keeps for a project with no GitHub repository attached.
public struct WorkPiece: Identifiable, Equatable, Sendable {
    public struct Note: Equatable, Sendable {
        public let at: Date
        /// The agent that wrote it; nil for the person.
        public let agentId: String?
        public let text: String
    }

    public let id: Int
    public let title: String
    public let text: String
    /// Where it is, and who has it: what a change on its way shows at once (`showing`), before the engine answers.
    public private(set) var state: String
    /// The class of model the work needs (docs/issue-classes.md); nil when not classified.
    public let modelClass: String?
    /// The agent working on it, and the sub-chat it works in; nil when nobody has it.
    public private(set) var holderAgentId: String?
    public private(set) var holderConversation: Int?
    public let notes: [Note]
    /// What finishing it said was done.
    public let result: String?
    public let updatedAt: Date
    /// GitHub only: the issue's address.
    public let url: String?
    /// GitHub only: only what its row shows was read, a closed issue's until it is opened (#599).
    public let partial: Bool

    public init?(_ value: JSONValue?) {
        guard let value, let id = value["id"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        var written = 0.0
        if case .number(let milliseconds)? = value["updatedAt"] { written = milliseconds }
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
            var at = 0.0
            if case .number(let milliseconds)? = note["at"] { at = milliseconds }
            return WorkPiece.Note(
                at: Date(timeIntervalSince1970: at / 1000),
                agentId: note["by"]?["agentId"]?.stringValue, text: text
            )
        }
        result = value["result"]?.stringValue
        updatedAt = Date(timeIntervalSince1970: written / 1000)
        url = value["url"]?.stringValue
        partial = value["partial"] == .bool(true)
    }

    /// The piece as it will be once the change on its way is made: shown at once, until the engine says how it went
    /// (#599). The state the change takes it to (nil to stay as it is), the agent it is given to, and whether it goes
    /// back to nobody: the shape of a change on its way, so that each app keeps its own view state for one.
    public func showing(state: String?, holderAgentId: String?, letsGo: Bool) -> WorkPiece {
        guard let state else { return self }
        var shown = self
        shown.state = state
        if letsGo {
            shown.holderAgentId = nil
            shown.holderConversation = nil
        } else if let agent = holderAgentId {
            shown.holderAgentId = agent
            shown.holderConversation = nil
        }
        return shown
    }
}

/// The work of one project, from the `work` event's `projects` (docs/projects.md, 4.3), grouped by state in the order the
/// state table lists them (3.11), with the empty groups left out.
public struct ProjectWork: Sendable {
    /// The states in the table's order, with the words the tab shows for each.
    public static let groups: [(state: String, name: String)] = [
        ("open", "Open"), ("in_progress", "In progress"), ("waiting", "Waiting"),
        ("blocked", "Blocked"), ("done", "Done"), ("dropped", "Dropped"),
    ]

    public let items: [WorkPiece]

    public init(_ value: JSONValue?) {
        items = (value?.arrayValue ?? []).compactMap(WorkPiece.init)
    }

    public init(pieces: [WorkPiece]) {
        items = pieces
    }

    /// The groups with something in them, each newest-changed first.
    public var grouped: [(state: String, name: String, items: [WorkPiece])] {
        ProjectWork.groups.compactMap { group in
            let inState = items.filter { $0.state == group.state }.sorted { $0.updatedAt > $1.updatedAt }
            return inState.isEmpty ? nil : (group.state, group.name, inState)
        }
    }

    /// The word the tab shows for a state; a state it does not know reads as the engine sent it.
    public static func name(of state: String) -> String {
        groups.first { $0.state == state }?.name ?? state
    }
}

/// What the project's limit was when the engine refused to start an agent (docs/projects.md, 8.3), with the opaque id of
/// that reading, for confirming the one start it refused.
public struct WorkLimit: Equatable, Sendable {
    public let id: String
    /// "planShare" or "dailySpend".
    public let kind: String
    /// What was over, as the engine read it.
    public let reason: String

    public init?(_ value: JSONValue?) {
        guard let id = value?["id"]?.stringValue, let kind = value?["limit"]?.stringValue,
              let reason = value?["reason"]?.stringValue else { return nil }
        self.id = id
        self.kind = kind
        self.reason = reason
    }

    /// The limit as the person reads its name.
    public var name: String {
        switch kind {
        case "dailySpend": "daily spending limit"
        case "planShare": "plan share limit"
        default: "limit"
        }
    }
}
