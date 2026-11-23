import EngineKit
import Foundation
import PiModels

/// What the client keeps of the engine's lines: the recording is played to the client itself, an `EngineSession` from
/// EngineKit, through a transport that gives it the lines as its connection would, and after each line what the session
/// keeps is written out under the names it keeps it by, with what it works out (the runs waiting for a limit, the proposed
/// rules by project, the cards a conversation's page shows) and what it hands to the app that holds it (the sidebar's
/// projects, the needs it notifies). Each open conversation is the session's `OpenConversation`, and its page is fed
/// through a `TranscriptFeed` as the conversation's web view feeds it. Only what changed is written, as the session sets
/// only what changed, so that the text says what every view reading the client would have read.
///
/// What the client keeps in types that are still the app's alone, or only hands to the app (the pictures' and looking's
/// models, `LocalServer`, the computer's, the browser's and sign-in's events), is written as the JSON it is, as the client
/// keeps the events of a feature in a file of its own (`ExtraEvents`); and an answer to a request the client did not make,
/// which it lets go, is written as the engine sent it.
@MainActor
final class Replay: EngineSessionHost {
    private(set) var lines: [String] = []
    /// Lines that could not be read into the models the client reads them into.
    private(set) var unread: [String] = []
    private(set) var counts: [String: Int] = [:]

    /// The client, reading the recording.
    private let session = EngineSession<NoDraft>()
    private let transport = Recording()

    // What the client keeps, as last written, by the names it keeps them by.
    private var conversations: [ConversationSummary] = []
    private var archived: [ArchivedConversation] = []
    private var autoArchiveDays: Int?
    private var hasLoadedLibrary = false
    private var allAgents: [AgentProfile] = []
    private var agents: [AgentProfile] = []
    private var builtInTools: [BuiltInTool] = []
    private var inbox: [InboxItem] = []
    private var activity: [ActivityRun] = []
    private var runningCount = 0
    private var limitWaits: [Int: LimitWait] = [:]
    private var subChatLimitWaits: [Int: [LimitWait]] = [:]
    private var heldByLimits: Set<Int> = []
    private var backgroundCommands: [BackgroundCommand] = []
    private var wakes: [WakeItem] = []
    private var wakeHolds: [WakeHold] = []
    private var schedules: [Schedule] = []
    private var recovery: RecoveryReport?
    private var usage: UsageSummary?
    private var mcpServers: [McpServer] = []
    private var branches: [Int: BranchStatus] = [:]
    private var leftBehind: [LeftBehindWorktree] = []
    private var projects: [ProjectRow] = []
    private var sidebarProjects: [ProjectInfo] = []
    private var carryOver: CarryOverState?
    private var needRefs: [NeedRef] = []
    private var needs: [NeedItem] = []
    private var ruleNeeds: [String: [NeedItem]] = [:]
    private var conversationNeeds: [TranscriptFeed.Need] = []
    private var projectRules: [String: [ProjectRule]] = [:]
    private var providers: [ProviderInfo] = []
    private var allModels: [ModelInfo] = []
    private var defaultModel: ModelRef?
    private var onboarded: Bool?
    private var appKept: [String: JSONValue] = [:]

    /// An open conversation's state as last written, and the page it feeds.
    private final class Page {
        var state: ConversationState?
        var feed = TranscriptFeed()
    }
    private var pages: [Int: Page] = [:]

    // What the session handed to its host while it read the current line.
    private var tookProjects: SidebarProjectsEvent?
    private var tookNeeds: [NeedRef]?
    private var arrived: [NeedItem]?
    private var notes: [String] = []

    init() {
        session.host = self
        // Never ready: the session asks the recording nothing, and is told only what was recorded.
        session.connect(transport)
    }

    func note(_ message: String) { notes.append(message) }
    func took(projects: SidebarProjectsEvent) { tookProjects = projects }
    func took(needs: [NeedRef]) { tookNeeds = needs }
    func needsArrived(_ new: [NeedItem]) { arrived = new }

    // What the check reads of a line itself, to say what it is: the client reads it all again.
    private struct Envelope: Decodable {
        let event: String?
        let id: Int?
        let error: String?
        let data: [String: JSONValue]?
        let result: JSONValue?
        let reset: Bool?
    }

    /// The events the client keeps in `extras` for a feature in a file of its own.
    private static let extraKinds: Set<String> = ["limits", "memory", "coauthor", "priority", "local", "chat", "compactionSettings", "work", "github", "reports", "awake", "agentDefault"]
    /// The events the client reads into types that are still the app's, or hands to the app.
    private static let appKinds: Set<String> = ["pictures", "look", "local.running", "auth", "computer", "browser"]

