import SwiftUI

/// A conversation on its own screen, an orchestrator's or an agent's: the transcript page and the message field
/// (docs/design/iphone.md, "An agent's conversation"; docs/iphone.md P18). #687 builds it: replace this body, keep the
/// type and its initialiser, and add files beside it in `Conversation/`.
struct ConversationView: View {
    /// The conversation's id, as `ConversationSummary.id`.
    let conversationID: Int

    init(conversationID: Int) {
        self.conversationID = conversationID
    }

    var body: some View {
        FeaturePlaceholder(screen: "Conversation", issue: 687, details: ["conversation \(conversationID)"])
    }
}
