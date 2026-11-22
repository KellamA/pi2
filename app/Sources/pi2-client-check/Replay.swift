import Foundation
import PiModels

/// What the app's client keeps of the engine's lines, read as `EngineClient.handle` reads them: each event decoded into
/// the models it decodes it into, and kept under the name the client keeps it by, with what the client works out of it
/// (the runs waiting for a limit, the proposed rules by project, the cards a conversation's page shows). Each open
/// conversation is kept as `OpenConversation` keeps it, and its page is fed through a `TranscriptFeed` as the
/// conversation's web view feeds it. After each line it writes what changed, as `EngineClient.update` sets only what
/// changed, so that the text says what every view reading the client would have read.
///
/// Until the client itself is in a package (`EngineKit`, docs/iphone.md section 8), the reading of each event is copied
/// here from `EngineClient.handle`, with the event wrappers it declares privately. What the client keeps in types that are
/// still the app's (`EngineClient.PictureModels`, `LocalServer`, the computer's, the browser's and sign-in's events) is
/// kept as the JSON it is, as the client keeps the events of a feature in a file of its own (`ExtraEvents`).
@MainActor
final class Replay {
    private(set) var lines: [String] = []
    /// Lines that could not be read into the models the client reads them into.
    private(set) var unread: [String] = []
    private(set) var counts: [String: Int] = [:]

    // What the client keeps, by the names EngineClient keeps them by.
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
    private let extras = ExtraEvents()

    /// An open conversation, as `OpenConversation` keeps it, and the page it feeds.
    private final class Open {
        var items: [Item] = []
        var state: ConversationState?
        var earlier = 0
        var more = false
        var feed = TranscriptFeed()
    }
    private var open: [Int: Open] = [:]

    // The event wrappers EngineClient declares privately, as it declares them.
    private struct Envelope: Decodable {
        let event: String?
        let id: Int?
        let error: String?
        let data: [String: JSONValue]?
        let result: JSONValue?
    }
    private struct LibraryEvent: Decodable {
        let conversations: [ConversationSummary]
        let archived: [ArchivedConversation]?
        let autoArchiveDays: Int?
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
        let earlier: Int?
        let more: Bool?
    }
    private struct OlderEvent: Decodable {
        let id: Int
        let items: [Item]
        let earlier: Int
        let more: Bool?
    }

    /// The events the client keeps in `extras` for a feature in a file of its own.
    private static let extraKinds: Set<String> = ["limits", "memory", "coauthor", "priority", "local", "chat", "compactionSettings", "work", "github", "reports", "awake", "agentDefault"]
    /// The events the client reads into types that are still the app's.
    private static let appKinds: Set<String> = ["pictures", "look", "local.running", "auth", "computer", "browser"]

    private func write(_ line: String) { lines.append(line) }

    /// Each list's elements as last written, by its name.
    private var written: [String: Set<String>] = [:]

    /// Writes `name` and its value when it differs from what was kept, as `EngineClient.update` sets it, and keeps it.
    /// Of a list, the elements that are new or changed since it was last written: every one is written once at least.
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

