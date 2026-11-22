import Foundation

/// A rule of a project, as the `projectRules` event sends it (docs/projects.md, 3.7). The array's order is the order
/// the prompt and this tab show, numbered from 1.
public struct ProjectRule: Decodable, Equatable, Identifiable, Sendable {
    /// Whom it binds.
    public enum Binds: String, Decodable, CaseIterable, Identifiable, Sendable {
        case orchestrator, everyone

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .orchestrator: "Orchestrator"
            case .everyone: "Every agent"
            }
        }
    }

    /// Who put it there: the person by hand, the orchestrator as the person dictated it, or an agent's proposal the
    /// person accepted (docs/projects.md, 3.7).
    public enum AddedBy: Equatable, Sendable {
        case person
        case agent(agentId: String, conversationId: Int)
        case proposal(agentId: String, conversationId: Int, need: String)
    }

    public let id: String
    public let text: String
    public let binds: Binds
    public let addedBy: AddedBy
    /// Milliseconds since 1970.
    public let createdAt: Double

    private enum CodingKeys: String, CodingKey { case id, text, binds, addedBy, createdAt }
    private enum AddedKeys: String, CodingKey { case kind, agentId, conversationId, need }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        binds = try values.decode(Binds.self, forKey: .binds)
        let added = try values.nestedContainer(keyedBy: AddedKeys.self, forKey: .addedBy)
        let kind = try added.decode(String.self, forKey: .kind)
        switch kind {
        case "person":
            addedBy = .person
        case "agent":
            addedBy = .agent(
                agentId: try added.decode(String.self, forKey: .agentId),
                conversationId: try added.decode(Int.self, forKey: .conversationId))
        case "proposal":
            addedBy = .proposal(
                agentId: try added.decode(String.self, forKey: .agentId),
                conversationId: try added.decode(Int.self, forKey: .conversationId),
                need: try added.decode(String.self, forKey: .need))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown addedBy kind: \(kind)"))
        }
        createdAt = try values.decode(Double.self, forKey: .createdAt)
    }
}

public struct ProjectRulesEvent: Decodable, Sendable {
    public let projects: [String: [ProjectRule]]
}

/// One thing waiting under Needs you, as the `needs` event sends it (docs/projects.md, 3.9): a discriminated union, with
/// the fields of the kinds that do not use them left out. The Rules tab reads a proposed rule from it, and the Now tab
/// the card of every kind; the sidebar counts what it holds by `projectId`. The whole array decodes whatever kinds are
/// in it, so a kind this app knows nothing of cannot take the list, a tab or the cards down.
public struct NeedItem: Decodable, Equatable, Identifiable, Sendable {
    public struct Choice: Decodable, Equatable, Sendable {
        public let id: String
        public let label: String
    }

    /// A reach request's change, as the person reads it (7.2): what it would let agents do.
    public struct ReachChange: Decodable, Equatable, Sendable {
        public let summary: String
    }

    /// The start the project's limit stopped (8.3), as the person reads it.
    public struct Start: Decodable, Equatable, Sendable {
        public let agentName: String?
        public let title: String?
        public let task: String?
    }

    /// What was over when the start was refused: `reason` is the sentence the person reads.
    public struct LimitReading: Decodable, Equatable, Sendable {
        public let reason: String
    }

    public let id: String
    /// Null for an approval or question of a conversation in no project.
    public let projectId: String?
    public let kind: String
    /// The conversation that asks, its root, and their titles, for "in …".
    public let conversationId: Int
    public let rootConversationId: Int
    public let title: String
    public let rootTitle: String
    /// The agent the conversation that asks runs as, and its name.
    public let agentId: String?
    public let agentName: String?
    /// Whether the agent is held until it is answered: true for approvals and ask_user questions only.
    public let blocking: Bool
    /// Milliseconds since 1970.
    public let createdAt: Double
    /// A proposed rule's text and whom it would bind, and why the agent proposes it.
    public let text: String?
    public let binds: ProjectRule.Binds?
    public let why: String?
    /// A question's or a decision's words, its choices, and whether it takes an answer in the person's own words.
    public let question: String?
    public let choices: [Choice]?
    public let words: Bool?
    /// An approval's call, and the switch of the project that asked when it is off (8.1): then it is answered with
    /// `once` or `deny` only.
    public let tool: String?
    public let arguments: JSONValue?
    public let projectSwitch: String?
    /// More reach, and a start the project's limit stopped.
    public let change: ReachChange?
    public let start: Start?
    public let limit: LimitReading?
    /// A worker's question or decision: the work item its run was handed, when it was handed one (#507).
    public let work: Int?

    /// Whether a worker asks, in a sub-chat, rather than an agent in a conversation of its own (#507).
    public var fromSubChat: Bool { conversationId != rootConversationId }

    /// Where it was asked, as a line names it: "sub-chat “Fix login”", or a conversation's title.
    public var placeWords: String {
        guard fromSubChat else { return title.isEmpty ? rootTitle : title }
        return title.isEmpty ? "sub-chat \(conversationId)" : "sub-chat “\(title)”"
    }

    /// Which switch asked, in words the person reads, or the switch's own name when the app does not know it.
    public var switchWords: String? {
        projectSwitch.map {
            switch $0 {
            case "startAgents": "starting agents without asking"
            case "fileWork": "filing work without asking"
            case "closeWork": "closing work without asking"
            case "makeAgents": "making agents without asking"
            case "addRules": "adding rules without asking"
            case "merge": "merging without asking"
            case "release": "releasing work without asking"
            case "passLimits": "going past the project's limits"
            default: $0
            }
        }
    }

    /// The line that says what it is, as the engine names the kinds to a person who answers the wrong one.
    public var named: String {
        switch kind {
        case "approval": "a request for approval"
        case "question": "a question"
        case "decision": "a decision"
        case "reach": "a request for more reach"
        case "rule": "a proposed rule"
        case "limit": "a start held back by the project's limit"
        default: "something that waits for you"
        }
    }

    /// What it asks, in one short line: the menu bar item's list of what waits and its notifications (#481).
    public var short: String {
        switch kind {
        case "approval":
            question ?? ToolCall(callId: "", name: tool ?? "", arguments: arguments ?? .null).summary
        case "question", "decision":
            question ?? ""
        case "reach":
            change?.summary ?? "Asks for more reach"
        case "rule":
            text.map { "Proposes a rule: \($0)" } ?? "Proposes a rule"
        case "limit":
            limitShort
        default:
            question ?? text ?? named
        }
    }

    /// A start held back by the limit, in one line: what it wanted to start, when the need says.
    private var limitShort: String {
        let what = [start?.title, start?.task].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        return what.isEmpty ? "A start is held back by the project's limit" : "Held back by the limit: \(what)"
    }
}

public struct NeedItemsEvent: Decodable, Sendable {
    public let items: [NeedItem]
}
