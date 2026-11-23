
import AppIntents
import Foundation
import PiModels

/// A project on the paired Mac, as Shortcuts and Siri name it: one of the session's projects (`session.engine.projects`),
/// by its id, not archived or deleted.
struct IntentProject: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = IntentProjectQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ row: ProjectRow) {
        self.init(id: row.id, name: row.name)
    }

    /// The projects a person can ask about: the session's, but those archived or deleted.
    @MainActor
    static func all(in session: AppSession) -> [ProjectRow] {
        session.engine.projects.filter { $0.archivedAt == nil && $0.deletedAt == nil }
    }
}

/// The projects Shortcuts offers and Siri matches, read from the session once it has reached its Mac.
struct IntentProjectQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [IntentProject] {
        let projects = await Self.projects()
        return identifiers.compactMap { id in projects.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [IntentProject] {
        await Self.projects()
    }

    @MainActor
    func entities(matching string: String) async throws -> [IntentProject] {
        let projects = await Self.projects()
        let wanted = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return projects }
        return projects.filter { $0.name.localizedStandardContains(wanted) }
    }

    /// The session's projects, once it answers; none when it cannot be reached and keeps nothing of them.
    @MainActor
    static func projects() async -> [IntentProject] {
        let session = IntentSessions.current().session
        _ = await IntentSessions.reach(session)
        return IntentProject.all(in: session).map(IntentProject.init)
    }
}
