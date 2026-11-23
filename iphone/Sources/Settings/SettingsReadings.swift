import Foundation
import PiModels

// What the settings screens read of the engine's events that the client keeps as they were sent (`extras`), each read
// as the Mac's views read it (app/Sources/pi2: AwakeSettings, CoauthorSettings, ChatSettings, CompactionSettings,
// AgentDefaultSettings, LimitsView). Each is nil until the engine has sent its event, so that a screen shows "not known
// yet" rather than a default the Mac may not have. The Mac's readers live in the Mac app's target; these are the phone's
// until they move to `PiModels` beside the types they read (#669).

/// Keeping the Mac awake while agents work: the `awake` event (engine/src/keepawake.ts).
struct SettingsAwake: Equatable {
    var keep: Bool
    var battery: Bool

    init(keep: Bool, battery: Bool) {
        self.keep = keep
        self.battery = battery
    }

    init?(_ event: JSONValue?) {
        guard let event, case .object = event else { return nil }
        // As the Mac reads it: on, and off on battery, until the engine says otherwise.
        keep = event["keep"].flag ?? true
        battery = event["battery"].flag ?? false
    }
}

/// The co-author line agents are asked to end their commits with: the `coauthor` event (docs/commits.md).
struct SettingsCoauthor: Equatable {
    static let fallback = "Co-authored-by: pi² <noreply@pi2.invalid>"
    var enabled: Bool
    var line: String
    var defaultLine: String

    init(enabled: Bool, line: String, defaultLine: String = Self.fallback) {
        self.enabled = enabled
        self.line = line
        self.defaultLine = defaultLine
    }

    init?(_ event: JSONValue?) {
        guard let event, case .object = event else { return nil }
        enabled = event["enabled"].flag ?? false
        line = event["line"]?.stringValue ?? Self.fallback
        defaultLine = event["defaultLine"]?.stringValue ?? Self.fallback
    }
}

/// Chat mode's settings: the `chat` event (docs/chat.md#settings).
struct SettingsChat: Equatable {
    var instructions: String
    var defaultModel: ModelRef?
    var web: Bool
    var memory: Bool

    init(instructions: String = "", defaultModel: ModelRef? = nil, web: Bool = true, memory: Bool = true) {
        self.instructions = instructions
        self.defaultModel = defaultModel
        self.web = web
        self.memory = memory
    }

    init?(_ event: JSONValue?) {
        guard let event, case .object = event else { return nil }
        instructions = event["instructions"]?.stringValue ?? ""
        defaultModel = SettingsModelRef.read(event["defaultModel"])
        web = event["web"].flag ?? true
        memory = event["memory"].flag ?? true
    }
}

/// The default size at which a conversation's earlier messages are summarised: the `compactionSettings` event
/// (docs/compaction.md). `tokens` nil is off.
struct SettingsCompaction: Equatable {
    var tokens: Int?

    init(tokens: Int?) {
        self.tokens = tokens
    }

    init?(_ event: JSONValue?) {
        guard let event, case .object = event else { return nil }
        tokens = event["defaultCompactionTokens"]?.intValue
    }

    /// The sizes the Mac offers (`CompactionSize.choices`), with one set elsewhere among them, so it is never silently
    /// replaced.
    static func choices(including value: Int?) -> [Int] {
        let usual = [50_000, 100_000, 200_000, 300_000, 500_000]
        guard let value, value > 0, !usual.contains(value) else { return usual }
        return (usual + [value]).sorted()
    }

    static func label(_ tokens: Int) -> String { "\(tokens.formatted()) tokens" }
}

/// The model every agent with none of its own starts on: the `agentDefault` event (#617).
struct SettingsAgentDefault: Equatable {
    /// What the person chose; nil for the model used last.
    var model: ModelRef?
    /// What such an agent starts on now.
    var using: ModelRef?
    var fellBack: Bool

    init(model: ModelRef?, using: ModelRef?, fellBack: Bool = false) {
        self.model = model
        self.using = using
        self.fellBack = fellBack
    }

