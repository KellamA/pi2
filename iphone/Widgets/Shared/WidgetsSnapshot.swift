import Foundation
import PiModels

/// What the widgets draw (docs/iphone.md 12.2, P31; docs/design/iphone.md, "What a phone adds"): Needs you, Who is
/// working and Today's spending, as the phone last had them from its Mac. The app makes it from what its client holds
/// (`init(needs:activity:projects:agents:usage:limits:heardAt:macName:)`) and writes it with `WidgetsFile`; the widgets
/// extension reads it and nothing else, since the phone's store is sealed with a key only a session Face ID opened can
/// read (docs/iphone-app.md, "The extensions").
///
/// **Counts and names only.** The file is not sealed, and a widget is drawn while the phone is locked, so it holds what
/// the design gives the widgets and no more: how many things wait and who asks (the words of a notification's title,
/// "Forge needs approval", never the card's text, a command or a question), which agents work in which project, and
/// today's spending with the plan's windows. Nothing in it is made up: every value is one the Mac sent.
struct WidgetsSnapshot: Codable, Equatable, Sendable {
    /// The file's shape. A snapshot of another version is not read, and the widgets say to open pi².
    static let currentVersion = 1
    /// How long a snapshot is drawn without the Mac: as long as the phone's store keeps its state (decision 31,
    /// `PhoneStore.keptWithoutMac`). After that the widgets say to open pi², as the store is wiped by then.
    static let keptFor: TimeInterval = 7 * 86_400
    /// How many needs and agents the snapshot keeps by name: what the large widget lists.
    static let named = 6

    var version = currentVersion
    /// When the Mac's state this was made from was last heard: now while connected, the store's last word while out of
    /// reach. The widgets say "Updated" with it.
    var heardAt: Date
    var macName: String?
    var needs: Needs
    var working: [Worker]
    /// Nil until the Mac has sent its usage.
    var spending: Spending?

    struct Needs: Codable, Equatable, Sendable {
        /// Everything waiting under Needs you, of every project.
        var count: Int
        /// The newest first, at most `named`.
        var newest: [Need]
    }

    struct Need: Codable, Equatable, Identifiable, Sendable {
        var id: String
        /// Who asks and what kind, as a notification's title says it: "Forge needs approval".
        var title: String
        var agentName: String?
        var agentColor: String?
        var projectID: String?
        var projectName: String?
        var createdAt: Date
    }

    /// An agent at work in a project, with however many runs it has there.
    struct Worker: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Sendable {
            case working
            /// Its runs wait for a provider's limit to reset.
            case waitsForLimit
            /// Its runs wait for the person: an approval or a question.
            case waitsForYou
        }

        var agentID: String
        var agentName: String
        var agentColor: String?
        var projectID: String?
        var projectName: String?
        /// The run that has gone longest, which a tap on the row opens.
        var conversationID: Int
        var since: Date
        var runs: Int
        var state: State

        var id: String { "\(agentID)|\(projectID ?? "")" }
    }

    struct Spending: Codable, Equatable, Sendable {
        var todayCost: Double
        var todayTokens: Int
        var dailyBudget: Double?
        var overBudget: Bool
        /// The plan's windows, the fullest first, at most `named`.
        var windows: [PlanWindow]
    }

    struct PlanWindow: Codable, Equatable, Identifiable, Sendable {
        var id: String
        /// The subscription: "Anthropic Max".
        var provider: String
        /// "5-hour window", "This week".
        var label: String
        /// 0–100.
        var usedPercent: Double
        var resetsAt: Date?
    }

    /// How many agents are at work, not waiting for the person.
    var workingCount: Int { working.filter { $0.state != .waitsForYou }.count }
}

