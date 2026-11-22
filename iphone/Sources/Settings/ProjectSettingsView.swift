import SwiftUI

/// A project's settings and limits, as grouped settings, from its hub's More tab (docs/design/iphone.md, "Every screen
/// and function of the Mac app"). #697 builds it: replace this body, keep the type and its initialiser, and add files
/// beside it in `Settings/`.
struct ProjectSettingsView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String

    init(projectID: String) {
        self.projectID = projectID
    }

    var body: some View {
        FeaturePlaceholder(screen: "Project settings", issue: 697, details: ["project \(projectID)"])
    }
}
