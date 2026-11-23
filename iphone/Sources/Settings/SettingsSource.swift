import EngineKit
import Foundation
import PiModels

/// What the settings screens are drawn from, read from the session's client as the Mac's views read it: the projects,
/// the agents, the schedules, today's spending, the plans' windows and the app's settings the engine sends. A debug build
/// may lay sample values over it (`SettingsSamples`) to draw states the recorded session lacks; a test builds one from
/// plain values.
@MainActor
struct SettingsSource {
    var connected: Bool
    var projects: [ProjectRow]
    var agents: [AgentProfile]
    var schedules: [Schedule]
    /// The conversations the Mac lists now, by id.
    var conversations: Set<Int>
    /// Today's cost of each project, by its id, as the `usage` event counts it; nil until the engine has sent it.
    var spentToday: [String: Double]?
    /// The plans' windows the `limits` event names; nil until the engine has sent it.
    var plan: [SettingsPlanWindow]?
    var awake: SettingsAwake?
    var coauthor: SettingsCoauthor?
    var chat: SettingsChat?
    var compaction: SettingsCompaction?
    var agentDefault: SettingsAgentDefault?
    /// After how many unused days a conversation is archived on its own; nil for never. Known once `libraryLoaded`.
    var autoArchiveDays: Int?
    var libraryLoaded: Bool
    /// Every model of every connected provider, the hidden ones included.
    var allModels: [ModelInfo]
    /// What a debug build laid over the engine's values, said on the screen; empty otherwise.
    var samples: [String] = []

    init(
        connected: Bool, projects: [ProjectRow], agents: [AgentProfile], schedules: [Schedule] = [], conversations: Set<Int> = [],
        spentToday: [String: Double]? = nil, plan: [SettingsPlanWindow]? = nil, awake: SettingsAwake? = nil,
        coauthor: SettingsCoauthor? = nil, chat: SettingsChat? = nil, compaction: SettingsCompaction? = nil,
        agentDefault: SettingsAgentDefault? = nil, autoArchiveDays: Int? = nil, libraryLoaded: Bool = true, allModels: [ModelInfo] = []
    ) {
        self.connected = connected
        self.projects = projects
        self.agents = agents
        self.schedules = schedules
        self.conversations = conversations
        self.spentToday = spentToday
        self.plan = plan
        self.awake = awake
        self.coauthor = coauthor
        self.chat = chat
        self.compaction = compaction
        self.agentDefault = agentDefault
        self.autoArchiveDays = autoArchiveDays
        self.libraryLoaded = libraryLoaded
        self.allModels = allModels
    }

    init(_ engine: EngineSession<MessageField>) {
        self.init(
            connected: engine.status == .connected,
            projects: engine.projects,
            agents: engine.allAgents,
            schedules: engine.schedules,
            conversations: Set(engine.conversations.map(\.id)),
            spentToday: engine.usage.map { usage in
                Dictionary((usage.projects ?? []).map { ($0.id, $0.today.cost) }, uniquingKeysWith: { first, _ in first })
            },
            plan: engine.extras["limits"].map { SettingsPlanWindow.read($0) },
            awake: SettingsAwake(engine.extras["awake"]),
            coauthor: SettingsCoauthor(engine.extras["coauthor"]),
            chat: SettingsChat(engine.extras["chat"]),
            compaction: SettingsCompaction(engine.extras["compactionSettings"]),
            agentDefault: SettingsAgentDefault(engine.extras["agentDefault"]),
            autoArchiveDays: engine.autoArchiveDays,
            libraryLoaded: engine.hasLoadedLibrary,
            allModels: engine.allModels
        )
        #if DEBUG
        SettingsSamples.current?.lay(over: &self)
        #endif
    }

    /// The session's client, with nothing sent while the connection bar says the Mac is out of reach or being reached.
    init(_ session: AppSession) {
        self.init(session.engine)
        switch session.connection {
        case .outOfReach, .connecting, .notPaired: connected = false
        case .demo, .connected: break
        }
    }

    /// Whether the engine's lists may still be coming: a project not among them may yet arrive.
    var waiting: Bool { !connected || (projects.isEmpty && !libraryLoaded) }

    func project(_ id: String) -> ProjectRow? {
        projects.first { $0.id == id }
    }

    var book: ScheduleBook {
        ScheduleBook(schedules: schedules, agents: agents, projects: projects, conversations: conversations)
    }

    func agent(_ id: String?) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    /// The models the pickers offer, by provider in name order, as the Mac's pickers list them.
    var modelGroups: [(name: String, models: [ModelInfo])] {
        Dictionary(grouping: allModels.filter { $0.hidden != true }, by: \.provider)
            .map { (name: $0.value[0].providerName, models: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Anthropic · Opus 5.5", or the model's id when the Mac does not list it now.
    func modelName(_ ref: ModelRef?) -> String? {
        guard let ref else { return nil }
        guard let model = allModels.first(where: { $0.ref == ref }) else { return ref.modelId }
        return "\(model.providerName) · \(model.name)"
    }
}
