import Foundation

/// What the transcript page is told about a conversation, and what it has been told already, so that each update
/// carries only what changed: the entries it has not seen, and the live state, the approvals waiting at its calls,
/// the names it shows and the palette whenever those differ from last time.
///
/// It depends on the models alone, so it can be exercised outside the app.
public struct TranscriptFeed: Sendable {
    /// The run as the page shows it: the answer still arriving and the tools still running.
    public struct Live: Encodable, Equatable, Sendable {
        public var busy: Bool
        public var partial: PartialAnswer?
        public var tools: [LiveTool]
        /// Retries are shown outside the transcript; the page only needs to know not to show "working" dots meanwhile.
        public var retrying: Bool
        /// A worktree set-up command still running, whose output the page shows in its row as it arrives.
        public var setup: LiveSetup?
    }

    /// An agent a hand-off can name.
    public struct Agent: Encodable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// The agent's colour as CSS, for its small square.
        public var color: String
        public var model: String

        public init(id: String, name: String, color: String, model: String) {
            self.id = id
            self.name = name
            self.color = color
            self.model = model
        }
    }

    /// What only the app knows: how to name MCP tools, agents and apps.
    public struct Names: Encodable, Equatable, Sendable {
        public var conversationId: Int
        /// The conversation's agent, for VoiceOver's name for each answer.
        public var agentName: String
        /// Tool name to "Server: tool".
        public var mcp: [String: String]
        public var agents: [Agent]
        /// Bundle ID to app name, for the apps computer-use calls in this transcript name.
        public var apps: [String: String]
        /// Whether the conversation has a folder, in which a relative link in an answer names a file (#451).
        public var folder = false

        public init(conversationId: Int, agentName: String, mcp: [String: String], agents: [Agent], apps: [String: String], folder: Bool = false) {
            self.conversationId = conversationId
            self.agentName = agentName
            self.mcp = mcp
            self.agents = agents
            self.apps = apps
            self.folder = folder
        }
    }

    /// A model Try Again can use, as the model selector lists it.
    public struct ModelChoice: Encodable, Equatable, Sendable {
        public var provider: String
        public var id: String
        public var name: String
        /// The provider's name, which the list is grouped by.
        public var group: String

        public init(provider: String, id: String, name: String, group: String) {
            self.provider = provider
            self.id = id
            self.name = name
            self.group = group
        }
    }

    /// What a chat adds to the page (#285): Try Again, Edit, the step between versions, and sources. `enabled` is
    /// false for an agent's conversation, and the page shows none of it.
    public struct Chat: Encodable, Equatable, Sendable {
        public var enabled: Bool
        public var versions: [VersionPoint]
        public var models: [ModelChoice]
        /// The model in use, as "provider/id".
        public var model: String

        public static let none = Chat(enabled: false, versions: [], models: [], model: "")

        /// Whether the page shows a chat's controls: only for a chat, as the engine says (#283).
        public static func shown(for state: ConversationState?) -> Bool {
            state?.chat == true
        }

        public init(enabled: Bool, versions: [VersionPoint], models: [ModelChoice], model: String) {
            self.enabled = enabled
            self.versions = versions
            self.models = models
            self.model = model
        }
    }

    /// Whether the conversation has entries older than all the app has, which the page asks for when the reader nears
    /// its top, and whether they are being asked for (#440).
    public struct Older: Encodable, Equatable, Sendable {
        public var more: Bool
        public var loading: Bool

        public static let none = Older(more: false, loading: false)

        public init(more: Bool, loading: Bool) {
            self.more = more
            self.loading = loading
        }
    }

    /// One reach request or proposed rule waiting under Needs you, as the `needs` event sends it (docs/projects.md,
    /// 3.9) with the fields the conversation's card reads. Every kind shares the base fields, so the whole array
    /// decodes whatever kinds are in it, and a kind this app knows nothing of cannot take the list down.
    public struct Need: Codable, Equatable, Identifiable, Sendable {
        /// A reach request's change, as the person reads it (7.2): what it would let agents do.
        public struct ReachChange: Codable, Equatable, Sendable {
            public let summary: String

            public init(summary: String) {
                self.summary = summary
            }
        }

        public let id: String
        /// "reach" or "rule".
        public let kind: String
        public let conversationId: Int
        public let agentName: String?
        /// Milliseconds since 1970.
        public let createdAt: Double
        public let change: ReachChange?
        /// A proposed rule: its text and whom it would bind, and why the agent proposes it.
        public let text: String?
        public let binds: String?
        public let why: String?

        public init(id: String, kind: String, conversationId: Int, agentName: String?, createdAt: Double, change: ReachChange?, text: String?, binds: String?, why: String?) {
            self.id = id
            self.kind = kind
            self.conversationId = conversationId
            self.agentName = agentName
            self.createdAt = createdAt
            self.change = change
            self.text = text
            self.binds = binds
            self.why = why
        }
    }

    public struct Message: Encodable, Sendable {
        public var reset: Bool?
        /// Entries to put before the first the page has, oldest first (#380).
        public var older: [Item]?
        /// How many entries older than those the page has are still to come.
        public var earlier: Int?
        /// Whether there are older entries still to ask for, and whether they are on their way (#440).
        public var history: Older?
        public var items: [Item]?
        public var live: Live?
        public var inbox: [InboxItem]?
        /// The changes made in this conversation of a project (docs/projects.md, 3.12), each drawn where the tool call
        /// that made it is, with its Undo.
        public var changes: [ProjectChangeLine]?
        /// The reach requests and proposed rules waiting from this conversation (3.9), drawn as cards at the calls that
        /// asked for them and answered in place.
        public var needs: [Need]?
        public var names: Names?
        public var palette: [String: String]?
        public var chat: Chat?
    }

    /// The page is sent a long conversation newest first, as the engine sends it to the app (#380, engine/src/opening.ts):
    /// at first the newest entries, as many as come to about `firstBytes` or number `firstCount`, then the older ones,
    /// about `olderBytes` at a time, each once the page has drawn the one before.
    public static let firstBytes = 64 * 1024
    public static let firstCount = 40
    public static let olderBytes = 256 * 1024

    /// The entries sent: `sentCount` of them, from the one whose id is `firstSent` to `lastSent`.
    private var sentCount = 0
    private var firstSent: Int?
    private var lastSent: Item?
    /// How many entries the app has before those the page was sent, still to be sent.
    public private(set) var pending = 0
    private var earlier: Int?
    private var history: Older?
    private var live: Live?
    private var inbox: [InboxItem]?
    private var changes: [ProjectChangeLine]?
    private var needs: [Need]?
    private var names: Names?
    private var palette: [String: String]?
    private var chat: Chat?
    private var startOver = false

    /// Forget what was sent and start the page's list over: for a page that has just loaded (or reloaded after its
    /// process ended), or a view now showing another conversation.
    public mutating func restart() {
        self = TranscriptFeed()
        startOver = true
    }

    /// The update that brings the page from what it was last sent to this, or nil when nothing changed.
    /// `earlier` is how many older entries the engine is still to send the app; with `withOlder` false, older entries the
    /// app has wait (the page has not yet drawn the part before them).
    public mutating func update(items: [Item], earlier: Int = 0, older: Older = .none, state: ConversationState?, inbox: [InboxItem], changes: [ProjectChangeLine] = [], needs: [Need] = [], names: Names, palette: [String: String], chat: Chat = .none, withOlder: Bool = true) -> Message? {
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
        if changes != self.changes {
            message.changes = changes
            self.changes = changes
            changed = true
        }
        if needs != self.needs {
            message.needs = needs
            self.needs = needs
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
    public static func partStart(_ items: [Item], end: Int, bytes: Int, count: Int = .max) -> Int {
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
    public static func size(of item: Item) -> Int {
        item.text.utf8.count + (item.thinking?.utf8.count ?? 0) + (item.error?.utf8.count ?? 0) + 200 * (1 + (item.toolCalls?.count ?? 0))
    }

    /// The message as the JSON text the page parses. The page is handed it as a string argument, never as script.
    public static func json(_ message: Message) -> String? {
        let encoder = JSONEncoder()
        // Sorted, so a call's arguments are summarised in the same order every time.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The bundle IDs computer-use calls name, in the transcript and in what is waiting on the person.
    public static func appsNamed(in items: [Item], partial: PartialAnswer?, inbox: [InboxItem]) -> Set<String> {
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

    public init() {}
}