    /// Takes in one line the engine sent, and writes what the client keeps of it. Every conversation the library lists is
    /// open, as the recording asked the engine for each one it saw.
    func take(_ text: String, number: Int) {
        let line = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            write("\(number) not an engine line")
            unread.append("line \(number)")
            return
        }
        let kind = envelope.event ?? "reply"
        counts[kind, default: 0] += 1
        write("\(number) \(kind)")
        do {
            switch envelope.event {
            case "library":
                let event = try decoder.decode(LibraryEvent.self, from: line)
                update("conversations", &conversations, event.conversations)
                update("archived", &archived, event.archived ?? [])
                update("autoArchiveDays", &autoArchiveDays, event.autoArchiveDays)
                update("hasLoadedLibrary", &hasLoadedLibrary, true)
                for row in event.conversations where open[row.id] == nil { open[row.id] = Open() }
            case "agents":
                let event = try decoder.decode(AgentsEvent.self, from: line)
                update("allAgents", &allAgents, event.agents)
                update("agents", &agents, event.agents.filter { $0.projectId == nil })
                update("builtInTools", &builtInTools, event.builtInTools ?? [])
            case "inbox":
                update("inbox", &inbox, try decoder.decode(InboxEvent.self, from: line).items)
            case "activity":
                update("activity", &activity, try decoder.decode(ActivityEvent.self, from: line).runs)
                update("runningCount", &runningCount, activity.count)
                let waits = Dictionary(activity.compactMap { run in run.limit.map { (run.conversationId, $0) } }, uniquingKeysWith: { first, _ in first })
                update("limitWaits", &limitWaits, waits)
                let bySubChats = Dictionary(grouping: activity.filter { $0.limit != nil && $0.parent != nil }, by: { $0.parent! }).mapValues { $0.compactMap(\.limit) }
                update("subChatLimitWaits", &subChatLimitWaits, bySubChats)
                let held = Set(Dictionary(grouping: activity, by: \.rootConversationId).filter { $0.value.allSatisfy { $0.limit != nil } }.keys)
                update("heldByLimits", &heldByLimits, held)
            case "background":
                update("backgroundCommands", &backgroundCommands, try decoder.decode(BackgroundEvent.self, from: line).commands)
            case "wakes":
                let event = try decoder.decode(WakesEvent.self, from: line)
                update("wakes", &wakes, event.items)
                update("wakeHolds", &wakeHolds, event.held)
            case "schedules":
                update("schedules", &schedules, try decoder.decode(SchedulesEvent.self, from: line).schedules)
            case "recovery":
                update("recovery", &recovery, try decoder.decode(RecoveryEvent.self, from: line).recovery)
            case "usage":
                update("usage", &usage, try decoder.decode(UsageSummary.self, from: line))
            case "mcp":
                update("mcpServers", &mcpServers, try decoder.decode(McpEvent.self, from: line).servers)
            case "branches":
                let event = try decoder.decode(BranchesEvent.self, from: line)
                update("branches", &branches, Dictionary(uniqueKeysWithValues: event.conversations.compactMap { key, value in Int(key).map { ($0, value) } }))
                update("leftBehind", &leftBehind, event.leftBehind ?? [])
            case "projects":
                guard let event = try? decoder.decode(ProjectsEvent.self, from: line) else {
                    write("  projects could not be read")
                    unread.append("line \(number) (projects)")
                    return
                }
                update("projects", &projects, event.projects)
                if let sidebar = try? decoder.decode(SidebarProjectsEvent.self, from: line) {
                    update("sidebar projects", &sidebarProjects, sidebar.projects)
                    update("carryOver", &carryOver, sidebar.carryOver)
                }
            case "providers":
                let event = try decoder.decode(ProvidersEvent.self, from: line)
                update("providers", &providers, event.providers)
                update("allModels", &allModels, event.models)
                update("defaultModel", &defaultModel, event.defaultModel)
                update("onboarded", &onboarded, event.onboarded ?? true)
            case "conversation":
                let event = try decoder.decode(ConversationEvent.self, from: line)
                guard let data = open[event.id] else {
                    write("  conversation \(event.id) is not open")
                    return
                }
                // As OpenConversation.apply takes it in.
                if event.reset { data.items = [] }
                data.items.append(contentsOf: event.items)
                if event.reset { data.earlier = event.earlier ?? 0 }
                if event.reset { data.more = event.more ?? false }
                write("  conversation \(event.id)\(event.reset ? " from the start" : ""): \(event.items.count) new, \(data.items.count) in all, \(data.earlier) earlier, more \(data.more)")
                for item in event.items { write("    item \(Dump.text(item))") }
                update("    state", &data.state, event.state)
                feed(event.id, data)
            case "conversation.older":
                let event = try decoder.decode(OlderEvent.self, from: line)
                guard let data = open[event.id] else {
                    write("  conversation \(event.id) is not open")
                    return
                }
                // As OpenConversation.prepend takes it in.
                let first = data.items.first?.id ?? Int.max
                let before = event.items.filter { $0.id < first }
                data.items.insert(contentsOf: before, at: 0)
                data.earlier = event.earlier
                if let more = event.more { data.more = more }
                write("  conversation \(event.id): \(before.count) older, \(data.items.count) in all, \(data.earlier) earlier, more \(data.more)")
                for item in before { write("    item \(Dump.text(item))") }
                feed(event.id, data)
            case "needs":
                let read = try decoder.decode(NeedItemsEvent.self, from: line).items
                update("needRefs", &needRefs, read.map { NeedRef(projectId: $0.projectId) })
                var proposals: [String: [NeedItem]] = [:]
                for need in read where need.kind == "rule" {
                    if let projectId = need.projectId { proposals[projectId, default: []].append(need) }
                }
                let known = Set(needs.map(\.id))
                update("ruleNeeds", &ruleNeeds, proposals)
                update("needs", &needs, read)
                write("  notified \(Dump.text(read.filter { !known.contains($0.id) }.map(\.id)))")
                let shown = read.filter { $0.kind == "reach" || $0.kind == "rule" }.map {
                    TranscriptFeed.Need(
                        id: $0.id, kind: $0.kind, conversationId: $0.conversationId, agentName: $0.agentName, createdAt: $0.createdAt,
                        change: $0.change.map { TranscriptFeed.Need.ReachChange(summary: $0.summary) }, text: $0.text, binds: $0.binds?.rawValue, why: $0.why
                    )
                }
                update("conversationNeeds", &conversationNeeds, shown)
            case "projectRules":
                update("projectRules", &projectRules, try decoder.decode(ProjectRulesEvent.self, from: line).projects)
            case let kind? where Self.extraKinds.contains(kind):
                let before = extras.generation(kind)
                extras[kind] = try decoder.decode(JSONValue.self, from: line)
                write("  extras[\(kind)] \(extras.generation(kind) == before ? "unchanged" : "= \(Dump.text(extras[kind] as Any))")")
            case let kind? where Self.appKinds.contains(kind):
                var kept = appKept[kind]
                update("\(kind) (the app's own types)", &kept, try decoder.decode(JSONValue.self, from: line))
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
        } catch {
            write("  could not be read")
            unread.append("line \(number) (\(kind))")
        }
    }

