import Foundation
import Observation
import PiModels

/// What a program holding a session keeps of a conversation's message field: its unsent input. The session makes one
/// for each conversation it opens, keeps one with input when the conversation closes, and discards it when the
/// conversation goes. The Mac app's is `ConversationDraft`.
@MainActor
public protocol MessageDraft: AnyObject {
    init()
    var hasInput: Bool { get }
    func discard()
}

/// What the session cannot do by itself, done by the program that holds it: the Mac app starts the engine and connects
/// again, writes its log, notifies the person, keeps its sidebar's projects, and does what only the Mac does (sign-in,
/// and working other apps and pages for agents). Every method does nothing unless the host says otherwise.
@MainActor
public protocol EngineSessionHost: AnyObject {
    /// The connection is ready and the session connected, before it asks again for the conversations it had open.
    func sessionConnected()
    /// The connection failed or closed, and the session let it go and failed every request waiting for an answer.
    func sessionLost()
    /// A line for the host's log, for working out why a connection dropped.
    func note(_ message: String)
    /// An event only the host reads (`auth`, `computer`, `browser`), as sent.
    func handle(_ event: String, _ line: Data, decoder: JSONDecoder) throws
    /// What the session read that a store of the host's own takes in too (the Mac's projects in the sidebar).
    func took(conversations: [ConversationSummary])
    func took(activity: [ActivityRun])
    func took(projects: SidebarProjectsEvent)
    func took(needs: [NeedRef])
    /// The needs that were not in the list before, once the list is kept.
    func needsArrived(_ new: [NeedItem])
    /// The `limits` event came, and is kept in `extras`.
    func limitsArrived()
}

extension EngineSessionHost {
    public func sessionConnected() {}
    public func sessionLost() {}
    public func note(_ message: String) {}
    public func handle(_ event: String, _ line: Data, decoder: JSONDecoder) throws {}
    public func took(conversations: [ConversationSummary]) {}
    public func took(activity: [ActivityRun]) {}
    public func took(projects: SidebarProjectsEvent) {}
    public func took(needs: [NeedRef]) {}
    public func needsArrived(_ new: [NeedItem]) {}
    public func limitsArrived() {}
}

/// Where the session says what its work costs, for the Mac app's speed probe (`PerfProbe`, #347).
@MainActor
public protocol EngineProbe {
    static func now() -> Double
    static func sent(_ id: Int, _ method: String)
    static func answered(_ id: Int) -> String?
    static func event(_ kind: String, bytes: Int, since start: Double)
    static func opening(_ id: Int, _ step: String, rest: Bool)
    static func note(_ text: String)
}

extension EngineProbe {
    static func opening(_ id: Int, _ step: String) { opening(id, step, rest: false) }
}

/// Measures nothing, for a session no probe watches.
enum NoProbe: EngineProbe {
    static func now() -> Double { 0 }
    static func sent(_ id: Int, _ method: String) {}
    static func answered(_ id: Int) -> String? { nil }
    static func event(_ kind: String, bytes: Int, since start: Double) {}
    static func opening(_ id: Int, _ step: String, rest: Bool) {}
    static func note(_ text: String) {}
}

/// Talks to pi2-engine, and keeps what it sends: requests and their answers, and the engine's events read into the
/// models the views read. Everything shown is the engine's committed state, mirrored here; the app keeps no truth of
/// its own. The Mac app's `EngineClient` holds one, and does with it what only the Mac does (docs/iphone.md section 8).
@MainActor
@Observable
public final class EngineSession<Draft: MessageDraft> {
    public enum Status: Equatable {
        case connecting
        case connected
        case restarting
    }

