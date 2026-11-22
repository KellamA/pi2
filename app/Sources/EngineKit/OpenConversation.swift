import Observation
import PiModels

/// An open conversation as the engine last sent it: its entries and its live state. One object per conversation, so that
/// an update to one conversation redraws only the views that show it, not every view that shows any (#347).
@MainActor
@Observable
public final class OpenConversation<Draft: MessageDraft> {
    public let draft: Draft
    public private(set) var items: [Item] = []

    public init(draft: Draft) { self.draft = draft }
    /// Nil until the engine has sent the conversation.
    public private(set) var state: ConversationState?
    /// Whether the engine has sent the conversation: set once, for a view that needs to know only that and should not be
    /// drawn again whenever the state changes, as the Dashboard's window onto an orchestrator (#618).
    public private(set) var arrived = false
    /// How many entries older than `items` the engine is still to send: it sends a long conversation newest first (#380).
    public private(set) var earlier = 0
    /// Whether the conversation has entries older than all of those, which come when asked for (#440): the engine's view
    /// of a conversation is a window of its newest 300 entries.
    public private(set) var more = false
    /// Whether a part of those older entries has been asked for and has not come yet (`EngineSession.loadOlder`).
    public var loadingOlder = false
    /// Whether a pane has shown the conversation since it was opened. The window's controls for it wait for that, so
    /// that making them does not hold up the first frame that shows it (#502).
    public private(set) var shown = false

    public func markShown() {
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
