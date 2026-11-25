import AppKit
import EngineKit
import Foundation
import LoginItemKit
import Observation
import PiModels

/// The Mac's side of the engine: it holds an EngineKit session, which talks to pi2-engine and keeps what it sends, and
/// does with it what only the Mac does: starts the engine when it is not running and connects again when it dies, signs
/// in to providers, does agents' work in other apps and in pi²'s browser, keeps the sidebar's projects, and notifies.
/// Everything shown in the app is the engine's committed state, mirrored in the session; the app keeps no truth of its own.
@MainActor
@Observable
final class EngineClient: EngineSessionHost {
    typealias Session = EngineSession<ConversationDraft>
    typealias Status = Session.Status
    typealias SubmitOutcome = Session.SubmitOutcome
    typealias PictureModels = Session.PictureModels
    typealias LookModels = Session.LookModels

    /// Requests and answers, and the engine's events read into the models the views read (docs/iphone.md section 8).
    let session = Session()

    // What the session keeps, as the views read it (EngineSession says what each is).
    var status: Status { session.status }
    var conversations: [ConversationSummary] { session.conversations }
    var archived: [ArchivedConversation] { session.archived }
    var autoArchiveDays: Int? { session.autoArchiveDays }
    var open: [Int: OpenConversation] { session.open }
    var outgoing: [Int: [OutgoingMessage]] { session.outgoing }
    var providers: [ProviderInfo] { session.providers }
    var allModels: [ModelInfo] { session.allModels }
    var models: [ModelInfo] { session.models }
    var modelGroups: [(provider: String, name: String, models: [ModelInfo])] { session.modelGroups }
    var defaultModel: ModelRef? { session.defaultModel }
    var onboarded: Bool? { session.onboarded }
    var agents: [AgentProfile] { session.agents }
    var allAgents: [AgentProfile] { session.allAgents }
    var builtInTools: [BuiltInTool] { session.builtInTools }
    var pictures: PictureModels? { session.pictures }
    var look: LookModels? { session.look }
    var inbox: [InboxItem] { session.inbox }
    var hasLoadedLibrary: Bool { session.hasLoadedLibrary }
    var activity: [ActivityRun] { session.activity }
    var runningCount: Int { session.runningCount }
    var limitWaits: [Int: LimitWait] { session.limitWaits }
    var subChatLimitWaits: [Int: [LimitWait]] { session.subChatLimitWaits }
    var heldByLimits: Set<Int> { session.heldByLimits }
    var backgroundCommands: [BackgroundCommand] { session.backgroundCommands }
    var wakes: [WakeItem] { session.wakes }
    var wakeHolds: [WakeHold] { session.wakeHolds }
    var localRunning: [LocalServer] { session.localRunning }
    var schedules: [Schedule] { session.schedules }
    var recovery: RecoveryReport? { session.recovery }
    var usage: UsageSummary? { session.usage }
    var mcpServers: [McpServer] { session.mcpServers }
    var branches: [Int: BranchStatus] { session.branches }
    var leftBehind: [LeftBehindWorktree] { session.leftBehind }
    var projects: [ProjectRow] { session.projects }
    var needs: [NeedItem] { session.needs }
    var projectRules: [String: [ProjectRule]] { session.projectRules }
    var ruleNeeds: [String: [NeedItem]] { session.ruleNeeds }
    var conversationNeeds: [TranscriptFeed.Need] { session.conversationNeeds }
    var rootConversations: [ConversationSummary] { session.rootConversations }
    var waitingCount: Int { session.waitingCount }
    var extras: ExtraEvents { session.extras }
    var onNavigate: (_ id: Int, _ from: Int?) -> Void {
        get { session.onNavigate }
        set { session.onNavigate = newValue }
    }
    var onOpenBeside: (_ id: Int, _ beside: Int) -> Void {
        get { session.onOpenBeside }
        set { session.onOpenBeside = newValue }
    }
    var lastError: String? {
        get { session.lastError }
        set { session.lastError = newValue }
    }
    var quickAskConversation: Int? {
        get { session.quickAskConversation }
        set { session.quickAskConversation = newValue }
    }

    // The session's requests, as the views make them.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> JSONValue { try await session.call(method, params) }
    func perform(_ method: String, _ params: [String: Any] = [:]) { session.perform(method, params) }
    func createConversation(agentId: String) async -> Int? { await session.createConversation(agentId: agentId) }
    func openConversation(_ id: Int, tail: Bool = false) { session.openConversation(id, tail: tail) }
    func loadOlder(_ id: Int) { session.loadOlder(id) }
    func setShown(_ ids: Set<Int>) { session.setShown(ids) }
    @discardableResult
    func submit(_ text: String, attachments: [[String: Any]] = [], to id: Int, steer: Bool) async -> SubmitOutcome {
        await session.submit(text, attachments: attachments, to: id, steer: steer)
    }
    func configure(_ id: Int, _ change: [String: Any]) { session.configure(id, change) }
    func fork(_ id: Int, at entryId: Int, then show: ((Int) -> Void)? = nil) { session.fork(id, at: entryId, then: show) }
    func search(_ query: String) async -> [SearchResult] { await session.search(query) }
    func agent(_ id: String?) -> AgentProfile? { session.agent(id) }