    /// What the conversation's page is sent next, as its web view works it out from what the client holds.
    private func feed(_ id: Int, _ data: Open) {
        let state = data.state
        var mcp: [String: String] = [:]
        for server in mcpServers {
            for tool in server.tools { mcp[tool.toolName] = "\(server.name): \(tool.name)" }
        }
        // The colour is the app's (AgentColor); the model's short name is worked out as the app does, from the models.
        let agents = allAgents.map { TranscriptFeed.Agent(id: $0.id, name: $0.name, color: $0.color, model: shortModelName($0.model)) }
        var apps: [String: String] = [:]
        for app in TranscriptFeed.appsNamed(in: data.items, partial: state?.partial, inbox: inbox) { apps[app] = app }
        let names = TranscriptFeed.Names(
            conversationId: id, agentName: allAgents.first { $0.id == state?.agent.agentId }?.name ?? "",
            mcp: mcp, agents: agents, apps: apps, folder: state?.agent.cwd?.hasPrefix("/") == true
        )
        var chat = TranscriptFeed.Chat.none
        if TranscriptFeed.Chat.shown(for: state) {
            let groups = Dictionary(grouping: allModels.filter { $0.hidden != true }, by: \.provider)
                .map { (name: $0.value[0].providerName, models: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let models = groups.flatMap { group in
                group.models.map { TranscriptFeed.ModelChoice(provider: $0.provider, id: $0.id, name: $0.listName, group: group.name) }
            }
            let model = state?.agent.model.map { "\($0.provider)/\($0.modelId)" } ?? ""
            chat = TranscriptFeed.Chat(enabled: true, versions: state?.versions ?? [], models: models, model: model)
        }
        let message = data.feed.update(
            items: data.items, earlier: data.earlier, older: TranscriptFeed.Older(more: data.more, loading: false), state: state,
            inbox: inbox.filter { $0.conversationId == id }, changes: state?.projectChanges ?? [],
            needs: conversationNeeds.filter { $0.conversationId == id }, names: names, palette: [:], chat: chat
        )
        write("    page \(message.flatMap(TranscriptFeed.json) ?? "nothing new"), \(data.feed.pending) to send")
    }

    private func shortModelName(_ ref: ModelRef?) -> String {
        guard let ref = ref ?? defaultModel else { return "" }
        let name = allModels.first { $0.ref == ref }?.name ?? ref.modelId
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
        for (id, data) in open.sorted(by: { $0.key < $1.key }) {
            write("  \(id): \(data.items.count) items, ids \(Dump.text(data.items.map(\.id))), earlier \(data.earlier), more \(data.more), arrived \(data.state != nil)")
        }
    }
}