    private func write(_ line: String) { lines.append(line) }

    /// Each list's elements as last written, by its name.
    private var written: [String: Set<String>] = [:]

    /// Writes `name` and the client's value when it differs from what was written last, and keeps it. Of a list, the
    /// elements that are new or changed since it was last written: every one is written once at least.
    private func update<Value: Equatable>(_ name: String, _ kept: inout Value, _ value: Value) {
        if kept == value {
            write("  \(name) unchanged")
            return
        }
        kept = value
        guard let list = value as? [Any] else {
            write("  \(name) = \(Dump.text(value))")
            return
        }
        let texts = list.map(Dump.text)
        let before = written[name] ?? []
        write("  \(name) = \(texts.count) elements")
        for (index, text) in texts.enumerated() where !before.contains(text) { write("    [\(index)] \(text)") }
        written[name] = Set(texts)
    }

    /// Plays one line the engine sent to the client, and writes what the client keeps of it. Every conversation the
    /// library lists is opened, as the recording asked the engine for each one it saw.
    func take(_ text: String, number: Int) {
        let line = Data(text.utf8)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            write("\(number) not an engine line")
            unread.append("line \(number)")
            return
        }
        let kind = envelope.event ?? "reply"
        counts[kind, default: 0] += 1
        write("\(number) \(kind)")

        // What is needed of the client before the line, to say what the line changed.
        let conversation = kind == "conversation" || kind == "conversation.older" ? envelope.id.flatMap { session.open[$0] } : nil
        let itemsBefore = conversation?.items.count ?? 0
        let generationBefore = session.extras.generation(kind)
        tookProjects = nil
        tookNeeds = nil
        arrived = nil
        notes = []
        session.lastError = nil

        transport.play(text)

