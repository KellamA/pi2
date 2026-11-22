import SwiftUI

/// The Dashboard on a phone: a page for each watched project, swiped sideways (docs/design/iphone.md, "The Dashboard on a
/// phone"). #688 builds it: replace this body, keep the type and its initialiser, and add files beside it in
/// `Dashboard/`.
struct DashboardView: View {
    /// The project whose page it opens on, as `ProjectRow.id`; nil for the first.
    let projectID: String?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }

    var body: some View {
        FeaturePlaceholder(screen: "Dashboard", issue: 688, details: projectID.map { ["project \($0)"] } ?? [])
    }
}