    public private(set) var status: Status = .connecting
    public private(set) var conversations: [ConversationSummary] = []
    /// The Archive, newest first.
    public private(set) var archived: [ArchivedConversation] = []
    /// After how many unused days a conversation is archived on its own; nil for never.
    public private(set) var autoArchiveDays: Int?
    /// The conversations the app has asked the engine for, which it keeps sending. The list changes only as one is opened
    /// or closed; each conversation's updates go to its own object, so they redraw only the views that show it.
    public private(set) var open: [Int: OpenConversation<Draft>] = [:]
    /// Only drafts with input survive closing a transcript. Keeping one here does not subscribe to the conversation.
    @ObservationIgnored private var parkedDrafts: [Int: Draft] = [:]
    /// Messages the person sent that the conversation does not show yet, by conversation, oldest first.
    public private(set) var outgoing: [Int: [OutgoingMessage]] = [:]
    public private(set) var providers: [ProviderInfo] = []
    /// Every model of every connected provider, including the ones hidden in Settings.
    public private(set) var allModels: [ModelInfo] = []
    /// The models the pickers offer.
    public var models: [ModelInfo] { allModels.filter { $0.hidden != true } }
    /// The models the pickers offer, by provider in name order. Two providers can offer a model with the same id,
    /// so a list that mixes providers identifies its rows by `ModelInfo.ref`, never by `id`.
    public var modelGroups: [(provider: String, name: String, models: [ModelInfo])] {
        Dictionary(grouping: models, by: \.provider)
            .map { (provider: $0.key, name: $0.value[0].providerName, models: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public private(set) var defaultModel: ModelRef?
    /// Whether the first-run welcome has been completed for this data folder. Nil until the engine has said.
    public private(set) var onboarded: Bool?
    /// The templates: agents that belong to no project, kept under Shared to make a project's agents from. A project's
    /// own agents are left out of them.
    public private(set) var agents: [AgentProfile] = []
    /// Every agent, the projects' own included, for finding one by id: a conversation's agent can be a project's.
    public private(set) var allAgents: [AgentProfile] = []
    /// The built-in tools an agent's settings list, sent with the agents. Empty from an engine older than the list.
    public private(set) var builtInTools: [BuiltInTool] = []
    /// The picture models the person's providers can use, for making pictures (engine/src/pictures.ts), and the providers
    /// that have such models at all, by name, for saying where to get one when there is none. Nil until the engine says.
    public private(set) var pictures: PictureModels?
    /// The models that can look at pictures for one that cannot see them, and the person's choice (engine/src/picturelook.ts).
    /// Nil until the engine says.
    public private(set) var look: LookModels?
    /// The approvals and questions waiting in each conversation, as the `inbox` event sends them, for the cards in a
    /// conversation's page. What waits for the person, counted and notified, is `needs` (docs/projects.md, 10.3, #481).
    public private(set) var inbox: [InboxItem] = []
    public private(set) var hasLoadedLibrary = false
    public private(set) var activity: [ActivityRun] = []
    /// How many runs `activity` lists, for the sidebar, which need not be drawn again for every change to a run.
    public private(set) var runningCount = 0
    /// The runs waiting for a provider's limit, by conversation; and those of sub-chats, by the conversation they belong to.
    public private(set) var limitWaits: [Int: LimitWait] = [:]
    public private(set) var subChatLimitWaits: [Int: [LimitWait]] = [:]
    /// Conversations in the sidebar whose every run, their own and their sub-chats', waits for a limit.
    public private(set) var heldByLimits: Set<Int> = []
    /// Commands agents left running in the background, oldest first.
    public private(set) var backgroundCommands: [BackgroundCommand] = []
    /// What will wake an agent when it ends, and what has and waits for it (docs/wakes.md).
    public private(set) var wakes: [WakeItem] = []
    public private(set) var wakeHolds: [WakeHold] = []
    /// Models running on this Mac (`local.running`).
    public private(set) var localRunning: [LocalServer] = []
    /// The conversations the window shows in its panes, as the engine was last told (`conversations.shown`).
    private var shown: Set<Int> = []
    public private(set) var schedules: [Schedule] = []
    public private(set) var recovery: RecoveryReport?
    public private(set) var usage: UsageSummary?
    public private(set) var mcpServers: [McpServer] = []
    /// The branch each conversation's folder is on, for conversations working in a git repository.
    public private(set) var branches: [Int: BranchStatus] = [:]
    /// Worktrees of conversations that were archived or deleted, newest first.
    public private(set) var leftBehind: [LeftBehindWorktree] = []
    /// The projects, as the `projects` event last said (docs/projects.md, 4.3).
    public private(set) var projects: [ProjectRow] = []
    /// Everything waiting for the person, of every project and none, as the `needs` event sends it (docs/projects.md,
    /// 3.9): the Now tab's cards. The sidebar's counts, and the Rules tab's proposals, come of the same reading.
    public private(set) var needs: [NeedItem] = []
    /// Each project's rules, from the `projectRules` event (docs/projects.md, 4.3): the Rules tab reads it.
    public private(set) var projectRules: [String: [ProjectRule]] = [:]
    /// Proposed rules waiting under Needs you, by project, from the `needs` event (docs/projects.md, 3.9); the Rules
    /// tab shows their cards.
    public private(set) var ruleNeeds: [String: [NeedItem]] = [:]
    /// The reach requests and proposed rules waiting under Needs you, as the `needs` event sends them (3.9), for the
    /// cards at the calls that asked in a conversation's page (#474).
    public private(set) var conversationNeeds: [TranscriptFeed.Need] = []
    /// Asked to show a conversation where it lives (`AppModel.openConversation`), for example a fork that was just made;
    /// `from` is the conversation it was opened from, when there is one, which places a sub-chat no list names.
    public var onNavigate: (_ id: Int, _ from: Int?) -> Void = { _, _ in }
    /// Asked to show a conversation (a sub-chat) in a pane beside another (the conversation it came from).
    public var onOpenBeside: (_ id: Int, _ beside: Int) -> Void = { id, _ in }
    public var lastError: String?
    /// The latest event of each kind that a feature in a file of its own reads ("limits", "memory"), as sent.
    public let extras = ExtraEvents()

    /// What only the program holding the session does: starting the engine, its log, notifications, its own stores.
    @ObservationIgnored public weak var host: (any EngineSessionHost)?
    /// The speed probe the session reports to, if any.
    @ObservationIgnored public var probe: any EngineProbe.Type = NoProbe.self

    /// What carries the connection to the engine, while there is one.
    public private(set) var transport: (any EngineTransport)?
    private var buffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    public init() {}

    // MARK: - Requests

    @discardableResult
    public func call(_ method: String, _ params: [String: Any] = [:]) async throws -> JSONValue {
        guard let transport, status == .connected else { throw EngineError(message: "The engine is not running yet.", unanswered: true) }
        let id = nextRequestID
        nextRequestID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(0x0A)
        probe.sent(id, method)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            transport.send(data)
        }
    }

    /// Runs a request whose only interesting outcome is failure, and shows that failure in the window.
    public func perform(_ method: String, _ params: [String: Any] = [:]) {
        Task {
            do { try await call(method, params) } catch { lastError = error.localizedDescription }
        }
    }

    /// Starts a conversation with an agent: one of a project's (docs/projects.md, 3.5), or a template, whose conversation
    /// the engine carries into the project of its folder (9.9).
    public func createConversation(agentId: String) async -> Int? {
        do {
            let result = try await call("conversation.create", ["agentId": agentId])
            guard let id = result["id"]?.intValue else { return nil }
            openConversation(id)
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Opens a conversation, or keeps one open a while longer. With `tail`, only its newest entries are asked for, and
    /// nothing older comes unless asked (#618): the Dashboard's window onto each orchestrator shows only the end of the
    /// conversation. A conversation opened so and then shown whole, in a pane or a hub, is asked for again from the start.
    public func openConversation(_ id: Int, tail: Bool = false) {
        if !tail { probe.opening(id, "asked") }
        lastWanted[id] = Date()
        if open[id] != nil {
            if !tail, tailOnly.remove(id) != nil, status == .connected {
                Task {
                    _ = try? await call("conversation.close", ["id": id])
                    requestOpen(id)
                }
            }
            return
        }
        if tail { tailOnly.insert(id) }
        open[id] = OpenConversation(draft: parkedDrafts.removeValue(forKey: id) ?? Draft())
        // Panes restored at launch appear before the app has connected. Connecting asks for every open conversation,
        // so one opened before then waits for that rather than failing.
        guard status == .connected else { return }
        requestOpen(id)
    }

    /// Asks the engine for a conversation's entries and to keep sending them. A pane kept from last time can name a
    /// conversation this data folder does not have (the layout is kept with the app's settings, not in the data folder),
    /// and it asks before the library has been seen. The engine sends the library before it answers anything, so when it
    /// does not know the conversation and the library does not list it, the request is let go quietly: the window empties
    /// that pane once the library is in. A conversation the library lists that fails to open is still reported.
    private func requestOpen(_ id: Int) {
        let tail = tailOnly.contains(id)
        if !tail { probe.opening(id, "sent") }
        Task {
            do {
                // A long conversation comes newest first, and the rest just after (#380); an older engine sends it whole.
                // Only the newest part, for the Dashboard (#618); an engine from before that sends the rest too.
                try await call("conversation.open", tail ? ["id": id, "newestFirst": true, "tail": true] : ["id": id, "newestFirst": true])
                probe.opening(id, "answered")
            } catch {
                if hasLoadedLibrary, !conversations.contains(where: { $0.id == id }), !archived.contains(where: { $0.id == id }) {
                    open[id] = nil
                    tailOnly.remove(id)
                    return
                }
                lastError = error.localizedDescription
            }
        }
    }

    /// Asks the engine for the part of a conversation just before the entries the app has (#440), which comes as a
    /// `conversation.older` event before the answer. One request a conversation at a time, and only when there is
    /// more and nothing else is on its way. An engine from before #440 does not know the request, and anything else
    /// that goes wrong leaves the conversation as it is: either way, nothing older is offered again until it starts over.
    public func loadOlder(_ id: Int) {
        guard let data = open[id], data.more, data.earlier == 0, !data.loadingOlder, status == .connected else { return }
        data.loadingOlder = true
        Task {
            defer { data.loadingOlder = false }
            do {
                let result = try await call("conversation.older", ["id": id])
                if result["more"] == .bool(false) { data.noMore() }
            } catch {
                data.noMore()
            }
        }
    }

    /// Tells the engine which conversations the panes show, when that changes: a model on this Mac stays loaded while a
    /// conversation using it is shown (docs/local-models-running.md).
    public func setShown(_ ids: Set<Int>) {
        guard ids != shown else { return }
        // What was on screen until now was wanted until now.
        for id in shown.union(ids) { lastWanted[id] = Date() }
        shown = ids
        sendShown()
    }

    /// When each open conversation was last on screen or asked for.
    @ObservationIgnored private var lastWanted: [Int: Date] = [:]
    /// The open conversations asked for with only their newest entries, for the Dashboard (#618).
    @ObservationIgnored private var tailOnly: Set<Int> = []
    /// The conversation Quick Ask shows, which no pane may: it is kept open while the panel has it.
    @ObservationIgnored public var quickAskConversation: Int?
    /// How long a conversation no longer on screen keeps coming from the engine, so that going back to it is instant.
    private static var keptOpen: TimeInterval { 120 }

    /// Closes the conversations nothing has shown for a while. Otherwise every conversation looked at since launch keeps
    /// coming from the engine, several times a second while it works, to be read and kept for nothing (#347).
    public func closeUnwanted() {
        guard status == .connected else { return }
        let now = Date()
        for id in open.keys where !shown.contains(id) && id != quickAskConversation && outgoing[id] == nil {
            guard now.timeIntervalSince(lastWanted[id] ?? .distantPast) > Self.keptOpen else { continue }
            if let draft = open[id]?.draft, draft.hasInput { parkedDrafts[id] = draft }
            open[id] = nil
            lastWanted[id] = nil
            tailOnly.remove(id)
            Task { _ = try? await call("conversation.close", ["id": id]) }
        }
    }

    private func sendShown() {
        guard status == .connected else { return }
        let ids = shown.sorted()
        Task { _ = try? await call("conversations.shown", ["ids": ids]) }
    }

    public enum SubmitOutcome: Sendable { case sent, refused, unconfirmed }

    /// Sends a message and shows why if it is refused or could not be confirmed.
    /// `attachments` are pictures and files to go with it, as `ComposerAttachments.Draft.payload` makes them.
    ///
    /// Until the engine has it, and then until the conversation shows it, the message is in `outgoing`, which the
    /// message field shows. When no answer comes because the engine is not connected or the connection goes, the message
    /// is sent again once the engine is back, with the same request id, which makes the engine find the submission it
    /// may already have taken rather than take it twice. After a minute without an engine, acceptance is unknown.
    @discardableResult
    public func submit(_ text: String, attachments: [[String: Any]] = [], to id: Int, steer: Bool) async -> SubmitOutcome {
        let requestId = UUID().uuidString
        var params: [String: Any] = ["id": id, "text": text, "mode": steer ? "steer" : "queue", "requestId": requestId]
        if !attachments.isEmpty { params["attachments"] = attachments }
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")" : text
        outgoing[id, default: []].append(OutgoingMessage(id: requestId, summary: summary))
        let asked = probe.now()
        let lastBefore = open[id]?.items.last?.id
        let deadline = ContinuousClock.now + .seconds(60)
        var unanswered = false
        while true {
            do {
                let result = try await call("submit", params)
                probe.note("submit to \(id) accepted in \(Int(((probe.now() - asked) * 1000).rounded()))ms")
                // Shown as taken until the conversation shows it (in `handle`), and for a few seconds at most. The
                // update that shows it can come before this answer.
                let submission = result["submissionId"]?.intValue ?? 0
                let shown = open[id]?.hasMessage(after: lastBefore) == true
                if shown || open[id]?.state?.queued.contains(where: { $0.id == submission }) == true {
                    dropOutgoing(requestId, from: id)
                } else if let index = outgoing[id]?.firstIndex(where: { $0.id == requestId }) {
                    outgoing[id]?[index].submission = submission
                }
                Task {
                    try? await Task.sleep(for: .seconds(open[id] == nil ? 0 : 3))
                    dropOutgoing(requestId, from: id)
                }
                return .sent
            } catch let error as EngineError where error.unanswered {
                unanswered = true
                if await connected(by: deadline) { continue }
                dropOutgoing(requestId, from: id)
                lastError = "The engine did not come back for a minute. The message may have been sent before it stopped. Check the conversation before sending it again."
                return .unconfirmed
            } catch {
                dropOutgoing(requestId, from: id)
                // A retry can be refused before it reaches the engine's submission lookup (e.g. after archiving).
                lastError = unanswered
                    ? "The message may have been sent before the connection was lost. Check the conversation before sending it again. \(error.localizedDescription)"
                    : error.localizedDescription
                return unanswered ? .unconfirmed : .refused
            }
        }
    }

    private func dropOutgoing(_ requestId: String, from id: Int) {
        outgoing[id]?.removeAll { $0.id == requestId }
        if outgoing[id]?.isEmpty == true { outgoing[id] = nil }
    }

    /// Waits a moment, then until the engine is connected, up to `deadline`. True once it is.
    private func connected(by deadline: ContinuousClock.Instant) async -> Bool {
        repeat {
            try? await Task.sleep(for: .milliseconds(200))
            guard ContinuousClock.now < deadline else { return false }
        } while status != .connected
        return true
    }

    public func configure(_ id: Int, _ change: [String: Any]) {
        var params = change
        params["id"] = id
        perform("conversation.configure", params)
    }

    /// Branch a conversation at one of its entries and show the new one: by `then`, given, as a project's hub shows it in
    /// place of its board (#632), else as the window shows any conversation chosen.
    public func fork(_ id: Int, at entryId: Int, then show: ((Int) -> Void)? = nil) {
        Task {
            do {
                let result = try await call("conversation.fork", ["id": id, "entryId": entryId])
                if let fork = result["id"]?.intValue {
                    openConversation(fork)
                    if let show { show(fork) } else { onNavigate(fork, nil) }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func search(_ query: String) async -> [SearchResult] {
        guard let result = try? await call("search", ["query": query]), let data = try? JSONEncoder().encode(result["results"] ?? .array([])) else { return [] }
        return (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
    }

    /// Conversations that are not sub-chats, newest first. Chats are chat mode's own (`chats`), so the projects' side never
    /// lists them.
    public var rootConversations: [ConversationSummary] { conversations.filter { $0.parent == nil && !$0.isChat } }

    public func agent(_ id: String?) -> AgentProfile? {
        allAgents.first { $0.id == id }
    }

    /// Lets go of every open conversation and every kept draft, as after a backup is restored: the restored database
    /// can use the same IDs for different conversations.
    public func forgetConversations() {
        for conversation in open.values { conversation.draft.discard() }
        for draft in parkedDrafts.values { draft.discard() }
        parkedDrafts.removeAll()
        open = [:]
    }

    // MARK: - Connection

    /// Connects to the engine over `transport`.
    public func connect(_ transport: any EngineTransport) {
        self.transport = transport
        buffer.removeAll()
        transport.start { [weak self, weak transport] event in
            guard let self, let transport, self.transport === transport else { return }
            switch event {
            case .ready:
                self.status = .connected
                self.host?.sessionConnected()
                // The engine forgets subscriptions with the connection; ask again for what is on screen.
                for id in self.open.keys { self.requestOpen(id) }
                self.sendShown()
            case .received(let data):
                self.consume(data)
            case .failed(let error):
                if self.status == .connected { self.host?.note("connection failed: \(error)") }
                self.retry()
            case .closed(let why):
                self.host?.note("connection lost: \(why)")
                self.status = .restarting
                self.retry()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // A picture arrives as one long line in many pieces; only a piece with a line break can finish one.
        guard data.contains(0x0A) else { return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handle(line) }
        }
    }

    private struct Envelope: Decodable {
        let event: String?
        let id: Int?
        let error: String?
        /// Beside `error`, what a refusal carries for the app to act on (docs/projects.md, 4.1).
        let data: [String: JSONValue]?
        let result: JSONValue?
    }
    private struct LibraryEvent: Decodable {
        let conversations: [ConversationSummary]
        let archived: [ArchivedConversation]?
        let autoArchiveDays: Int?
    }
    public struct PictureModels: Decodable, Equatable {
        public struct Model: Decodable, Equatable {
            public struct Price: Decodable, Equatable {
                public let input: Double
                public let output: Double
            }
            public let provider: String
            public let id: String
            public let name: String
            public let providerName: String?
            public let canEdit: Bool?
            public let price: Price?
            public var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
            public var displayName: String { "\(providerName ?? provider) · \(name)" }
        }
        public let model: ModelRef?
        public let models: [Model]
        public let makers: [String]
    }
    /// The models the person's connected providers offer that take pictures, for looking at ones a conversation's own
    /// model cannot see (engine/src/picturelook.ts, #540). Nil until the engine says.
    public struct LookModels: Decodable, Equatable {
        public struct Model: Decodable, Equatable {
            public struct Price: Decodable, Equatable {
                public let input: Double
                public let output: Double
            }
            public let provider: String
            public let id: String
            public let name: String
            public let providerName: String?
            public let price: Price?
            public var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
            public var displayName: String { "\(providerName ?? provider) · \(name)" }
        }
        public let model: ModelRef?
        public let models: [Model]
    }
    private struct AgentsEvent: Decodable {
        let agents: [AgentProfile]
        let builtInTools: [BuiltInTool]?
    }
    private struct BranchesEvent: Decodable {
        let conversations: [String: BranchStatus]
        let leftBehind: [LeftBehindWorktree]?
    }
    private struct InboxEvent: Decodable { let items: [InboxItem] }
    private struct ActivityEvent: Decodable { let runs: [ActivityRun] }
    private struct BackgroundEvent: Decodable { let commands: [BackgroundCommand] }
    private struct WakesEvent: Decodable {
        let items: [WakeItem]
        let held: [WakeHold]
    }
    private struct SchedulesEvent: Decodable { let schedules: [Schedule] }
    private struct RecoveryEvent: Decodable { let recovery: RecoveryReport? }
    private struct McpEvent: Decodable { let servers: [McpServer] }
    private struct ProvidersEvent: Decodable {
        let providers: [ProviderInfo]
        let models: [ModelInfo]
        let defaultModel: ModelRef?
        let onboarded: Bool?
    }
    private struct ConversationEvent: Decodable {
        let id: Int
        let reset: Bool
        let items: [Item]
        let state: ConversationState
        /// With a list sent from the start, how many older entries are still to come; absent from an older engine.
        let earlier: Int?
        /// With a list sent from the start, whether the conversation has entries older than it, to ask for (#440).
        let more: Bool?
    }
    /// Entries that go before those the app has, oldest first, how many are still to come after them, and whether
    /// there are older ones to ask for.
    private struct OlderEvent: Decodable {
        let id: Int
        let items: [Item]
        let earlier: Int
        let more: Bool?
    }

    private func handle(_ line: Data) {
        let started = probe.now()
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return }
        defer {
            let kind = envelope.event ?? envelope.id.flatMap { probe.answered($0) }.map { "reply \($0)" } ?? "reply"
            probe.event(kind, bytes: line.count, since: started)
        }
        do {
            switch envelope.event {
            case "library":
                let event = try decoder.decode(LibraryEvent.self, from: line)
                if (!parkedDrafts.isEmpty || !open.isEmpty), event.conversations != conversations {
                    let listed = Set(event.conversations.map(\.id))
                    // The previous list also covers sub-chats that disappear when their parent is put away.
                    for row in conversations where !listed.contains(row.id) {
                        open[row.id]?.draft.discard()
                        parkedDrafts.removeValue(forKey: row.id)?.discard()
                    }
                }
                update(\.conversations, event.conversations)
                host?.took(conversations: event.conversations)
                update(\.archived, event.archived ?? [])
                update(\.autoArchiveDays, event.autoArchiveDays)
                update(\.hasLoadedLibrary, true)
            case "agents":
                let event = try decoder.decode(AgentsEvent.self, from: line)
                update(\.allAgents, event.agents)
                update(\.agents, event.agents.filter { $0.projectId == nil })
                update(\.builtInTools, event.builtInTools ?? [])
            case "pictures":
                update(\.pictures, try decoder.decode(PictureModels.self, from: line))
            case "look":
                update(\.look, try decoder.decode(LookModels.self, from: line))
            case "inbox":
                update(\.inbox, try decoder.decode(InboxEvent.self, from: line).items)
            case "activity":
                update(\.activity, try decoder.decode(ActivityEvent.self, from: line).runs)
                update(\.runningCount, activity.count)
                host?.took(activity: activity)
                // By conversation, and by the conversation that handed the work out, for the rows and the line that show a
                // run waiting for a provider's limit rather than working (#343). Set only when changed, so the views that
                // read them are not drawn again for every clock tick of a command.
                let waits = Dictionary(activity.compactMap { run in run.limit.map { (run.conversationId, $0) } }, uniquingKeysWith: { first, _ in first })
                if waits != limitWaits { limitWaits = waits }
                let bySubChats = Dictionary(grouping: activity.filter { $0.limit != nil && $0.parent != nil }, by: { $0.parent! }).mapValues { $0.compactMap(\.limit) }
                if bySubChats != subChatLimitWaits { subChatLimitWaits = bySubChats }
                // A conversation whose every run, its own and its sub-chats', waits for a limit is waiting too, not working.
                let held = Set(Dictionary(grouping: activity, by: \.rootConversationId).filter { $0.value.allSatisfy { $0.limit != nil } }.keys)
                if held != heldByLimits { heldByLimits = held }
            case "background":
                update(\.backgroundCommands, try decoder.decode(BackgroundEvent.self, from: line).commands)
            case "wakes":
                let event = try decoder.decode(WakesEvent.self, from: line)
                update(\.wakes, event.items)
                update(\.wakeHolds, event.held)
            case "local.running":
                update(\.localRunning, try decoder.decode(LocalRunningEvent.self, from: line).running)
            case "schedules":
                update(\.schedules, try decoder.decode(SchedulesEvent.self, from: line).schedules)
            case "recovery":
                update(\.recovery, try decoder.decode(RecoveryEvent.self, from: line).recovery)
            case "usage":
                update(\.usage, try decoder.decode(UsageSummary.self, from: line))
            case "mcp":
                update(\.mcpServers, try decoder.decode(McpEvent.self, from: line).servers)
            case "branches":
                let event = try decoder.decode(BranchesEvent.self, from: line)
                update(\.branches, Dictionary(uniqueKeysWithValues: event.conversations.compactMap { key, value in Int(key).map { ($0, value) } }))
                update(\.leftBehind, event.leftBehind ?? [])
            case "projects":
                // One the app cannot read is noted in app.log and leaves the window as it was.
                guard let event = try? decoder.decode(ProjectsEvent.self, from: line) else {
                    host?.note("The engine's projects event could not be read; projects are not shown.")
                    return
                }
                update(\.projects, event.projects)
                // What the sidebar and Settings read of it (Projects.swift): without the orchestrator's last words, which
                // change with every finished answer and would draw the list of projects again for nothing.
                if let sidebar = try? decoder.decode(SidebarProjectsEvent.self, from: line) { host?.took(projects: sidebar) }
            case "providers":
                let event = try decoder.decode(ProvidersEvent.self, from: line)
                update(\.providers, event.providers)
                update(\.allModels, event.models)
                update(\.defaultModel, event.defaultModel)
                update(\.onboarded, event.onboarded ?? true)
            case "conversation":
                let event = try decoder.decode(ConversationEvent.self, from: line)
                guard let data = open[event.id] else { return }
                let first = data.state == nil
                data.apply(reset: event.reset, items: event.items, state: event.state, earlier: event.earlier, more: event.more)
                // A message the engine has taken goes from the field once the conversation shows it: in the queue, or as
                // a message of the person's in the transcript.
                if outgoing[event.id]?.contains(where: { $0.submission != nil }) == true {
                    let queued = Set(event.state.queued.map(\.id))
                    let arrived = event.reset || event.items.contains { $0.kind == "user" }
                    outgoing[event.id]?.removeAll { $0.submission.map { arrived || queued.contains($0) } ?? false }
                    if outgoing[event.id]?.isEmpty == true { outgoing[event.id] = nil }
                }
                if first {
                    let more = data.earlier > 0 ? ", \(data.earlier) earlier to come" : ""
                    probe.opening(event.id, "entries \(data.items.count) (\(line.count / 1024) KB, \(Int(((probe.now() - started) * 1000).rounded()))ms to read\(more))", rest: data.earlier > 0)
                }
            case "conversation.older":
                let event = try decoder.decode(OlderEvent.self, from: line)
                guard let data = open[event.id] else { return }
                data.prepend(event.items, earlier: event.earlier, more: event.more)
                if event.earlier == 0 { probe.opening(event.id, "all \(data.items.count) in") }
            case "needs":
                // One reading of the event for all three: the sidebar's count of what waits, a proposed rule waiting to
                // be answered, which the Rules tab shows, and the Now tab's cards. The whole array decodes whatever kinds
                // are in it, so a need of a kind this app knows nothing of cannot take any of them down.
                let needs = try decoder.decode(NeedItemsEvent.self, from: line).items
                host?.took(needs: needs.map { NeedRef(projectId: $0.projectId) })
                var proposals: [String: [NeedItem]] = [:]
                for need in needs where need.kind == "rule" {
                    if let projectId = need.projectId { proposals[projectId, default: []].append(need) }
                }
                let known = Set(self.needs.map(\.id))
                update(\.ruleNeeds, proposals)
                update(\.needs, needs)
                // This list is what waits for the person: the Dock's badge, and the notifications, come from it (10.3, #481).
                host?.needsArrived(needs.filter { !known.contains($0.id) })
                // The reach requests and proposed rules a conversation's page shows cards for (#474), from the same
                // reading of the event, with only what a card reads.
                let shown = needs.filter { $0.kind == "reach" || $0.kind == "rule" }.map {
                    TranscriptFeed.Need(
                        id: $0.id, kind: $0.kind, conversationId: $0.conversationId, agentName: $0.agentName, createdAt: $0.createdAt,
                        change: $0.change.map { TranscriptFeed.Need.ReachChange(summary: $0.summary) }, text: $0.text, binds: $0.binds?.rawValue, why: $0.why
                    )
                }
                update(\.conversationNeeds, shown)
            case "projectRules":
                update(\.projectRules, try decoder.decode(ProjectRulesEvent.self, from: line).projects)
            case "auth", "computer", "browser":
                // The host's alone: sign-in, and the Mac's host roles.
                try host?.handle(envelope.event ?? "", line, decoder: decoder)
            case "limits", "memory", "coauthor", "priority", "local", "chat", "compactionSettings", "work", "github", "reports", "awake", "agentDefault":
                // Events that belong to a feature in a file of its own; it reads its latest one from `extras`.
                extras[envelope.event ?? ""] = try decoder.decode(JSONValue.self, from: line)
                if envelope.event == "limits" { host?.limitsArrived() }
            case "local.progress":
                // One download's progress, kept in the `local` event it belongs to (LocalModelsSettings.swift).
                if let download = try decoder.decode(JSONValue.self, from: line)["download"], let local = extras["local"] {
                    extras["local"] = local.replacingDownload(download)
                }
            default:
                guard let id = envelope.id, let continuation = pending.removeValue(forKey: id) else { return }
                if let error = envelope.error {
                    continuation.resume(throwing: EngineError(message: error, data: envelope.data))
                } else {
                    continuation.resume(returning: envelope.result ?? .null)
                }
            }
        } catch {
            lastError = "The engine sent something the app could not read (\(envelope.event ?? "reply"))."
        }
    }

    /// What the menu bar item counts beside its icon and what the Dock's badge shows: everything waiting in the `needs`
    /// event (docs/projects.md, 10.3, #481).
    public var waitingCount: Int { needs.count }

    /// Sets a property only when the value differs. A property of an observable object tells every view that reads it
    /// of each set, even to the same value, and the engine sends most of these again whenever anything in them changes.
    private func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<EngineSession, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    /// Drop the current connection, fail what waited for an answer, and let the host start an engine and connect again.
    private func retry() {
        transport?.cancel()
        transport = nil
        if status == .connected { status = .restarting }
        for continuation in pending.values { continuation.resume(throwing: EngineError(message: "The engine stopped before it answered.", unanswered: true)) }
        pending.removeAll()
        host?.sessionLost()
    }
}
