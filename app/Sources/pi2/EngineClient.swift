import AppKit
import Foundation
import LoginItemKit
import Network
import Observation

/// Talks to pi2-engine over its Unix socket, starts the engine when it is not running, and reconnects when it dies.
/// Everything shown in the app is the engine's committed state, mirrored here; the app keeps no truth of its own.
@MainActor
@Observable
final class EngineClient {
    enum Status: Equatable {
        case connecting
        case connected
        case restarting
    }

    private(set) var status: Status = .connecting
    private(set) var conversations: [ConversationSummary] = []
    /// The Archive, newest first.
    private(set) var archived: [ArchivedConversation] = []
    /// After how many unused days a conversation is archived on its own; nil for never.
    private(set) var autoArchiveDays: Int?
    /// The conversations the app has asked the engine for, which it keeps sending. The list changes only as one is opened
    /// or closed; each conversation's updates go to its own object, so they redraw only the views that show it.
    private(set) var open: [Int: OpenConversation] = [:]
    /// Only drafts with input survive closing a transcript. Keeping one here does not subscribe to the conversation.
    @ObservationIgnored private var parkedDrafts: [Int: ConversationDraft] = [:]
    /// Messages the person sent that the conversation does not show yet, by conversation, oldest first.
    private(set) var outgoing: [Int: [OutgoingMessage]] = [:]
    private(set) var providers: [ProviderInfo] = []
    /// Every model of every connected provider, including the ones hidden in Settings.
    private(set) var allModels: [ModelInfo] = []
    /// The models the pickers offer.
    var models: [ModelInfo] { allModels.filter { $0.hidden != true } }
    /// The models the pickers offer, by provider in name order. Two providers can offer a model with the same id,
    /// so a list that mixes providers identifies its rows by `ModelInfo.ref`, never by `id`.
    var modelGroups: [(provider: String, name: String, models: [ModelInfo])] {
        Dictionary(grouping: models, by: \.provider)
            .map { (provider: $0.key, name: $0.value[0].providerName, models: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private(set) var defaultModel: ModelRef?
    /// Whether the first-run welcome has been completed for this data folder. Nil until the engine has said.
    private(set) var onboarded: Bool?
    /// The templates: agents that belong to no project, which is every agent made the old way. They are what the agents'
    /// list, the New Conversation With menus and the palette offer, with the preview on or off; a project's own agents
    /// are left out of them (docs/projects.md, 10.2).
    private(set) var agents: [AgentProfile] = []
    /// Every agent, the projects' own included, for finding one by id: a conversation's agent can be a project's.
    private(set) var allAgents: [AgentProfile] = []
    /// The built-in tools an agent's settings list, sent with the agents. Empty from an engine older than the list.
    private(set) var builtInTools: [BuiltInTool] = []
    /// The picture models the person's providers can use, for making pictures (engine/src/pictures.ts), and the providers
    /// that have such models at all, by name, for saying where to get one when there is none. Nil until the engine says.
    private(set) var pictures: PictureModels?
    private(set) var inbox: [InboxItem] = [] {
        didSet {
            guard inbox != oldValue else { return }
            NSApp.dockTile.badgeLabel = inbox.isEmpty ? nil : String(inbox.count)
            let known = Set(oldValue.map(\.id))
            for item in inbox where !known.contains(item.id) { Notifier.shared.needsYou(item) }
        }
    }
    private(set) var hasLoadedLibrary = false
    private(set) var activity: [ActivityRun] = []
    /// How many runs `activity` lists, for the sidebar, which need not be drawn again for every change to a run.
    private(set) var runningCount = 0
    /// The runs waiting for a provider's limit, by conversation; and those of sub-chats, by the conversation they belong to.
    private(set) var limitWaits: [Int: LimitWait] = [:]
    private(set) var subChatLimitWaits: [Int: [LimitWait]] = [:]
    /// Conversations in the sidebar whose every run, their own and their sub-chats', waits for a limit.
    private(set) var heldByLimits: Set<Int> = []
    /// Commands agents left running in the background, oldest first.
    private(set) var backgroundCommands: [BackgroundCommand] = []
    /// What will wake an agent when it ends, and what has and waits for it (docs/wakes.md).
    private(set) var wakes: [WakeItem] = []
    private(set) var wakeHolds: [WakeHold] = []
    /// Models running on this Mac (`local.running`).
    private(set) var localRunning: [LocalServer] = []
    /// The conversations the window shows in its panes, as the engine was last told (`conversations.shown`).
    private var shown: Set<Int> = []
    private(set) var schedules: [Schedule] = []
    private(set) var recovery: RecoveryReport?
    private(set) var usage: UsageSummary?
    private(set) var mcpServers: [McpServer] = []
    /// The branch each conversation's folder is on, for conversations working in a git repository.
    private(set) var branches: [Int: BranchStatus] = [:]
    /// Worktrees of conversations that were archived or deleted, newest first.
    private(set) var leftBehind: [LeftBehindWorktree] = []
    /// Whether the projects preview is on, and the projects, as the `projects` event last said (docs/projects.md, 4.3).
    /// With the preview off the app shows none of them (10.2).
    private(set) var projectsPreview = false
    private(set) var projects: [ProjectRow] = []
    /// Asked to show a conversation, for example a fork that was just made.
    var onNavigate: (Int) -> Void = { _ in }
    /// Asked to show a conversation (a sub-chat) in a pane beside another (the conversation it came from).
    var onOpenBeside: (_ id: Int, _ beside: Int) -> Void = { id, _ in }
    var signIn: SignInFlow?
    var lastError: String?
    /// Set once several starts of the engine in a row have ended without an engine to connect to, and cleared as soon
    /// as one answers. The window says so instead of "Starting engine…" for ever.
    private(set) var startProblem: EngineStartProblem?
    /// The latest event of each kind that a feature in a file of its own reads ("limits", "memory"), as sent.
    let extras = ExtraEvents()
    /// Does what agents ask of other apps' windows; the app holds the macOS permissions for it.
    let computer = ComputerSession()
    /// Works pages in pi²'s own browser for agents; the app holds the web views.
    let browser = BrowserSession()
    /// Projects, the preview switch and what the sidebar shows of each (Projects.swift).
    let projectStore = ProjectsStore()

    let home: URL
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var lastLaunch = Date.distantPast
    /// Starts tried since the app last reached an engine. A start is only tried when no engine is running, so each one
    /// after the first means the one before it ended without an engine (or never began).
    private var startsWithoutConnecting = 0
    /// Why the app itself could not start the last engine, when it could not.
    private var launchFailure: String?
    /// How the last engine the app started ended before the app reached it, such as "exited with status 1".
    private var lastExit: String?
    /// Failed starts in a row before the window says the engine cannot be started. Each takes about three seconds, so a
    /// slow start is not mistaken for a failed one.
    private static let startsBeforeProblem = 3
    /// Keeps reconnects from starting the engine during a restore, update, or planned restart.
    private var holdEngine = false

    init() {
        // A development build's own data folder and Keychain service, unless the environment names others.
        let setAside = DevelopmentBuild.applyDefaults()
        if let override = ProcessInfo.processInfo.environment["PI2_HOME"] {
            home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("pi2", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let setAside { note(setAside) }
        PerfProbe.start(home: home)
    }

    // MARK: - Requests

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> JSONValue {
        guard let connection, status == .connected else { throw EngineError(message: "The engine is not running yet.", unanswered: true) }
        let id = nextRequestID
        nextRequestID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(0x0A)
        PerfProbe.sent(id, method)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Runs a request whose only interesting outcome is failure, and shows that failure in the window.
    func perform(_ method: String, _ params: [String: Any] = [:]) {
        Task {
            do { try await call(method, params) } catch { lastError = error.localizedDescription }
        }
    }

    func createConversation(agentId: String? = nil) async -> Int? {
        do {
            let result = try await call("conversation.create", agentId.map { ["agentId": $0] } ?? [:])
            guard let id = result["id"]?.intValue else { return nil }
            openConversation(id)
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func openConversation(_ id: Int) {
        PerfProbe.opening(id, "asked")
        lastWanted[id] = Date()
        guard open[id] == nil else { return }
        open[id] = OpenConversation(draft: parkedDrafts.removeValue(forKey: id) ?? ConversationDraft())
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
        PerfProbe.opening(id, "sent")
        Task {
            do {
                // A long conversation comes newest first, and the rest just after (#380); an older engine sends it whole.
                try await call("conversation.open", ["id": id, "newestFirst": true])
                PerfProbe.opening(id, "answered")
            } catch {
                if hasLoadedLibrary, !conversations.contains(where: { $0.id == id }), !archived.contains(where: { $0.id == id }) {
                    open[id] = nil
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
    func loadOlder(_ id: Int) {
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
    func setShown(_ ids: Set<Int>) {
        guard ids != shown else { return }
        // What was on screen until now was wanted until now.
        for id in shown.union(ids) { lastWanted[id] = Date() }
        shown = ids
        sendShown()
    }

    /// When each open conversation was last on screen or asked for.
    @ObservationIgnored private var lastWanted: [Int: Date] = [:]
    /// The conversation Quick Ask shows, which no pane may: it is kept open while the panel has it.
    @ObservationIgnored var quickAskConversation: Int?
    /// How long a conversation no longer on screen keeps coming from the engine, so that going back to it is instant.
    private static let keptOpen: TimeInterval = 120

    /// Closes the conversations nothing has shown for a while. Otherwise every conversation looked at since launch keeps
    /// coming from the engine, several times a second while it works, to be read and kept for nothing (#347).
    private func closeUnwanted() {
        guard status == .connected else { return }
        let now = Date()
        for id in open.keys where !shown.contains(id) && id != quickAskConversation && outgoing[id] == nil {
            guard now.timeIntervalSince(lastWanted[id] ?? .distantPast) > Self.keptOpen else { continue }
            if let draft = open[id]?.draft, draft.hasInput { parkedDrafts[id] = draft }
            open[id] = nil
            lastWanted[id] = nil
            Task { _ = try? await call("conversation.close", ["id": id]) }
        }
    }

    private func sendShown() {
        guard status == .connected else { return }
        let ids = shown.sorted()
        Task { _ = try? await call("conversations.shown", ["ids": ids]) }
    }

    enum SubmitOutcome { case sent, refused, unconfirmed }

    /// Sends a message and shows why if it is refused or could not be confirmed.
    /// `attachments` are pictures and files to go with it, as `ComposerAttachments.Draft.payload` makes them.
    ///
    /// Until the engine has it, and then until the conversation shows it, the message is in `outgoing`, which the
    /// message field shows. When no answer comes because the engine is not connected or the connection goes, the message
    /// is sent again once the engine is back, with the same request id, which makes the engine find the submission it
    /// may already have taken rather than take it twice. After a minute without an engine, acceptance is unknown.
    @discardableResult
    func submit(_ text: String, attachments: [[String: Any]] = [], to id: Int, steer: Bool) async -> SubmitOutcome {
        let requestId = UUID().uuidString
        var params: [String: Any] = ["id": id, "text": text, "mode": steer ? "steer" : "queue", "requestId": requestId]
        if !attachments.isEmpty { params["attachments"] = attachments }
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")" : text
        outgoing[id, default: []].append(OutgoingMessage(id: requestId, summary: summary))
        let asked = PerfProbe.now()
        let lastBefore = open[id]?.items.last?.id
        let deadline = ContinuousClock.now + .seconds(60)
        var unanswered = false
        while true {
            do {
                let result = try await call("submit", params)
                PerfProbe.note("submit to \(id) accepted in \(Int(((PerfProbe.now() - asked) * 1000).rounded()))ms")
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

    func configure(_ id: Int, _ change: [String: Any]) {
        var params = change
        params["id"] = id
        perform("conversation.configure", params)
    }

    /// Branch a conversation at one of its entries and show the new one.
    func fork(_ id: Int, at entryId: Int) {
        Task {
            do {
                let result = try await call("conversation.fork", ["id": id, "entryId": entryId])
                if let fork = result["id"]?.intValue {
                    openConversation(fork)
                    onNavigate(fork)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func search(_ query: String) async -> [SearchResult] {
        guard let result = try? await call("search", ["query": query]), let data = try? JSONEncoder().encode(result["results"] ?? .array([])) else { return [] }
        return (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
    }

    /// Conversations that are not sub-chats, newest first. Chats are chat mode's own (`chats`), so the agent view never
    /// lists them.
    var rootConversations: [ConversationSummary] { conversations.filter { $0.parent == nil && !$0.isChat } }

    /// The sub-chats an agent opened from a conversation, oldest first.
    func subChats(of id: Int) -> [ConversationSummary] {
        conversations.filter { $0.parent == id }.sorted { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }

    func agent(_ id: String?) -> AgentProfile? {
        allAgents.first { $0.id == id }
    }

    /// A folder as the person reads it: abbreviated with ~, or named when it is the folder conversations work in when
    /// none was chosen.
    func folderName(_ path: String) -> String {
        let scratch = home.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL.path
        if URL(fileURLWithPath: path).standardizedFileURL.path == scratch { return "pi²’s scratch folder" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Sign-in

    func startSignIn(_ provider: ProviderInfo) {
        signIn = SignInFlow(providerId: provider.id, providerName: provider.oauth?.name ?? provider.name)
        Task {
            do {
                try await call("providers.login", ["id": provider.id])
                signIn = nil
            } catch {
                if signIn != nil {
                    signIn?.error = error.localizedDescription
                    signIn?.finished = true
                }
            }
        }
    }

    func answerSignInPrompt(_ value: String) {
        guard let promptId = signIn?.promptId else { return }
        signIn?.promptId = nil
        signIn?.prompt = nil
        perform("auth.answer", ["promptId": promptId, "value": value])
    }

    func cancelSignIn() {
        if let loginId = signIn?.loginId, signIn?.finished == false { perform("auth.cancel", ["loginId": loginId]) }
        signIn = nil
    }

    // MARK: - Connection

    func start() {
        guard connection == nil else { return }
        connect()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeUnwanted() }
        }
    }

    private func connect() {
        let socketPath: String
        do {
            socketPath = try EngineSocket.path(for: home)
        } catch {
            // Nothing to connect to, and retrying would not change that.
            lastError = "Cannot reach the engine for the data folder \(home.path): \(error.localizedDescription)"
            return
        }
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.connection = connection
        buffer.removeAll()
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.status = .connected
                    self.startsWithoutConnecting = 0
                    self.launchFailure = nil
                    self.lastExit = nil
                    self.startProblem = nil
                    self.receive(on: connection)
                    // Offer this app as the one that sees and works other apps for agents.
                    Task { _ = try? await self.call("computer.register") }
                    // And as the one whose browser agents use.
                    Task { _ = try? await self.call("browser.register") }
                    // After an update either the running engine or its login item may still be out of date.
                    Task { await self.reconcileEngine(on: connection) }
                    Task { await self.noteEngineFromAnotherCheckout() }
                    Task { await self.noteIfAnswersRefused(on: connection) }
                    // The engine forgets subscriptions with the connection; ask again for what is on screen.
                    for id in self.open.keys { self.requestOpen(id) }
                    self.sendShown()
                case .waiting(let error), .failed(let error):
                    if self.status == .connected { self.note("connection failed: \(error)") }
                    self.retry()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === connection else { return }
                if let data { self.consume(data) }
                if isComplete || error != nil {
                    self.note("connection lost: \(error.map { "\($0)" } ?? "closed by the engine")")
                    self.status = .restarting
                    self.retry()
                } else {
                    self.receive(on: connection)
                }
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
    struct PictureModels: Decodable, Equatable {
        struct Model: Decodable, Equatable {
            struct Price: Decodable, Equatable {
                let input: Double
                let output: Double
            }
            let provider: String
            let id: String
            let name: String
            let providerName: String?
            let canEdit: Bool?
            let price: Price?
            var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
            var displayName: String { "\(providerName ?? provider) · \(name)" }
        }
        let model: ModelRef?
        let models: [Model]
        let makers: [String]
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
    private struct AuthEventMessage: Decodable {
        let loginId: String
        let kind: String
        let notice: AuthNotice?
        let promptId: String?
        let prompt: AuthPromptInfo?
    }

    private func handle(_ line: Data) {
        let started = PerfProbe.now()
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return }
        defer {
            let kind = envelope.event ?? envelope.id.flatMap { PerfProbe.answered($0) }.map { "reply \($0)" } ?? "reply"
            PerfProbe.event(kind, bytes: line.count, since: started)
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
                projectStore.take(conversations: event.conversations)
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
            case "inbox":
                update(\.inbox, try decoder.decode(InboxEvent.self, from: line).items)
            case "activity":
                update(\.activity, try decoder.decode(ActivityEvent.self, from: line).runs)
                update(\.runningCount, activity.count)
                projectStore.take(activity: activity)
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
                // A preview: one the app cannot read is noted in app.log and leaves the window as it was.
                guard let event = try? decoder.decode(ProjectsEvent.self, from: line) else {
                    note("The engine's projects event could not be read; projects are not shown.")
                    return
                }
                update(\.projectsPreview, event.preview)
                update(\.projects, event.projects)
                // What the sidebar and Settings read of it (Projects.swift): without the orchestrator's last words, which
                // change with every finished answer and would draw the list of projects again for nothing.
                if let sidebar = try? decoder.decode(SidebarProjectsEvent.self, from: line) { projectStore.take(projects: sidebar) }
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
                    PerfProbe.opening(event.id, "entries \(data.items.count) (\(line.count / 1024) KB, \(Int(((PerfProbe.now() - started) * 1000).rounded()))ms to read\(more))", rest: data.earlier > 0)
                }
            case "conversation.older":
                let event = try decoder.decode(OlderEvent.self, from: line)
                guard let data = open[event.id] else { return }
                data.prepend(event.items, earlier: event.earlier, more: event.more)
                if event.earlier == 0 { PerfProbe.opening(event.id, "all \(data.items.count) in") }
            case "needs":
                projectStore.take(needs: try decoder.decode(NeedsEvent.self, from: line).items)
            case "auth":
                handleAuth(try decoder.decode(AuthEventMessage.self, from: line))
            case "computer":
                computer.handle(try decoder.decode(ComputerEvent.self, from: line), engine: self)
            case "browser":
                browser.handle(try decoder.decode(BrowserEvent.self, from: line), engine: self)
            case "limits", "memory", "coauthor", "priority", "local", "chat", "compactionSettings":
                // Events that belong to a feature in a file of its own; it reads its latest one from `extras`.
                extras[envelope.event ?? ""] = try decoder.decode(JSONValue.self, from: line)
                if envelope.event == "limits" { Notifier.shared.limitNotices(PlanLimits(extras["limits"])?.notices ?? []) }
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

    /// Sets a property only when the value differs. A property of an observable object tells every view that reads it
    /// of each set, even to the same value, and the engine sends most of these again whenever anything in them changes.
    private func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<EngineClient, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func handleAuth(_ event: AuthEventMessage) {
        guard signIn != nil else { return }
        switch event.kind {
        case "started":
            signIn?.loginId = event.loginId
        case "notify":
            guard let notice = event.notice else { return }
            switch notice.type {
            case "auth_url":
                signIn?.openURL = notice.url
                if let instructions = notice.instructions { signIn?.messages.append(instructions) }
                if let url = notice.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            case "device_code":
                signIn?.userCode = notice.userCode
                signIn?.openURL = notice.verificationUri
            default:
                if let message = notice.message { signIn?.messages.append(message) }
            }
        case "prompt":
            signIn?.promptId = event.promptId
            signIn?.prompt = event.prompt
        case "promptClosed":
            if signIn?.promptId == event.promptId {
                signIn?.promptId = nil
                signIn?.prompt = nil
            }
        default:
            break
        }
    }

    /// A line in app.log next to the engine's log, for working out why a connection dropped, or why a window's size did
    /// not settle (`SizeWatch`).
    func note(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let url = home.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }

    /// Drop the current connection, make sure an engine is running, and try again shortly.
    private func retry() {
        connection?.cancel()
        connection = nil
        if status == .connected { status = .restarting }
        for continuation in pending.values { continuation.resume(throwing: EngineError(message: "The engine stopped before it answered.", unanswered: true)) }
        pending.removeAll()
        launchEngineIfNeeded()
        // While the engine cannot be started, keep looking for one (it may be started some other way) but calmly.
        let delay: Duration = startProblem == nil ? .milliseconds(250) : .seconds(2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    // MARK: - Engine process

    private var enginePID: pid_t? {
        guard let text = try? String(contentsOf: home.appendingPathComponent("engine.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    /// How long to wait between starts: three seconds at first, then twice as long after each failure past the few that
    /// show the problem, up to a minute, so an engine that cannot start is not started over and over.
    private var launchInterval: TimeInterval {
        let beyond = startsWithoutConnecting - Self.startsBeforeProblem
        return beyond > 0 ? min(60, 3 * pow(2, Double(beyond))) : 3
    }

    private func launchEngineIfNeeded() {
        guard !holdEngine, enginePID == nil, Date().timeIntervalSince(lastLaunch) > launchInterval else { return }
        // No engine is running, so every start tried since the last connection has ended without one.
        if startsWithoutConnecting >= Self.startsBeforeProblem { reportStartProblem() }
        lastLaunch = Date()
        startsWithoutConnecting += 1
        launchFailure = nil
        guard let (node, main) = Self.enginePaths else {
            launchFailure = "This build does not know where its engine is. Build it again with app/build.sh."
            return
        }
        // When the login item starts this engine, start it through launchd, so it is still restarted after a crash.
        if let item = EngineLoginItem.current, item.serves(home: home.path), item.arguments == [node, main],
           EngineLoginItem.start(home: home.path) {
            return
        }
        let logURL = home.appendingPathComponent("engine.log")
        // Append, so the output of an engine that crashed is still there after the restart.
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        defer { try? log?.close() }
        // Responsible for itself, so agents' commands do not have the app's Accessibility (EngineSpawn).
        if !EngineSpawn.canDisclaim { note("this macOS cannot start the engine as its own responsible process; it runs under the app's permissions") }
        do {
            try EngineSpawn.run(
                node,
                arguments: [main],
                environment: engineEnvironment,
                output: log
            ) { [weak self] ending in
                let text = switch ending {
                case .signal(let signal): "was stopped by signal \(signal)"
                case .exited(let status): "exited with status \(status)"
                }
                Task { @MainActor in
                    guard let self, self.status != .connected else { return }
                    self.lastExit = text
                }
            }
        } catch {
            launchFailure = "Node could not be run from \(node): \(error.localizedDescription)"
        }
    }

    /// Say that the engine cannot be started, with the end of its log as it is now.
    private func reportStartProblem() {
        startProblem = EngineStartProblem(
            attempts: startsWithoutConnecting,
            reason: launchFailure,
            lastExit: lastExit,
            logTail: Self.tail(of: home.appendingPathComponent("engine.log")),
            checkedAt: Date()
        )
    }

    /// Start the engine now rather than when the slowed-down retries come round, after the person changed something.
    func tryStartingAgain() {
        startsWithoutConnecting = min(startsWithoutConnecting, Self.startsBeforeProblem)
        lastLaunch = .distantPast
        launchEngineIfNeeded()
    }

    /// The last lines of a log, enough to hold a stack trace.
    private static func tail(of url: URL, lines: Int = 16) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var kept = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if size > 8192, !kept.isEmpty { kept.removeFirst() }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        return kept.suffix(lines).joined(separator: "\n")
    }

    /// Where Node and the engine's entry point are: inside the app for a self-contained build, otherwise the
    /// development paths the build recorded.
    static var enginePaths: (node: String, main: String)? {
        let fileManager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let node = resources.appendingPathComponent("node").path
            let main = resources.appendingPathComponent("engine/src/main.ts").path
            if fileManager.isExecutableFile(atPath: node), fileManager.fileExists(atPath: main) { return (node, main) }
        }
        let environment = ProcessInfo.processInfo.environment
        guard let node = Bundle.main.object(forInfoDictionaryKey: "PI2NodePath") as? String ?? environment["PI2_NODE"],
              let main = Bundle.main.object(forInfoDictionaryKey: "PI2EngineMain") as? String ?? environment["PI2_ENGINE_MAIN"]
        else { return nil }
        return (node, main)
    }

    /// Whether this build carries its own engine, and so can be moved or copied.
    static var isSelfContained: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: resources.appendingPathComponent("engine/src/main.ts").path)
    }

    var dataFolder: URL { home }

    /// Replace all data with a backup: stop the engine, swap the files, start it again. What was replaced is kept
    /// in a `before-restore-…` folder inside the data folder.
    func restoreBackup(from folder: URL) async throws {
        guard let (node, main) = Self.enginePaths else { throw EngineError(message: "This build does not know where its engine is.") }
        holdEngine = true
        defer {
            holdEngine = false
            lastLaunch = .distantPast
        }
        stopEngine()
        for _ in 0..<50 where enginePID != nil { try await Task.sleep(for: .milliseconds(100)) }
        if enginePID != nil { throw EngineError(message: "The engine did not stop, so nothing was changed.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [main, "--restore", folder.path]
        process.environment = engineEnvironment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError(message: message?.isEmpty == false ? message! : "The backup could not be restored.")
        }
        // The restored database can use the same IDs for different conversations.
        for conversation in open.values { conversation.draft.discard() }
        for draft in parkedDrafts.values { draft.discard() }
        parkedDrafts.removeAll()
        open = [:]
    }

    /// Simulates a crash: SIGKILL, no chance to clean up.
    func killEngine() {
        if let pid = enginePID { kill(pid, SIGKILL) }
    }

    /// A clean stop, used when the app quits unless the person chose to keep agents running.
    func stopEngine() {
        if let pid = enginePID { kill(pid, SIGTERM) }
    }

    // MARK: - Updates

    /// The build this app is, which build.sh also writes into the engine's `BUILD` file. Nil in a development build.
    static var buildID: String? { Bundle.main.object(forInfoDictionaryKey: "PI2BuildID") as? String }
    /// Whether the engine was already replaced in this run of the app, so a mismatch a restart cannot fix never loops.
    private var replacedEngine = false

    /// A failed refresh must not restart the engine on every reconnect.
    private var attemptedLoginItemRefresh = false

    /// The engine can outlive the app, but even an engine of this build may have been started by an outdated login
    /// item. Check both after connecting and share a single stop if both need changing. Runs pick up after the stop.
    private func reconcileEngine(on connection: NWConnection) async {
        guard Self.isSelfContained, self.connection === connection, !holdEngine,
              let (node, main) = Self.enginePaths else { return }
        var replaceEngine = false
        if !replacedEngine {
            // An engine from before this check does not know the method, which makes it just as much from another build.
            let info = try? await call("engine.info")
            guard self.connection === connection, !holdEngine else { return }
            if info == nil || info?["build"]?.stringValue != Self.buildID || info?["main"]?.stringValue != main {
                replaceEngine = true
                replacedEngine = true
                note("replacing an engine from build \(info?["build"]?.stringValue ?? "unknown") with \(Self.buildID ?? "unknown")")
            }
        }
        func loginItemNeedsRefresh() -> Bool {
            EngineLoginItem.needsRefresh(EngineLoginItem.current, node: node, main: main, home: home.path)
        }
        let refreshLoginItem = loginItemNeedsRefresh() && !attemptedLoginItemRefresh
        guard replaceEngine || refreshLoginItem else { return }
        if refreshLoginItem {
            attemptedLoginItemRefresh = true
            note("stopping the engine to refresh its login item (paths or ProcessType changed)")
        }
        holdEngine = true
        defer {
            holdEngine = false
            lastLaunch = .distantPast
        }
        stopEngine()
        for _ in 0..<150 where enginePID != nil { try? await Task.sleep(for: .milliseconds(100)) }
        // Preserve the hard stop fallback for an engine that has to be replaced, but don't force it for a plist change.
        if replaceEngine, let pid = enginePID {
            kill(pid, SIGKILL)
            for _ in 0..<20 where enginePID != nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // Settings may have turned the item off or reinstalled it while we waited for the engine to stop.
        guard refreshLoginItem, loginItemNeedsRefresh() else { return }
        guard enginePID == nil else {
            note("left the engine login item unchanged because the engine did not stop")
            return
        }
        do {
            try EngineLoginItem.install(node: node, main: main, home: home.path)
        } catch {
            note("could not update the engine login item: \(error.localizedDescription)")
            lastError = "Could not update the login item: \(error.localizedDescription)"
        }
    }

    /// A development build never replaces the engine it finds: pointed at another copy's data folder on purpose, it
    /// would stop that copy's engine. On its own data folder, the engine can still be one another development build
    /// with the same bundle id started from another checkout, which runs that checkout's code rather than this one's,
    /// so app.log says so.
    private func noteEngineFromAnotherCheckout() async {
        guard !Self.isSelfContained, let (_, main) = Self.enginePaths else { return }
        guard let info = try? await call("engine.info"), let theirs = info["main"]?.stringValue, theirs != main else { return }
        note("connected to an engine started from \(theirs), not this build's \(main); it is left running")
    }

    /// The engine takes answers to approvals and questions only from the app, which it tells by the code signature of
    /// the process at the other end of the connection (#504). Asked once a connection is made, so that if it does not
    /// take them from this app, app.log says why: the person could not answer anything until it did.
    private func noteIfAnswersRefused(on connection: NWConnection) async {
        // An engine from before #504 does not know the request, and takes answers from anyone.
        guard let reply = try? await call("connection.mayAnswer"), self.connection === connection,
              reply["mayAnswer"] == .bool(false) else { return }
        note("the engine will not take answers to approvals and questions from this app: \(reply["why"]?.stringValue ?? "it did not say why")")
    }

    /// What the engine is started with: the app's own environment, its data folder, and the bundle it belongs to, by
    /// which a development engine, running from the checkout, knows the app's connections from others (#504). A release
    /// engine, inside the bundle, ignores it; commands an agent runs never get either (engine/src/environment.ts).
    private var engineEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(["PI2_HOME": home.path, "PI2_APP_BUNDLE": Bundle.main.bundlePath]) { _, new in new }
    }

    /// Called just before an update replaces the app. Stops the engine cleanly, so it is not left running from files
    /// that are being swapped out, and keeps it stopped while this copy of the app quits. If agents should keep
    /// running without the app, the new engine is started a little later, once the new app is in place; if the new
    /// app opens first, it starts the engine itself and the late start finds it running and exits.
    func prepareForUpdate() {
        holdEngine = true
        stopEngine()
        let deadline = Date().addingTimeInterval(10)
        while enginePID != nil, Date() < deadline { usleep(100_000) }
        if let pid = enginePID { kill(pid, SIGKILL) }
        let loginItem = EngineLoginItem.current?.serves(home: home.path) == true
        guard loginItem || UserDefaults.standard.bool(forKey: BackgroundSettings.keepEngineKey),
              let (node, main) = Self.enginePaths else { return }
        // Responsible for itself, as the app would start the engine (EngineSpawn), and with no output of its own.
        _ = try? EngineSpawn.run(
            "/bin/sh",
            arguments: loginItem
                ? ["-c", "sleep 20; exec /bin/launchctl kickstart \"gui/$(id -u)/$0\"", EngineLoginItem.label]
                : ["-c", "sleep 20; exec \"$0\" \"$1\" >> \"$2\" 2>&1", node, main, home.appendingPathComponent("engine.log").path],
            environment: engineEnvironment
        )
    }
}