    init?(_ event: JSONValue?) {
        guard let event, case .object = event else { return nil }
        model = SettingsModelRef.read(event["model"])
        using = SettingsModelRef.read(event["using"])
        fellBack = event["fellBack"].flag ?? false
    }
}

/// How long unused conversations wait before they are archived on their own (`settings.setAutoArchive`), with the
/// Mac's choices and words (app/Sources/pi2/ArchiveViews.swift).
enum SettingsAutoArchive {
    /// The usual choices, with whatever is set when it is not one of them.
    static func choices(including set: Int?) -> [Int] {
        var days = [7, 30, 90, 365]
        if let set, set > 0, !days.contains(set) { days = (days + [set]).sorted() }
        return days
    }

    static func label(_ days: Int?) -> String {
        switch days {
        case nil, 0?: "Never"
        case 7?: "A week"
        case 30?: "A month"
        case 90?: "Three months"
        case 365?: "A year"
        case let days?: "\(days) days"
        }
    }
}

/// One window of a plan, as the `limits` event sends it (engine/src/limits.ts; the Mac's `PlanLimits`): how much of it is
/// used, and when it starts again.
struct SettingsPlanWindow: Equatable, Identifiable {
    var providerName: String
    var plan: String?
    var label: String
    /// 0 to 100.
    var usedPercent: Double
    /// When it starts again; nil when the provider does not say.
    var resetsAt: Date?

    var id: String { "\(providerName)·\(plan ?? "")·\(label)" }

    init(providerName: String, plan: String?, label: String, usedPercent: Double, resetsAt: Date?) {
        self.providerName = providerName
        self.plan = plan
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Every window the event names, of every provider.
    static func read(_ event: JSONValue?) -> [SettingsPlanWindow] {
        (event?["providers"]?.arrayValue ?? []).flatMap { provider -> [SettingsPlanWindow] in
            let name = provider["name"]?.stringValue ?? provider["id"]?.stringValue ?? "A provider"
            let plan = provider["plan"]?.stringValue
            return (provider["windows"]?.arrayValue ?? []).compactMap { window in
                guard let label = window["label"]?.stringValue, let used = window["usedPercent"].number else { return nil }
                let resets = window["resetsAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) }
                return SettingsPlanWindow(providerName: name, plan: plan, label: label, usedPercent: used, resetsAt: resets)
            }
        }
    }

    /// The most-used window that still counts at `now` (one whose reset has passed does not), as a project's plan limit
    /// counts them; nil when none has been read.
    static func mostUsed(_ windows: [SettingsPlanWindow], at now: Date) -> SettingsPlanWindow? {
        windows.filter { $0.resetsAt.map { $0 > now } ?? true }.max { $0.usedPercent < $1.usedPercent }
    }

    /// "Anthropic Max, week: 41% used, resets Mon 09:00".
    func line(at now: Date) -> String {
        let percent = Int(usedPercent.rounded())
        let resets = resetsAt.map { ", resets \($0.formatted(date: Calendar.current.isDate($0, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))" } ?? ""
        return "\(providerName)\(plan.map { " \($0)" } ?? ""), \(label): \(percent)% used\(resets)"
    }
}

enum SettingsModelRef {
    static func read(_ value: JSONValue?) -> ModelRef? {
        guard let provider = value?["provider"]?.stringValue, let modelId = value?["modelId"]?.stringValue else { return nil }
        return ModelRef(provider: provider, modelId: modelId)
    }
}

/// Dollars as the Mac's Usage shows them: "$0.42", "$12.50", "$0" for nothing.
enum SettingsMoney {
    static func text(_ dollars: Double) -> String {
        if dollars == 0 { return "$0" }
        if dollars < 0.01 { return "less than $0.01" }
        return dollars.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

extension Optional where Wrapped == JSONValue {
    /// A JSON true or false, or nil for anything else.
    fileprivate var flag: Bool? {
        if case .bool(let value)? = self { return value }
        return nil
    }

    /// A JSON number, or nil for anything else.
    fileprivate var number: Double? {
        if case .number(let value)? = self { return value }
        return nil
    }
}
