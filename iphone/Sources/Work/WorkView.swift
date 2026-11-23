import SwiftUI

/// A project's work list, as the Mac's Work tab has it: the list in its states (open, in progress, waiting, blocked,
/// done) behind a segmented control, a piece of work with its text, its notes and Give to an agent, and filing
/// (docs/design/iphone.md, "The Work tab, and a pull request with its diff"). The hub's Work tab draws it inline
/// (`RouteView(.work(project: id), placement: .inline)`); a piece of work opens as a screen of its own. #694 builds it:
/// replace this body, keep the type and its initialiser, and add files beside it in `Work/`. A pull request opens with
/// `openRoute(.pullRequest(project:number:))`.
struct WorkView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// The piece of work it opens on, by its number; nil for the list.
    let itemID: Int?

    init(projectID: String, itemID: Int? = nil) {
        self.projectID = projectID
        self.itemID = itemID
    }

    var body: some View {
        FeaturePlaceholder(screen: itemID == nil ? "Work" : "A piece of work", issue: 694,
                           details: ["project \(projectID)"] + (itemID.map { ["work #\($0)"] } ?? []))
    }
}
