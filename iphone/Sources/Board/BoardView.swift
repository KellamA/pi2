import SwiftUI

/// One of a project's board pages that its hub's More tab lists: Agents (as grouped settings), Rules, Notes, or Branches
/// and worktrees (docs/design/iphone.md, "Every screen and function of the Mac app"). #696 builds it: replace this body,
/// keep the type and its initialiser, and add files beside it in `Board/`. An agent's page opens with
/// `openRoute(.agent(id, project:))`.
struct BoardView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// Which page.
    let page: BoardPage

    init(projectID: String, page: BoardPage) {
        self.projectID = projectID
        self.page = page
    }

    var body: some View {
        FeaturePlaceholder(screen: page.rawValue.capitalized, issue: 696, details: ["project \(projectID)"])
    }
}
