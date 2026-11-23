
import SwiftUI

/// An agent's page, as grouped settings: a project's agent, or a template (docs/design/iphone.md, "Every screen and
/// function of the Mac app"), the Mac's agent page (app/Sources/pi2/AgentViews.swift) drawn for a phone. Allow everything
/// can be turned off here but on only at the Mac (docs/iphone.md, 4.2, question 5).
struct BoardAgentView: View {
    /// The agent's id, as `AgentProfile.id`.
    let agentID: String
    /// The project whose agent it is, as `ProjectRow.id`; nil for a template.
    let projectID: String?

    @Environment(AppSession.self) private var session

    init(agentID: String, projectID: String? = nil) {
        self.agentID = agentID
        self.projectID = projectID
    }

    var body: some View {
        let data = session.boardData
        let agent = data.agent(agentID)
        Group {
            if let agent {
                BoardAgentForm(saved: agent, data: data)
                    // Drawn anew for another agent, so that one page's edits never land on another's.
                    .id(agentID)
            } else {
                BoardMissing(waiting: !data.connected || !data.loaded, title: projectID == nil ? "No such template" : "No such agent",
                             description: "Your Mac has no such agent now. It may have been deleted.")
            }
        }
        .navigationTitle(agent?.name ?? (projectID == nil ? "Template" : "Agent"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
