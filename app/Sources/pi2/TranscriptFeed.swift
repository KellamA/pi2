import Foundation

/// What the transcript page is told about a conversation, and what it has been told already, so that each update
/// carries only what changed: the entries it has not seen, and the live state, the approvals waiting at its calls,
/// the names it shows and the palette whenever those differ from last time.
///
/// It depends on the models alone, so it can be exercised outside the app.
struct TranscriptFeed {
    /// The run as the page shows it: the answer still arriving and the tools still running.
    struct Live: Encodable, Equatable {
        var busy: Bool
        var partial: PartialAnswer?
        var tools: [LiveTool]
        /// Retries are shown outside the transcript; the page only needs to know not to show "working" dots meanwhile.
        var retrying: Bool
    }

    /// An agent a hand-off can name.
    struct Agent: Encodable, Equatable {
        var id: String
        var name: String
        /// The agent's colour as CSS, for its small square.
        var color: String
        var model: String
    }

    /// What only the app knows: how to name MCP tools, agents and apps.
    struct Names: Encodable, Equatable {
        var conversationId: Int
        /// The conversation's agent, for VoiceOver's name for each answer.
        var agentName: String
        /// Tool name to "Server: tool".
        var mcp: [String: String]
        var agents: [Agent]
        /// Bundle ID to app name, for the apps computer-use calls in this transcript name.
        var apps: [String: String]
    }

    struct Message: Encodable {
        var reset: Bool?
        var items: [Item]?
        var live: Live?
        var inbox: [InboxItem]?
        var names: Names?
        var palette: [String: String]?
    }

    private var sentCount = 0
    private var firstSent: Int?
    private var lastSent: Item?
    private var live: Live?
    private var inbox: [InboxItem]?
    private var names: Names?
    private var palette: [String: String]?
    private var startOver = false

    /// Forget what was sent and start the page's list over: for a page that has just loaded (or reloaded after its
    /// process ended), or a view now showing another conversation.
    mutating func restart() {
        self = TranscriptFeed()
        startOver = true
    }

    /// The update that brings the page from what it was last sent to this, or nil when nothing changed.
    mutating func update(items: [Item], state: ConversationState?, inbox: [InboxItem], names: Names, palette: [String: String]) -> Message? {
        var message = Message()
        var changed = false

        // Entries only ever arrive at the end. Anything else (a reset, a reload) starts the page's list over.
        let continues = sentCount <= items.count
            && (sentCount == 0 || (items.first?.id == firstSent && items[sentCount - 1] == lastSent))
        if startOver || !continues {
            message.reset = true
            sentCount = 0
            startOver = false
            changed = true
        }
        if items.count > sentCount {
            message.items = Array(items[sentCount...])
            changed = true
        }
        sentCount = items.count
        firstSent = items.first?.id
        lastSent = items.last

        let live = Live(busy: state?.busy ?? false, partial: state?.partial, tools: state?.tools ?? [], retrying: state?.retry != nil)
        if live != self.live {
            message.live = live
            self.live = live
            changed = true
        }
        if inbox != self.inbox {
            message.inbox = inbox
            self.inbox = inbox
            changed = true
        }
        if names != self.names {
            message.names = names
            self.names = names
            changed = true
        }
        if palette != self.palette {
            message.palette = palette
            self.palette = palette
            changed = true
        }
        return changed ? message : nil
    }

    /// The message as the JSON text the page parses. The page is handed it as a string argument, never as script.
    static func json(_ message: Message) -> String? {
        let encoder = JSONEncoder()
        // Sorted, so a call's arguments are summarised in the same order every time.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The bundle IDs computer-use calls name, in the transcript and in what is waiting on the person.
    static func appsNamed(in items: [Item], partial: PartialAnswer?, inbox: [InboxItem]) -> Set<String> {
        var apps = Set<String>()
        func add(_ name: String, _ arguments: JSONValue) {
            if name == "computer" || name == "browser", let app = arguments["app"]?.stringValue, !app.isEmpty { apps.insert(app) }
        }
        for item in items where item.kind == "assistant" {
            for call in item.toolCalls ?? [] { add(call.name, call.arguments) }
        }
        for call in partial?.toolCalls ?? [] { add(call.name, call.arguments) }
        for entry in inbox { add(entry.tool, entry.arguments) }
        return apps
    }
}
