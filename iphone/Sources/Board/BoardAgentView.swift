import SwiftUI

/// An agent's page, as grouped settings: a project's agent, or a template. Allow everything can be turned off here but
/// on only at the Mac (docs/iphone.md, question 5). #696 builds it: replace this body, keep the type and its initialiser,
/// and add files beside it in `Board/`.
struct BoardAgentView: View {
    /// The agent's id, as `AgentProfile.id`.
    let agentID: String
    /// The project whose agent it is, as `ProjectRow.id`; nil for a template.
    let projectID: String?

    init(agentID: String, projectID: String? = nil) {
        self.agentID = agentID
        self.projectID = projectID
    }

    var body: some View {
        FeaturePlaceholder(screen: projectID == nil ? "Template" : "Agent", issue: 696,
                           details: ["agent \(agentID)"] + (projectID.map { ["project \($0)"] } ?? []))
    }
}
