import AppKit
import Foundation
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
    private(set) var open: [Int: ConversationData] = [:]
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
    private(set) var agents: [AgentProfile] = []
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
    private(set) var schedules: [Schedule] = []
    private(set) var recovery: RecoveryReport?
    private(set) var usage: UsageSummary?
    private(set) var mcpServers: [McpServer] = []
    /// The branch each conversation's folder is on, for conversations working in a git repository.
    private(set) var branches: [Int: BranchStatus] = [:]
    /// Worktrees of conversations that were archived or deleted, newest first.
    private(set) var leftBehind: [LeftBehindWorktree] = []
    /// Asked to show a conversation, for example a fork that was just made.
    var onNavigate: (Int) -> Void = { _ in }
    /// Asked to show a conversation (a sub-chat) in a pane beside another (the conversation it came from).
    var onOpenBeside: (_ id: Int, _ beside: Int) -> Void = { id, _ in }
    var signIn: SignInFlow?
    var lastError: String?
    /// The latest event of each kind that a feature in a file of its own reads ("limits", "memory"), as sent.
    private(set) var extras: [String: JSONValue] = [:]
    /// Does what agents ask of other apps' windows; the app holds the macOS permissions for it.
    let computer = ComputerSession()
    /// Works pages in pi²'s own browser for agents; the app holds the web views.
    let browser = BrowserSession()

    private let home: URL
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var lastLaunch = Date.distantPast
    /// Set while a backup is being restored, so the engine is not started underneath it.
    private var holdEngine = false

    init() {
        if let override = ProcessInfo.processInfo.environment["PI2_HOME"] {
            home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("pi2", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: - Requests

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> JSONValue {
        guard let connection, status == .connected else { throw EngineError(message: "The engine is not running yet.") }
        let id = nextRequestID
        nextRequestID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(0x0A)
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
        guard open[id] == nil else { return }
        open[id] = ConversationData()
        perform("conversation.open", ["id": id])
    }

    /// Sends a message. Returns false, after showing why, when the engine refused it.
    /// `attachments` are pictures and files to go with it, as `ComposerAttachments.Draft.payload` makes them.
    @discardableResult
    func submit(_ text: String, attachments: [[String: Any]] = [], to id: Int, steer: Bool) async -> Bool {
        do {
            // The request ID makes a resend after a lost reply harmless: the engine finds the same submission.
            var params: [String: Any] = ["id": id, "text": text, "mode": steer ? "steer" : "queue", "requestId": UUID().uuidString]
            if !attachments.isEmpty { params["attachments"] = attachments }
            try await call("submit", params)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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

    /// Conversations that are not sub-chats, newest first.
    var rootConversations: [ConversationSummary] { conversations.filter { $0.parent == nil } }

    /// The sub-chats an agent opened from a conversation, oldest first.
    func subChats(of id: Int) -> [ConversationSummary] {
        conversations.filter { $0.parent == id }.sorted { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }

    func agent(_ id: String?) -> AgentProfile? {
        agents.first { $0.id == id }
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
    }

    private func connect() {
        let socketPath = home.appendingPathComponent("engine.sock").path
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.connection = connection
        buffer.removeAll()
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.status = .connected
                    self.receive(on: connection)
                    // Offer this app as the one that sees and works other apps for agents.
                    Task { _ = try? await self.call("computer.register") }
                    // And as the one whose browser agents use.
                    Task { _ = try? await self.call("browser.register") }
                    // After an update the engine that answered may be the one from before.
                    Task { await self.replaceEngineFromAnotherBuild() }
                    // The engine forgets subscriptions with the connection; ask again for what is on screen.
                    for id in self.open.keys { self.perform("conversation.open", ["id": id]) }
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
        let result: JSONValue?
    }
    private struct LibraryEvent: Decodable {
        let conversations: [ConversationSummary]
        let archived: [ArchivedConversation]?
        let autoArchiveDays: Int?
    }
    private struct AgentsEvent: Decodable { let agents: [AgentProfile] }
    private struct BranchesEvent: Decodable {
        let conversations: [String: BranchStatus]
        let leftBehind: [LeftBehindWorktree]?
    }
    private struct InboxEvent: Decodable { let items: [InboxItem] }
    private struct ActivityEvent: Decodable { let runs: [ActivityRun] }
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
    }
    private struct AuthEventMessage: Decodable {
        let loginId: String
        let kind: String
        let notice: AuthNotice?
        let promptId: String?
        let prompt: AuthPromptInfo?
    }

    private func handle(_ line: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return }
        do {
            switch envelope.event {
            case "library":
                let event = try decoder.decode(LibraryEvent.self, from: line)
                conversations = event.conversations
                archived = event.archived ?? []
                autoArchiveDays = event.autoArchiveDays
                hasLoadedLibrary = true
            case "agents":
                agents = try decoder.decode(AgentsEvent.self, from: line).agents
            case "inbox":
                inbox = try decoder.decode(InboxEvent.self, from: line).items
            case "activity":
                activity = try decoder.decode(ActivityEvent.self, from: line).runs
            case "schedules":
                schedules = try decoder.decode(SchedulesEvent.self, from: line).schedules
            case "recovery":
                recovery = try decoder.decode(RecoveryEvent.self, from: line).recovery
            case "usage":
                usage = try decoder.decode(UsageSummary.self, from: line)
            case "mcp":
                mcpServers = try decoder.decode(McpEvent.self, from: line).servers
            case "branches":
                let event = try decoder.decode(BranchesEvent.self, from: line)
                branches = Dictionary(uniqueKeysWithValues: event.conversations.compactMap { key, value in Int(key).map { ($0, value) } })
                leftBehind = event.leftBehind ?? []
            case "providers":
                let event = try decoder.decode(ProvidersEvent.self, from: line)
                providers = event.providers
                allModels = event.models
                defaultModel = event.defaultModel
                onboarded = event.onboarded ?? true
            case "conversation":
                let event = try decoder.decode(ConversationEvent.self, from: line)
                guard var data = open[event.id] else { return }
                if event.reset { data.items = [] }
                data.items.append(contentsOf: event.items)
                data.state = event.state
                open[event.id] = data
            case "auth":
                handleAuth(try decoder.decode(AuthEventMessage.self, from: line))
            case "computer":
                computer.handle(try decoder.decode(ComputerEvent.self, from: line), engine: self)
            case "browser":
                browser.handle(try decoder.decode(BrowserEvent.self, from: line), engine: self)
            case "limits", "memory":
                // Events that belong to a feature in a file of its own; it reads its latest one from `extras`.
                extras[envelope.event ?? ""] = try decoder.decode(JSONValue.self, from: line)
            default:
                guard let id = envelope.id, let continuation = pending.removeValue(forKey: id) else { return }
                if let error = envelope.error {
                    continuation.resume(throwing: EngineError(message: error))
                } else {
                    continuation.resume(returning: envelope.result ?? .null)
                }
            }
        } catch {
            lastError = "The engine sent something the app could not read (\(envelope.event ?? "reply"))."
        }
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

    /// A line in app.log next to the engine's log, for working out why a connection dropped.
    private func note(_ message: String) {
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
        for continuation in pending.values { continuation.resume(throwing: EngineError(message: "The engine stopped before it answered.")) }
        pending.removeAll()
        launchEngineIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
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

    private func launchEngineIfNeeded() {
        guard !holdEngine, enginePID == nil, Date().timeIntervalSince(lastLaunch) > 3 else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let (node, main) = Self.enginePaths else {
            lastError = "The app does not know where the engine is. Build it with app/build.sh."
            return
        }
        lastLaunch = Date()
        // When the login item starts this engine, start it through launchd, so it is still restarted after a crash.
        if let item = EngineLoginItem.current, item.serves(home: home.path), item.arguments == [node, main],
           EngineLoginItem.start() {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [main]
        process.environment = environment.merging(["PI2_HOME": home.path]) { _, new in new }
        let logURL = home.appendingPathComponent("engine.log")
        // Append, so the output of an engine that crashed is still there after the restart.
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) {
            _ = try? log.seekToEnd()
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
        } catch {
            lastError = "Could not start the engine: \(error.localizedDescription)"
        }
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
            open = [:]
        }
        stopEngine()
        for _ in 0..<50 where enginePID != nil { try await Task.sleep(for: .milliseconds(100)) }
        if enginePID != nil { throw EngineError(message: "The engine did not stop, so nothing was changed.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [main, "--restore", folder.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["PI2_HOME": home.path]) { _, new in new }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError(message: message?.isEmpty == false ? message! : "The backup could not be restored.")
        }
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

    /// The engine outlives the app when agents are kept running or it starts at login, so after an update (or after
    /// the app was moved) the engine that answers may be the one from before. Ask which build it is; if it is not this
    /// app's, stop it cleanly and start this app's. Runs pick up where they stopped.
    private func replaceEngineFromAnotherBuild() async {
        guard Self.isSelfContained, !replacedEngine, let (node, main) = Self.enginePaths else { return }
        // An engine from before this check does not know the method, which makes it just as much from another build.
        let info = try? await call("engine.info")
        if let info, info["build"]?.stringValue == Self.buildID, info["main"]?.stringValue == main { return }
        replacedEngine = true
        note("replacing an engine from build \(info?["build"]?.stringValue ?? "unknown") with \(Self.buildID ?? "unknown")")
        holdEngine = true
        defer {
            holdEngine = false
            lastLaunch = .distantPast
        }
        stopEngine()
        // A clean stop waits for the engine to close its storage. Past that, a hard stop is safe: reopening recovers.
        for _ in 0..<150 where enginePID != nil { try? await Task.sleep(for: .milliseconds(100)) }
        if let pid = enginePID {
            kill(pid, SIGKILL)
            for _ in 0..<20 where enginePID != nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // A login item for this data folder may still name the old copy of the app; point it at this one.
        if let item = EngineLoginItem.current, item.serves(home: home.path), item.arguments != [node, main] {
            EngineLoginItem.remove()
            do {
                try EngineLoginItem.install(node: node, main: main, home: home.path)
            } catch {
                lastError = "Could not update the login item: \(error.localizedDescription)"
            }
        }
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
        let later = Process()
        later.executableURL = URL(fileURLWithPath: "/bin/sh")
        later.arguments = loginItem
            ? ["-c", "sleep 20; exec /bin/launchctl kickstart \"gui/$(id -u)/$0\"", EngineLoginItem.label]
            : ["-c", "sleep 20; exec \"$0\" \"$1\" >> \"$2\" 2>&1", node, main, home.appendingPathComponent("engine.log").path]
        later.environment = ProcessInfo.processInfo.environment.merging(["PI2_HOME": home.path]) { _, new in new }
        later.standardInput = FileHandle.nullDevice
        later.standardOutput = FileHandle.nullDevice
        later.standardError = FileHandle.nullDevice
        try? later.run()
    }
}
