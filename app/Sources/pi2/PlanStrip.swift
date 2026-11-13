import SwiftUI

/// The agent's task list for the conversation, pinned above the message field.
/// Not built yet: this file is the whole of that view when it is.
struct PlanStrip: View {
    let engine: EngineClient
    let id: Int
    let state: ConversationState?

    var body: some View {
        EmptyView()
    }
}
