import Observation

/// Unsent input belongs to the conversation, not to a pane, and never enters the transcript or app preferences.
@MainActor
@Observable
final class ConversationDraft {
    var text = ""
    let attachments = ComposerAttachments()
    @ObservationIgnored private var generation = 0

    var hasInput: Bool { !text.isEmpty || !attachments.isEmpty || attachments.hasPendingDrops }

    func discard() {
        generation += 1
        text = ""
        attachments.discard()
    }

    func send(using engine: EngineClient, to id: Int, steer: Bool) {
        let sentText = text
        let carried = attachments.takeReady()
        let revision = generation
        text = ""
        Task {
            let result = await engine.submit(sentText, attachments: carried.compactMap(\.payload), to: id, steer: steer)
            // Only a definite refusal goes back in the box. An archive or deletion after Send discards it too.
            guard result == .refused, generation == revision else { return }
            if !sentText.isEmpty { text = text.isEmpty ? sentText : sentText + "\n\n" + text }
            attachments.restore(carried)
        }
    }
}