        if session.lastError != nil {
            write("  could not be read")
            unread.append("line \(number) (\(kind))")
            return
        }
        switch envelope.event {
        case "library":
            update("conversations", &conversations, session.conversations)
            update("archived", &archived, session.archived)
            update("autoArchiveDays", &autoArchiveDays, session.autoArchiveDays)
            update("hasLoadedLibrary", &hasLoadedLibrary, session.hasLoadedLibrary)
            for row in session.conversations where pages[row.id] == nil {
                session.openConversation(row.id)
                pages[row.id] = Page()
            }
        case "agents":
            update("allAgents", &allAgents, session.allAgents)
            update("agents", &agents, session.agents)
            update("builtInTools", &builtInTools, session.builtInTools)
        case "inbox":
            update("inbox", &inbox, session.inbox)
        case "activity":
            update("activity", &activity, session.activity)
            update("runningCount", &runningCount, session.runningCount)
            update("limitWaits", &limitWaits, session.limitWaits)
            update("subChatLimitWaits", &subChatLimitWaits, session.subChatLimitWaits)
            update("heldByLimits", &heldByLimits, session.heldByLimits)
        case "background":
            update("backgroundCommands", &backgroundCommands, session.backgroundCommands)
        case "wakes":
            update("wakes", &wakes, session.wakes)
            update("wakeHolds", &wakeHolds, session.wakeHolds)
        case "schedules":
            update("schedules", &schedules, session.schedules)
        case "recovery":
            update("recovery", &recovery, session.recovery)
        case "usage":
            update("usage", &usage, session.usage)
        case "mcp":
            update("mcpServers", &mcpServers, session.mcpServers)
        case "branches":
            update("branches", &branches, session.branches)
            update("leftBehind", &leftBehind, session.leftBehind)
        case "projects":
            guard notes.isEmpty else {
                write("  projects could not be read")
                unread.append("line \(number) (projects)")
                return
            }
            update("projects", &projects, session.projects)
            if let sidebar = tookProjects {
                update("sidebar projects", &sidebarProjects, sidebar.projects)
                update("carryOver", &carryOver, sidebar.carryOver)
            }
        case "providers":
            update("providers", &providers, session.providers)
            update("allModels", &allModels, session.allModels)
            update("defaultModel", &defaultModel, session.defaultModel)
            update("onboarded", &onboarded, session.onboarded)
        case "conversation":
            guard let id = envelope.id, let data = conversation, let page = pages[id] else {
                write("  conversation \(envelope.id ?? 0) is not open")
                return
            }
            let reset = envelope.reset ?? false
            let new = reset ? data.items.count : data.items.count - itemsBefore
            write("  conversation \(id)\(reset ? " from the start" : ""): \(new) new, \(data.items.count) in all, \(data.earlier) earlier, more \(data.more)")
            for item in data.items.suffix(new) { write("    item \(Dump.text(item))") }
            update("    state", &page.state, data.state)
            feed(id, data, page)
        case "conversation.older":
            guard let id = envelope.id, let data = conversation, let page = pages[id] else {
                write("  conversation \(envelope.id ?? 0) is not open")
                return
            }
            let older = data.items.count - itemsBefore
            write("  conversation \(id): \(older) older, \(data.items.count) in all, \(data.earlier) earlier, more \(data.more)")
            for item in data.items.prefix(older) { write("    item \(Dump.text(item))") }
            feed(id, data, page)
        case "needs":
            update("needRefs", &needRefs, tookNeeds ?? [])
            update("ruleNeeds", &ruleNeeds, session.ruleNeeds)
            update("needs", &needs, session.needs)
            write("  notified \(Dump.text((arrived ?? []).map(\.id)))")
            update("conversationNeeds", &conversationNeeds, session.conversationNeeds)
        case "projectRules":
            update("projectRules", &projectRules, session.projectRules)
        case let kind? where Self.extraKinds.contains(kind):
            write("  extras[\(kind)] \(session.extras.generation(kind) == generationBefore ? "unchanged" : "= \(Dump.text(session.extras[kind] as Any))")")
        case let kind? where Self.appKinds.contains(kind):
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: line) else {
                write("  could not be read")
                unread.append("line \(number) (\(kind))")
                return
            }
            var kept = appKept[kind]
            update("\(kind) (the app's own types)", &kept, json)
            appKept[kind] = kept
        case let kind?:
            write("  \(kind) is not read by the client")
        case nil:
            if let error = envelope.error {
                let refused = EngineError(message: error, data: envelope.data)
                write("  error \(Dump.text(refused.errorDescription as Any)) data \(Dump.text(refused.data as Any))")
            } else {
                write("  result \(Dump.text(envelope.result ?? .null))")
            }
        }
    }

    /// What the conversation's page is sent next, as its web view works it out from what the client holds.
    private func feed(_ id: Int, _ data: OpenConversation<NoDraft>, _ page: Page) {
        let state = data.state
        var mcp: [String: String] = [:]
        for server in session.mcpServers {
            for tool in server.tools { mcp[tool.toolName] = "\(server.name): \(tool.name)" }
        }
        // The colour is the app's (AgentColor); the model's short name is worked out as the app does, from the models.
        let agents = session.allAgents.map { TranscriptFeed.Agent(id: $0.id, name: $0.name, color: $0.color, model: shortModelName($0.model)) }
        var apps: [String: String] = [:]
        for app in TranscriptFeed.appsNamed(in: data.items, partial: state?.partial, inbox: session.inbox) { apps[app] = app }
        let names = TranscriptFeed.Names(
            conversationId: id, agentName: session.agent(state?.agent.agentId)?.name ?? "",
            mcp: mcp, agents: agents, apps: apps, folder: state?.agent.cwd?.hasPrefix("/") == true
        )
        var chat = TranscriptFeed.Chat.none
        if TranscriptFeed.Chat.shown(for: state) {
            let models = session.modelGroups.flatMap { group in
                group.models.map { TranscriptFeed.ModelChoice(provider: $0.provider, id: $0.id, name: $0.listName, group: group.name) }
            }
            let model = state?.agent.model.map { "\($0.provider)/\($0.modelId)" } ?? ""
            chat = TranscriptFeed.Chat(enabled: true, versions: state?.versions ?? [], models: models, model: model)
        }
        let message = page.feed.update(
            items: data.items, earlier: data.earlier, older: TranscriptFeed.Older(more: data.more, loading: false), state: state,
            inbox: session.inbox.filter { $0.conversationId == id }, changes: state?.projectChanges ?? [],
            needs: session.conversationNeeds.filter { $0.conversationId == id }, names: names, palette: [:], chat: chat
        )
        write("    page \(message.flatMap(TranscriptFeed.json) ?? "nothing new"), \(page.feed.pending) to send")
    }

    /// The model's short name as the app works it out (`EngineClient.shortModelName`, Pi2App.swift).
    private func shortModelName(_ ref: ModelRef?) -> String {
        guard let ref = ref ?? session.defaultModel else { return "" }
        let name = session.allModels.first { $0.ref == ref }?.name ?? ref.modelId
        for prefix in ["Claude ", "Demo model "] where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? name : rest.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return name
    }

    /// What the models work out by themselves, from no event: the formats every view writes numbers in, and the levels
    /// of access.
    func writeFormats() {
        write("formats")
        for cost in [0, 0.004, 0.01, 1.5, 1234.567] { write("  cost \(cost) \(Dump.quoted(Formats.cost(cost)))") }
        for tokens in [0, 999, 1_000, 12_345, 999_999, 2_500_000] { write("  tokens \(tokens) \(Dump.quoted(Formats.tokens(tokens)))") }
        write("  usage \(Dump.quoted(Formats.usage(tokens: 12_345, cost: 0))) \(Dump.quoted(Formats.usage(tokens: 12_345, cost: 0.42)))")
        for seconds in [0.0, 45, 192, 3840] { write("  short \(seconds) \(Dump.quoted(RunningCommand.short(seconds)))") }
        write("  access \(Dump.text(AccessLevel.all))")
    }

    /// The conversations as the client holds them once every line is in.
    func writeOpen() {
        write("open conversations")
        for (id, data) in session.open.sorted(by: { $0.key < $1.key }) {
            write("  \(id): \(data.items.count) items, ids \(Dump.text(data.items.map(\.id))), earlier \(data.earlier), more \(data.more), arrived \(data.state != nil)")
        }
    }

    /// What the work and github readings read (#828): the recording's last `work` event through `ProjectWork`, and one
    /// `github` event through `GitHubWork`. The recording's own `github` event is empty — its projects keep their work in
    /// pi² — so the event here is the phone's test fixture, which holds issues, pull requests with findings and failing
    /// checks, and a write whose outcome is unknown (`iphone/Tests/WorkTests.swift`,
    /// "aRepositorysIssuesAndPullsReadAsTheMacs", with its interpolated dates filled in).
    func writeWorkReadings() {
        write("work and github readings")
        for project in session.projects {
            let work = ProjectWork(session.extras["work"]?["projects"]?[project.id])
            write("  work \(project.id) \(Dump.text(work))")
        }
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(Self.githubEvent.utf8)) else {
            unread.append("the sample github event")
            return
        }
        write("  github \(Dump.text(GitHubWork(event["projects"]?["p-1"])))")
    }

    /// A `github` event as the engine sends one for a project with a repository attached, taken from the phone's test
    /// fixture: the recording's own holds no project, so this is what the `github` reading is decoded against.
    private static let githubEvent = """
        {"projects": {"p-1": {"state": "ok", "readAt": 1795359420000, "reading": true, "error": null,
          "issues": [
            {"id": 7, "title": "Open one", "text": "", "state": "open", "class": "local", "takenBy": null, "notes": [], "updatedAt": 1795359540000},
            {"id": 8, "title": "Newer open one", "text": "", "state": "open", "takenBy": null, "notes": [], "updatedAt": 1795359599000},
            {"id": 9, "title": "Held", "state": "in_progress", "takenBy": {"agentId": "forge", "conversationId": 21}, "notes": [], "updatedAt": 1795359600000},
            {"id": 3, "title": "Closed", "state": "done", "takenBy": null, "notes": [], "result": "Shipped.", "updatedAt": 1795359600000, "partial": true}],
          "pulls": [
            {"number": 12, "title": "Ready", "state": "open", "draft": false, "checks": "passing", "failingChecks": [], "mergeable": "yes",
             "findings": [{"agentName": "Scout", "verdict": "changes", "at": 1795359591000, "url": "", "text": ""},
                          {"agentName": "Reviewer", "verdict": "approve", "at": 1795359599000, "url": "", "text": ""}], "work": 7},
            {"number": 14, "title": "Failing", "state": "open", "draft": false, "checks": "failing",
             "failingChecks": [{"name": "engine", "url": ""}, {"name": "app", "url": ""}], "mergeable": "yes", "findings": []},
            {"number": 10, "title": "Merged", "state": "merged", "draft": false, "checks": "passing", "failingChecks": [], "mergeable": "unknown", "findings": []}],
          "unknown": [{"intent": "merge:12", "summary": "merging pull request #12", "at": 1795359000000}]}}}
        """
}

/// The recording, given to the session as its connection gives it the engine's lines. It is never ready, so the
/// session sends nothing on it.
@MainActor
final class Recording: EngineTransport {
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) { self.handler = handler }
    func send(_ data: Data) {}
    func cancel() { handler = nil }

    /// One line the engine sent, as it came: with its line break.
    func play(_ line: String) { handler?(.received(Data((line + "\n").utf8))) }
}

/// No message field: the check has none.
final class NoDraft: MessageDraft {
    var hasInput: Bool { false }
    func discard() {}
}
