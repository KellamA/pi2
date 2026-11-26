import PiModels

// The conversation that opened a pull request through pi² (its `openedBy`), named as the person knows it, from the
// library's rows: a sub-chat by its number, the project's conversation with its orchestrator as that, another agent's
// own conversation by the agent, and one the session does not list (not loaded yet, archived, deleted) by its number
// alone, which claims nothing it cannot know. The same words as the iPhone's `PullRequestLook.opener`
// (iphone/Sources/PullRequest/PullRequestPage.swift): the Mac's Send Back field says them too (#1005).

public enum PullRequestOpener {
    public static func words(_ id: Int, conversations: [ConversationSummary], agents: [AgentProfile]) -> String {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return "conversation \(id)" }
        if conversation.parent != nil { return "sub-chat \(id)" }
        switch conversation.orchestrator {
        case "current": return "the orchestrator's conversation"
        case "earlier": return "an earlier conversation with the orchestrator"
        default: break
        }
        if let agentID = conversation.runsAs ?? conversation.agentId, let agent = agents.first(where: { $0.id == agentID }) {
            return "\(agent.name)'s conversation"
        }
        return "conversation \(id)"
    }
}
