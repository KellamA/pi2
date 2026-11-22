import SwiftUI

/// What needs the person: every card waiting, answered in place (docs/design/iphone.md, "A card that needs the person";
/// docs/iphone.md P17). Drawn as a screen of its own, and inline at the top of the projects list
/// (`RouteView(.needs(), placement: .inline)`). #686 builds it: replace this body, keep the type and its initialiser,
/// and add files beside it in `Needs/`.
struct NeedsView: View {
    /// The project whose cards it shows, as `ProjectRow.id`; nil for every project's.
    let projectID: String?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }

    var body: some View {
        FeaturePlaceholder(screen: "Needs you", issue: 686, details: projectID.map { ["project \($0)"] } ?? [])
    }
}
