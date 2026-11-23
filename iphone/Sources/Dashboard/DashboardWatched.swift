import Observation
import PiModels

/// Which projects the Dashboard shows a page for. On the Mac it is the app's own choice, kept in its preferences
/// (`dashboard.projects`, docs/projects.md 10.1); the phone keeps its choice in memory only until its store exists
/// (#692), so it lasts while the app runs. Until the person chooses, every project the Mac lists is watched, as on the
/// Mac.
@MainActor
@Observable
final class DashboardWatched {
    static let shared = DashboardWatched()

    /// The projects ticked, once the person has chosen; nil until then.
    private(set) var chosen: Set<String>?

    init(chosen: Set<String>? = nil) {
        self.chosen = chosen
    }

    /// The projects to show a page for, in the Mac's order: those ticked, or every listed one until a choice is made.
    func watched(_ listed: [ProjectRow]) -> [ProjectRow] {
        guard let chosen else { return listed }
        return listed.filter { chosen.contains($0.id) }
    }

    func watching(_ id: String, listed: [ProjectRow]) -> Bool {
        chosen?.contains(id) ?? listed.contains { $0.id == id }
    }

    /// Ticks or unticks one project. The first choice starts from every listed project.
    func toggle(_ id: String, listed: [ProjectRow]) {
        var set = chosen ?? Set(listed.map(\.id))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        chosen = set
    }

    /// The page to open on: the project asked for when it is watched, else the first.
    static func opening(_ projectID: String?, in pages: [ProjectRow]) -> String? {
        if let projectID, pages.contains(where: { $0.id == projectID }) { return projectID }
        return pages.first?.id
    }
}
