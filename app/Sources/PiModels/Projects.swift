import Foundation

// Projects (epic #450, docs/projects.md): what the app reads of the engine's `projects` and `needs` events.

/// A project as the `projects` event sends it (docs/projects.md, 3.2 and 4.3): the parts the app reads. Fields the app
/// does not read, such as `lastWords`, are left out, so that a change to them changes nothing here.
public struct ProjectInfo: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The real path of its folder, or nil for a project with no folder.
    public let folder: String?
    /// The project agent that is its orchestrator.
    public let orchestratorId: String
    /// The orchestrator's conversation now; nil until one is made with `projects.startFresh` (9.6).
    public let conversation: Int?
    public let archivedAt: Double?
    public let deletedAt: Double?
    /// Its folder has gone since it was set.
    public let folderMissing: Bool?
}

/// What carrying over has left to do, as the `projects` event says (4.3).
public struct CarryOverState: Codable, Equatable, Sendable {
    public struct Pending: Codable, Equatable, Sendable {
        public let copy: String
        public let name: String
        public let project: String
        public let variables: [String]
        public let error: String?
    }
    /// The copy of the data the update to projects made before it carried anything (docs/projects.md, 9.8): where, and
    /// when, in milliseconds.
    public struct RemovalBackup: Codable, Equatable, Sendable {
        public let path: String
        public let at: Double

        public init(path: String, at: Double) {
            self.path = path
            self.at = at
        }
    }
    public let secretsPending: [Pending]
    /// Set once the update to projects has made its copy of the data (#715). Nil from an engine that does not send it.
    public let removalBackup: RemovalBackup?
    /// Why the update to projects could not make its copy or carry everything over, while it could not; it tries again
    /// at the engine's next start. Nil from an engine that does not send it.
    public let removalFailed: String?
}

/// What carrying over would do, or did (docs/projects.md, 9.8).
public struct CarryOverReport: Codable, Equatable, Sendable {
    public struct Project: Codable, Equatable, Identifiable, Sendable {
        public struct Orchestrator: Codable, Equatable, Sendable {
            public let title: String?
        }
        public struct Copy: Codable, Equatable, Identifiable, Sendable {
            public let template: String
            public let name: String
            public let existing: String?
            public let allowEverything: Bool
            public let variables: [String]
            public let worktreeOff: Bool
            public let folder: String?
            public var id: String { template }
        }
        public let key: String
        public let name: String
        public let existing: String?
        public let adopted: Bool
        public let archived: Bool
        public let orchestrator: Orchestrator?
        public let copies: [Copy]
        public let conversations: Int
        public let archivedConversations: Int
        public let subChats: Int
        public let notes: Int
        public let notices: [String]
        public var id: String { key }
    }
    public let plan: String?
    public let projects: [Project]
    // A single restore: the original agent whose copy the root will run as, and whether the destination comes back too.
    public let rootAgent: String?
    public let restoresProject: Bool?
    // A completed restore: the destination, even when it was just made.
    public let projectId: String?

    public init(_ value: JSONValue) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

/// The `projects` event as the sidebar and Settings read it. The hub reads it as `ProjectsEvent` (ProjectHub.swift).
public struct SidebarProjectsEvent: Decodable, Sendable {
    public let projects: [ProjectInfo]
    public let carryOver: CarryOverState?
}

/// One thing waiting for the person, as much as the sidebar reads of it: whose project it is. The `needs` event
/// decodes as `NeedItemsEvent` (ProjectRulesTab.swift), which the Rules tab reads the proposed rules from.
public struct NeedRef: Equatable, Sendable {
    public let projectId: String?

    public init(projectId: String?) {
        self.projectId = projectId
    }
}

/// A conversation of a project that is not the orchestrator's, as the sidebar lists it under the project.
public struct ProjectConversation: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    /// The agent it runs as.
    public let agentId: String?

    public init(id: Int, title: String, agentId: String?) {
        self.id = id
        self.title = title
        self.agentId = agentId
    }
}
