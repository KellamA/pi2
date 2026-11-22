import Foundation

/// A project as the engine's `projects` event sends it (docs/projects.md, 3.2 and 4.3): what the app reads of it.
public struct ProjectRow: Decodable, Equatable, Identifiable, Sendable {
    public struct Repository: Decodable, Equatable, Sendable {
        public let owner: String
        public let name: String
    }

    public struct LastWords: Decodable, Equatable, Sendable {
        public let text: String
        /// Milliseconds since 1970.
        public let at: Double
    }

    /// About how many tokens the rules add to each request (docs/projects.md, 6.2): an orchestrator's, and every other
    /// agent's. Absent from an engine before #459 filled it.
    public struct RuleTokens: Decodable, Equatable, Sendable {
        public let orchestrator: Int
        public let agents: Int
    }

    public let id: String
    public let name: String
    /// The real path of its folder, or nil for a project with none.
    public let folder: String?
    public let repository: Repository?
    /// The project agent that is its orchestrator.
    public let orchestratorId: String
    /// The orchestrator's conversation now: nil until it is first opened, for a project carried over (3.2).
    public let conversation: Int?
    public let archivedAt: Double?
    public let deletedAt: Double?
    /// Its folder has gone since it was set.
    public let folderMissing: Bool?
    /// The last line of the orchestrator's last finished answer, for the folded conversation's strip.
    public let lastWords: LastWords?
    /// The project's settings (docs/projects.md, section 8) as the `projects` event sends them. The Agents tab reads
    /// the switches of 8.1; the Settings tab reads the rest: when reports wake the orchestrator, and the limits (#478).
    public var settings: Settings? = nil

    /// A project's settings: the switches of 8.1, which the Agents tab reads, and the rest, which the Settings tab
    /// reads. A change to one part changes nothing in the tabs reading the other.
    public struct Settings: Decodable, Equatable, Sendable {
        /// What the orchestrator may do without asking, by switch name (8.1).
        public let withoutAsking: [String: Bool]?
        /// The person's switch for reports waking the orchestrator.
        public let wakeOnReports: Bool
        public struct Limits: Decodable, Equatable, Sendable {
            /// Percent of a plan window, 1 to 100, or nil for none.
            public let planShare: Int?
            /// Dollars a day, or nil for none.
            public let dailySpend: Double?
        }
        public let limits: Limits
    }

    /// Whether the orchestrator may do what the switch of 8.1 named `name` governs without asking.
    public func allows(_ name: String) -> Bool { settings?.withoutAsking?[name] ?? false }
    /// What the rules add to each request, for the Rules tab; nil when the engine sends none.
    public let ruleTokens: RuleTokens?
}

public struct ProjectsEvent: Decodable, Sendable {
    public let projects: [ProjectRow]
}