extension WidgetsSnapshot {
    /// The snapshot of what the client holds: `session.engine`'s `needs`, `activity`, `projects`, `allAgents`, `usage`
    /// and `extras["limits"]`, all of `PiModels`, so that the extension, which has no EngineKit, can be tested with it too.
    init(
        needs: [NeedItem], activity: [ActivityRun], projects: [ProjectRow], agents: [AgentProfile],
        usage: UsageSummary?, limits: JSONValue?, heardAt: Date, macName: String?
    ) {
        let projectName = { (id: String?) in id.flatMap { id in projects.first { $0.id == id }?.name } }
        let agent = { (id: String?) in id.flatMap { id in agents.first { $0.id == id } } }

        let sorted = needs.sorted { $0.createdAt > $1.createdAt }
        let newest = sorted.prefix(Self.named).map { need in
            Need(
                id: need.id, title: Self.title(of: need), agentName: need.agentName, agentColor: agent(need.agentId)?.color,
                projectID: need.projectId, projectName: projectName(need.projectId),
                createdAt: Date(timeIntervalSince1970: need.createdAt / 1000)
            )
        }

        // A chat answering is not an agent at work. An agent with several runs in a project (its sub-chats) is one row.
        var workers: [String: Worker] = [:]
        for run in activity where run.chat != true {
            let agentID = run.runsAs ?? run.agentId ?? ""
            let since = Date(timeIntervalSince1970: run.since / 1000)
            let state: Worker.State = run.status == "waiting" ? .waitsForYou : (run.limit != nil ? .waitsForLimit : .working)
            let key = "\(agentID)|\(run.projectId ?? "")"
            if var worker = workers[key] {
                worker.runs += 1
                if since < worker.since { worker.since = since; worker.conversationID = run.conversationId }
                worker.state = Self.busier(worker.state, state)
                workers[key] = worker
            } else {
                let profile = agent(agentID)
                workers[key] = Worker(
                    agentID: agentID, agentName: profile?.name ?? "An agent", agentColor: profile?.color,
                    projectID: run.projectId, projectName: projectName(run.projectId),
                    conversationID: run.conversationId, since: since, runs: 1, state: state
                )
            }
        }
        let working = workers.values.sorted {
            ($0.state == .waitsForYou ? 1 : 0, $0.since, $0.id) < ($1.state == .waitsForYou ? 1 : 0, $1.since, $1.id)
        }

        self.init(
            heardAt: heardAt, macName: macName,
            needs: Needs(count: needs.count, newest: Array(newest)),
            working: Array(working.prefix(Self.named)),
            spending: usage.map { usage in
                Spending(
                    todayCost: usage.today.cost, todayTokens: usage.today.tokens, dailyBudget: usage.budget.daily,
                    overBudget: usage.overBudget, windows: Self.windows(limits)
                )
            }
        )
    }

    /// A notification's title for a need (`Notifier.needsYou` on the Mac): who asks, and what kind.
    static func title(of need: NeedItem) -> String {
        let who = need.agentName ?? "An agent"
        return switch need.kind {
        case "approval": "\(who) needs approval"
        case "question", "decision": "\(who) has a question"
        case "reach": "\(who) asks for more reach"
        case "rule": "\(who) proposes a rule"
        case "limit": "\(who) is held back by a limit"
        default: "\(who) needs you"
        }
    }

    /// Of an agent's runs, the state its row shows: at work if any run is, then held by a limit, then waiting for you.
    private static func busier(_ a: Worker.State, _ b: Worker.State) -> Worker.State {
        let order: [Worker.State] = [.working, .waitsForLimit, .waitsForYou]
        return order.firstIndex(of: a)! <= order.firstIndex(of: b)! ? a : b
    }

    /// The plan's windows from the `limits` event (engine/src/limits.ts), the fullest first. A provider that does not
    /// report them has none; an event that cannot be read gives none, rather than a window made up.
    static func windows(_ limits: JSONValue?) -> [PlanWindow] {
        struct Event: Decodable {
            struct Provider: Decodable {
                struct Window: Decodable {
                    let id: String
                    let label: String
                    let usedPercent: Double
                    let resetsAt: Double?
                }
                let id: String
                let name: String
                let plan: String?
                let windows: [Window]?
            }
            let providers: [Provider]
        }
        guard let limits, let data = try? JSONEncoder().encode(limits),
              let event = try? JSONDecoder().decode(Event.self, from: data) else { return [] }
        let windows = event.providers.flatMap { provider in
            (provider.windows ?? []).map { window in
                PlanWindow(
                    id: "\(provider.id).\(window.id)", provider: [provider.name, provider.plan].compactMap { $0 }.joined(separator: " "),
                    label: window.label, usedPercent: min(100, max(0, window.usedPercent)),
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                )
            }
        }
        return Array(windows.sorted { ($0.usedPercent, $1.id) > ($1.usedPercent, $0.id) }.prefix(named))
    }
}
