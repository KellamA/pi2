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
        /// A worktree set-up command still running, whose output the page shows in its row as it arrives.
        var setup: LiveSetup?
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
        /// Whether the conversation has a folder, in which a relative link in an answer names a file (#451).
        var folder = false
    }

    /// A model Try Again can use, as the model selector lists it.
    struct ModelChoice: Encodable, Equatable {
        var provider: String
        var id: String
        var name: String
        /// The provider's name, which the list is grouped by.
        var group: String
    }

    /// What a chat adds to the page (#285): Try Again, Edit, the step between versions, and sources. `enabled` is
    /// false for an agent's conversation, and the page shows none of it.
    struct Chat: Encodable, Equatable {
        var enabled: Bool
        var versions: [VersionPoint]
        var models: [ModelChoice]
        /// The model in use, as "provider/id".
        var model: String

        static let none = Chat(enabled: false, versions: [], models: [], model: "")

        /// Whether the page shows a chat's controls: only for a chat, as the engine says (#283).
        static func shown(for state: ConversationState?) -> Bool {
            state?.chat == true
        }
    }

    /// Whether the conversation has entries older than all the app has, which the page asks for when the reader nears
    /// its top, and whether they are being asked for (#440).
    struct Older: Encodable, Equatable {
        var more: Bool
        var loading: Bool

        static let none = Older(more: false, loading: false)
    }

    struct Message: Encodable {
        var reset: Bool?
        /// Entries to put before the first the page has, oldest first (#380).
        var older: [Item]?
        /// How many entries older than those the page has are still to come.
        var earlier: Int?
        /// Whether there are older entries still to ask for, and whether they are on their way (#440).
        var history: Older?
        var items: [Item]?
        var live: Live?
        var inbox: [InboxItem]?
        var names: Names?
        var palette: [String: String]?
        var chat: Chat?
    }

    /// The page is sent a long conversation newest first, as the engine sends it to the app (#380, engine/src/opening.ts):
    /// at first the newest entries, as many as come to about `firstBytes` or number `firstCount`, then the older ones,
    /// about `olderBytes` at a time, each once the page has drawn the one before.
    static let firstBytes = 64 * 1024
    static let firstCount = 40
    static let olderBytes = 256 * 1024

    /// The entries sent: `sentCount` of them, from the one whose id is `firstSent` to `lastSent`.
    private var sentCount = 0
    private var firstSent: Int?
    private var lastSent: Item?
    /// How many entries the app has before those the page was sent, still to be sent.
    private(set) var pending = 0
    private var earlier: Int?
    private var history: Older?
    private var live: Live?
    private var inbox: [InboxItem]?
    private var names: Names?
    private var palette: [String: String]?
    private var chat: Chat?
    private var startOver = false

    /// Forget what was sent and start the page's list over: for a page that has just loaded (or reloaded after its
    /// process ended), or a view now showing another conversation.
    mutating func restart() {
        self = TranscriptFeed()
        startOver = true
    }

    /// The update that brings the page from what it was last sent to this, or nil when nothing changed.
    /// `earlier` is how many older entries the engine is still to send the app; with `withOlder` false, older entries the
    /// app has wait (the page has not yet drawn the part before them).
    mutating func update(items: [Item], earlier: Int = 0, older: Older = .none, state: ConversationState?, inbox: [InboxItem], names: Names, palette: [String: String], chat: Chat = .none, withOlder: Bool = true) -> Message? {
        var message = Message()
        var changed = false

        // Entries arrive at the end, and before the first sent: those the app has and has not sent yet, and those the
        // engine sends after the newest (#380). Anything else (a reset, a reload) starts the page's list over.
        let front: Int? = sentCount == 0 || items.first?.id == firstSent ? 0 : items.firstIndex(where: { $0.id == firstSent })
        let continues = front.map { front in sentCount == 0 || (front + sentCount <= items.count && items[front + sentCount - 1] == lastSent) } ?? false
        if startOver || !continues {
            message.reset = true
            sentCount = 0
            startOver = false
            changed = true
        }
        let start: Int
        if sentCount == 0 {
            // The page has none of them: the newest first.
            start = Self.partStart(items, end: items.count, bytes: Self.firstBytes, count: Self.firstCount)
            if start < items.count {
                message.items = Array(items[start...])
                changed = true
            }
        } else {
            let front = front ?? 0
            start = front > 0 && withOlder ? Self.partStart(items, end: front, bytes: Self.olderBytes) : front
            if start < front {
                message.older = Array(items[start..<front])
                changed = true
            }
            if items.count > front + sentCount {
                message.items = Array(items[(front + sentCount)...])
                changed = true
            }
        }
        sentCount = items.count - start
        firstSent = items.indices.contains(start) ? items[start].id : nil
        lastSent = items.last
        pending = start
        // What the page is still to get: what the app has and has not sent it, and what the engine has still to send.
        let earlier = start + earlier
        if earlier != self.earlier || message.reset == true {
            message.earlier = earlier
            self.earlier = earlier
            changed = true
        }
        if older != history || message.reset == true {
            message.history = older
            history = older
            changed = true
        }

        let live = Live(busy: state?.busy ?? false, partial: state?.partial, tools: state?.tools ?? [], retrying: state?.retry != nil, setup: state?.setup)
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
        if chat != self.chat {
            message.chat = chat
            self.chat = chat
            changed = true
        }
        return changed ? message : nil
    }

    /// Where the part of `items` that ends at `end` starts: entries are taken from `end` back until they come to about
    /// `bytes` or number `count`, always at least one, and reaching back over tool results to the answer whose calls
    /// they answer, as the engine cuts its parts (engine/src/opening.ts).
    static func partStart(_ items: [Item], end: Int, bytes: Int, count: Int = .max) -> Int {
        var start = end
        var total = 0
        while start > 0 && (start == end || (total < bytes && end - start < count)) {
            start -= 1
            total += size(of: items[start])
        }
        while start > 0 && items[start].kind == "tool" { start -= 1 }
        return start
    }

    /// About how large an entry is as JSON: its text, which is most of it, and a little for the rest.
    static func size(of item: Item) -> Int {
        item.text.utf8.count + (item.thinking?.utf8.count ?? 0) + (item.error?.utf8.count ?? 0) + 200 * (1 + (item.toolCalls?.count ?? 0))
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
