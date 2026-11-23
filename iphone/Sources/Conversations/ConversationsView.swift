import SwiftUI

/// Conversations other than an orchestrator's: a project's (its agents' and their sub-chats), or, with no project, those
/// outside projects, chats among them (docs/design/iphone.md, "An agent's conversation" and "Every screen and function
/// of the Mac app"). Each opens with `openRoute(.conversation(id))`. #698 builds it: replace this body, keep the type and
/// its initialiser, and add files beside it in `Conversations/`.
struct ConversationsView: View {
    /// The project whose conversations it lists, as `ProjectRow.id`; nil for those outside projects.
    let projectID: String?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }

    var body: some View {
        FeaturePlaceholder(screen: "Conversations", issue: 698, details: projectID.map { ["project \($0)"] } ?? [])
    }
}