    var signIn: SignInFlow?
    /// Set once several starts of the engine in a row have ended without an engine to connect to, and cleared as soon
    /// as one answers. The window says so instead of "Starting engine…" for ever.
    private(set) var startProblem: EngineStartProblem?
    /// Does what agents ask of other apps' windows; the app holds the macOS permissions for it.
    let computer = ComputerSession()
    /// Works pages in pi²'s own browser for agents; the app holds the web views.
    let browser = BrowserSession()
    /// Projects, carrying over's state and what the sidebar shows of each (Projects.swift).
    let projectStore = ProjectsStore()
    /// Who follows which conversation's presentations as `conversation.presented` brings them (PresentedEngine.swift).
    @ObservationIgnored let presentedFollowers = PresentedFollowers()
    /// Draws agents' pages offscreen when the engine asks (PresentedDrawing.swift).
    @ObservationIgnored let presentedDrawing = PresentedDrawing()
    #if PI2_DEVELOPMENT
    /// Paired devices and remote access, for Settings › Devices, the menu bar item and the sidebar (DevicesSettings.swift):
    /// development builds alone until a real phone is paired (#712).
    let devices = DevicesStore()
    #endif

    let home: URL
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
        session.host = self
        session.probe = PerfProbe.self
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
        signIn = SignInFlow(providerName: provider.oauth?.name ?? provider.name)
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
        guard session.transport == nil else { return }
        connect()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.closeUnwanted() }
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
        session.connect(UnixSocketTransport(path: socketPath))
    }

    // MARK: - What the session leaves to the Mac

    func sessionConnected() {
        guard let connection = session.transport else { return }
        self.startsWithoutConnecting = 0
        self.launchFailure = nil
        self.lastExit = nil
        self.startProblem = nil
        // Offer this app as the one that sees and works other apps for agents.
        Task { _ = try? await self.call("computer.register") }
        // And as the one whose browser agents use.
        Task { _ = try? await self.call("browser.register") }
        // And as the one that draws the pages agents present (the engine never loads one).
        presentedDrawing.register(self)
        // After an update either the running engine or its login item may still be out of date.
        Task { await self.reconcileEngine(on: connection) }
        Task { await self.noteEngineFromAnotherCheckout() }
        Task { await self.noteIfAnswersRefused(on: connection) }
        #if PI2_DEVELOPMENT
        // The `devices` event comes only to a connection that asks for it, and only from the app's (docs/iphone.md 3.3).
        // A release build never asks (#712).
        Task { await self.devices.watch(self) }
        #endif
    }

    /// The session let the connection go: make sure an engine is running, and try again shortly.
    func sessionLost() {
        launchEngineIfNeeded()
        // While the engine cannot be started, keep looking for one (it may be started some other way) but calmly.
        let delay: Duration = startProblem == nil ? .milliseconds(250) : .seconds(2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.session.transport == nil else { return }
            self.connect()
        }
    }

    func handle(_ event: String, _ line: Data, decoder: JSONDecoder) throws {
        switch event {
        case "auth":
            handleAuth(try decoder.decode(AuthEventMessage.self, from: line))
        case "computer":
            computer.handle(try decoder.decode(ComputerEvent.self, from: line), engine: self)
        case "browser":
            browser.handle(try decoder.decode(BrowserEvent.self, from: line), engine: self)
        case "conversation.presented":
            presentedFollowers.take(line)
        case "present.draw":
            presentedDrawing.take(line, engine: self)
        #if PI2_DEVELOPMENT
        case "devices":
            devices.take(line: line, decoder: decoder, engine: self)
        #endif
        default:
            break
        }
    }

    func took(conversations: [ConversationSummary]) { projectStore.take(conversations: conversations) }
    func took(activity: [ActivityRun]) { projectStore.take(activity: activity) }
    func took(projects: SidebarProjectsEvent) { projectStore.take(projects: projects) }
    func took(needs: [NeedRef]) { projectStore.take(needs: needs) }

    func needsArrived(_ new: [NeedItem]) {
        for need in new { Notifier.shared.needsYou(need) }
        refreshWaitingBadge()
    }

    func limitsArrived() {
        Notifier.shared.limitNotices(PlanLimits(extras["limits"])?.notices ?? [])
    }

    private struct AuthEventMessage: Decodable {
        let loginId: String
        let kind: String
        let notice: AuthNotice?
        let promptId: String?
        let prompt: AuthPromptInfo?
    }

    /// The Dock's badge: what waits for the person, everything in the `needs` event (docs/projects.md, 10.3, #481).
    private func refreshWaitingBadge() {
        let count = needs.count
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
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
        session.forgetConversations()
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
    private func reconcileEngine(on connection: any EngineTransport) async {
        guard Self.isSelfContained, session.transport === connection, !holdEngine,
              let (node, main) = Self.enginePaths else { return }
        var replaceEngine = false
        if !replacedEngine {
            // An engine from before this check does not know the method, which makes it just as much from another build.
            let info = try? await call("engine.info")
            guard session.transport === connection, !holdEngine else { return }
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
    private func noteIfAnswersRefused(on connection: any EngineTransport) async {
        // An engine from before #504 does not know the request, and takes answers from anyone.
        guard let reply = try? await call("connection.mayAnswer"), session.transport === connection,
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
