import SwiftUI

/// A project's hub: the orchestrator's conversation, with the tab bar Chat · Now · Work · More (docs/design/iphone.md,
/// "A project's hub"). #688 builds it: replace this body, keep the type and its initialiser, and add files beside it in
/// `Hub/`. The Chat tab draws the orchestrator's conversation with `RouteView(.conversation(id), placement: .inline)`.
struct HubView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// The tab it opens on.
    let tab: HubTab

    init(projectID: String, tab: HubTab = .chat) {
        self.projectID = projectID
        self.tab = tab
    }

    var body: some View {
        FeaturePlaceholder(screen: "Project hub", issue: 688, details: ["project \(projectID)", "tab \(tab.rawValue)"])
    }
}
