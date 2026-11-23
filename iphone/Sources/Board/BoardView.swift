
import SwiftUI

/// One of a project's board pages that its hub's More tab lists: Agents (as grouped settings), Rules, Notes, or Branches
/// and worktrees (docs/design/iphone.md, "Every screen and function of the Mac app"), each the Mac's board tab of the same
/// name drawn for a phone. An agent's page opens with `openRoute(.agent(id, project:))`.
struct BoardView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// Which page.
    let page: BoardPage

    @Environment(AppSession.self) private var session

    init(projectID: String, page: BoardPage) {
        self.projectID = projectID
        self.page = page
    }

    var body: some View {
        let data = session.boardData
        Group {
            if let project = data.project(projectID) {
                switch page {
                case .agents: BoardAgentsPage(project: project, data: data)
                case .rules: BoardRulesPage(project: project, data: data)
                case .notes: BoardNotesPage(project: project, data: data)
                case .branches: BoardBranchesPage(project: project, data: data)
                }
            } else {
                BoardMissing(waiting: !data.connected || !data.loaded, title: "No such project",
                             description: "Your Mac has no project by this name now. It may have been deleted.")
            }
        }
        .navigationTitle(Self.title(page))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func title(_ page: BoardPage) -> String {
        switch page {
        case .agents: "Agents"
        case .rules: "Rules"
        case .notes: "Notes"
        case .branches: "Branches"
        }
    }
}
