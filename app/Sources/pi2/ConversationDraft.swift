import Observation
import PiModels

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

/// An open conversation as the engine last sent it: its entries and its live state. One object per conversation, so that
/// an update to one conversation redraws only the views that show it, not every view that shows any (#347).
@MainActor
@Observable
final class OpenConversation {
    let draft: ConversationDraft
    private(set) var items: [Item] = []

    init(draft: ConversationDraft) { self.draft = draft }
    /// Nil until the engine has sent the conversation.
    private(set) var state: ConversationState?
    /// Whether the engine has sent the conversation: set once, for a view that needs to know only that and should not be
    /// drawn again whenever the state changes, as the Dashboard's window onto an orchestrator (#618).
    private(set) var arrived = false
    /// How many entries older than `items` the engine is still to send: it sends a long conversation newest first (#380).
    private(set) var earlier = 0
    /// Whether the conversation has entries older than all of those, which come when asked for (#440): the engine's view
    /// of a conversation is a window of its newest 300 entries.
    private(set) var more = false
    /// Whether a part of those older entries has been asked for and has not come yet (`EngineClient.loadOlder`).
    var loadingOlder = false
    /// Whether a pane has shown the conversation since it was opened. The window's controls for it wait for that, so
    /// that making them does not hold up the first frame that shows it (#502).
    private(set) var shown = false

    func markShown() {
        if !shown { shown = true }
    }

    /// Takes in one update from the engine, touching only what changed. `earlier` and `more` come with a list sent from
    /// the start.
    func apply(reset: Bool, items new: [Item], state: ConversationState, earlier: Int?, more: Bool? = nil) {
        if reset, !items.isEmpty { items = [] }
        if !new.isEmpty { items.append(contentsOf: new) }
        if self.state != state { self.state = state }
        if !arrived { arrived = true }
        if reset, self.earlier != (earlier ?? 0) { self.earlier = earlier ?? 0 }
        if reset, self.more != (more ?? false) { self.more = more ?? false }
    }

    /// Takes in entries that come before those it has, how many are still to come after them, and whether there are
    /// older ones still (absent from an engine from before #440).
    func prepend(_ older: [Item], earlier: Int, more: Bool? = nil) {
        // Only what goes before the first it has, which is all of them unless a list sent from the start came between.
        let first = items.first?.id ?? Int.max
        let before = older.filter { $0.id < first }
        if !before.isEmpty { items.insert(contentsOf: before, at: 0) }
        if self.earlier != earlier { self.earlier = earlier }
        if let more, self.more != more { self.more = more }
    }

    /// Nothing older is to be had after all: the engine said so, or could not say.
    func noMore() {
        if more { more = false }
    }

    /// Whether the person's message has come after the entry `last` (nil: since the conversation was empty). Entries can
    /// arrive before those there were too, so this looks past `last` rather than counting.
    func hasMessage(after last: Int?) -> Bool {
        for item in items.reversed() {
            if let last, item.id <= last { return false }
            if item.kind == "user" { return true }
        }
        return false
    }
}
