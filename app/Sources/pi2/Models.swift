import Foundation

/// Any JSON value, for payloads the app shows but does not interpret (tool arguments, request results).
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Compact text for display.
    var displayText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct ModelRef: Codable, Hashable, Sendable {
    let provider: String
    let modelId: String
}

struct ConversationSummary: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let updatedAt: Double
    let busy: Bool
    let agentId: String?
    let createdAt: Double?
    /// Set for a sub-chat: the conversation whose agent opened it.
    let parent: Int?
}

struct ToolCall: Codable, Equatable, Identifiable {
    let callId: String
    let name: String
    let arguments: JSONValue
    var id: String { callId }

    /// The one line worth showing for a call: the command, the path, or the raw arguments.
    var summary: String {
        if let command = arguments["command"]?.stringValue { return command }
        if let path = arguments["path"]?.stringValue { return path }
        if let task = arguments["task"]?.stringValue { return task }
        if let code = arguments["code"]?.stringValue { return code.replacingOccurrences(of: "\n", with: " ") }
        if let question = arguments["question"]?.stringValue { return question }
        return arguments.displayText.replacingOccurrences(of: "\n", with: " ")
    }
}

/// One transcript entry. `kind` is "user", "assistant", "tool" or "marker".
struct Item: Codable, Identifiable, Equatable {
    let id: Int
    let kind: String
    let text: String
    var thinking: String?
    var toolCalls: [ToolCall]?
    var stop: String?
    var error: String?
    var model: String?
    var callId: String?
    var name: String?
    var isError: Bool?
    var details: JSONValue?
    /// How many pictures a tool result or a message holds; they are fetched when shown, not sent with the transcript.
    var images: Int?
    /// What a message was sent with: its pictures and files, by name.
    var attachments: [AttachmentNote]?
}

struct PartialAnswer: Codable, Equatable {
    let text: String
    let thinking: String
    let toolCalls: [ToolCall]
}

struct LiveTool: Codable, Equatable {
    let callId: String
    let name: String
    let status: String
    let output: String
    let details: JSONValue?
}

struct RetryInfo: Codable, Equatable {
    let at: Double
    let error: String
}

struct RunFailure: Codable, Equatable {
    let reason: String
    let detail: String?

    var message: String {
        let what: String = switch reason {
        case "model_error": "The model returned an error"
        case "no_model": "The model is not available"
        case "aborted": "Stopped"
        case "interrupted": "The engine stopped while the model was answering"
        case "turn_limit": "The run reached its turn limit"
        case "restart_limit": "The run kept crashing and was ended"
        case "nothing_to_answer": "There was nothing to answer"
        default: "The run ended without an answer (\(reason))"
        }
        if let detail, !detail.isEmpty { return "\(what): \(detail)" }
        return what
    }
}

struct QueuedInput: Codable, Equatable, Identifiable {
    let id: Int
    let mode: String
    let text: String
    var attachments: [AttachmentNote]? = nil
}

struct AgentInfo: Codable, Equatable {
    let model: ModelRef?
    let thinkingLevel: String?
    let cwd: String?
    let access: String
    let agentId: String?
    /// Set for a subagent's conversation: the conversation that delegated to it.
    let parent: Int?
}

/// Whether an agent may use apps on this Mac: which ones, and whether it asks before acting.
struct ComputerSettings: Codable, Equatable {
    var enabled = false
    var apps: [String] = []
    var ask = true
}

/// Whether an agent may browse the web in pi²'s own browser, and whether it asks before acting on a page.
struct BrowserSettings: Codable, Equatable {
    var enabled = false
    var ask = true
}

/// Whether an agent may set schedules for itself. You approve each one before it is set.
struct ScheduleSettings: Codable, Equatable {
    var enabled = false
}

/// A file or folder an agent may always read, with a note on what it is for.
struct ReferenceFile: Codable, Equatable, Identifiable {
    var path: String
    var note: String
    var id: String { path }
}

/// Shell commands an agent may run without asking, in one folder: those that start with `words`.
struct CommandRule: Codable, Equatable, Identifiable {
    let folder: String
    let words: [String]
    let createdAt: Double
    var id: String { folder + "\n" + command }
    var command: String { words.joined(separator: " ") }
}

/// A saved setup that conversations start from.
struct AgentProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var color: String
    var model: ModelRef?
    var thinkingLevel: String?
    var instructions: String
    var access: String
    var cwd: String?
    var delegates: [String]
    var maxTurns: Int?
    var codeMode: Bool?
    var mcpServers: [String]?
    /// Files and folders every conversation of the agent may read.
    var files: [ReferenceFile]?
    /// Whether the agent may use apps on this Mac, and which.
    var computer: ComputerSettings?
    /// Whether the agent may browse the web in pi²'s own browser.
    var browser: BrowserSettings?
    /// Whether the agent may set schedules for itself.
    var schedule: ScheduleSettings?
    /// Commands it may run without asking. Changed through their own requests, never by saving the agent.
    var commandRules: [CommandRule]?
    var createdAt: Double

    /// What the engine's `agents.save` takes. Nulls are sent, so clearing a field clears it.
    var payload: [String: Any] {
        [
            "id": id, "name": name, "description": description, "color": color,
            "model": model.map { ["provider": $0.provider, "modelId": $0.modelId] as Any } ?? NSNull(),
            "thinkingLevel": thinkingLevel as Any? ?? NSNull(),
            "instructions": instructions, "access": access,
            "cwd": cwd as Any? ?? NSNull(),
            "delegates": delegates,
            "maxTurns": maxTurns as Any? ?? NSNull(),
            "codeMode": codeMode ?? false,
            "mcpServers": mcpServers ?? [],
            "files": (files ?? []).map { ["path": $0.path, "note": $0.note] },
            "computer": ["enabled": computer?.enabled ?? false, "apps": computer?.apps ?? [], "ask": computer?.ask ?? true],
            "browser": ["enabled": browser?.enabled ?? false, "ask": browser?.ask ?? true],
            "schedule": ["enabled": schedule?.enabled ?? false],
        ]
    }
}

/// Something a run is waiting on the person for: approval of a tool call, or an answer to a question.
struct InboxItem: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let conversationId: Int
    let callId: String
    let tool: String
    let arguments: JSONValue
    let question: String?
    /// For a browser action: the site it would act on, which is what "always allow" then covers.
    var site: String? = nil
    /// For a schedule an agent asks to set: when it would run, in words.
    var when: String? = nil
    /// For a command: the rule the engine offers to make of it. Answering "rule" makes this rule; nothing else is sent.
    var rule: RuleOffer? = nil
    let title: String
    let agentName: String?
    /// The conversation in the sidebar this belongs to; differs from `conversationId` for a subagent.
    let rootConversationId: Int
    let rootTitle: String

    var call: ToolCall { ToolCall(callId: callId, name: tool, arguments: arguments) }
}

/// The rule an approval for a command offers: commands that start with `words`, in `folder`.
struct RuleOffer: Codable, Equatable {
    let words: [String]
    let folder: String
    var command: String { words.joined(separator: " ") }
}

/// A conversation with work in flight, as the Activity view lists it.
struct ActivityRun: Codable, Equatable, Identifiable {
    let conversationId: Int
    let parent: Int?
    let rootConversationId: Int
    let title: String
    let agentId: String?
    let status: String
    let since: Double
    var id: Int { conversationId }
}

struct Repeat: Codable, Equatable {
    var kind: String
    var at: Double?
    var minutes: Int?
    var hour: Int?
    var minute: Int?
    var weekday: Int?

    var payload: [String: Any] {
        switch kind {
        case "once": ["kind": kind, "at": at ?? 0]
        case "interval": ["kind": kind, "minutes": minutes ?? 60]
        case "weekly": ["kind": kind, "weekday": weekday ?? 1, "hour": hour ?? 9, "minute": minute ?? 0]
        default: ["kind": "daily", "hour": hour ?? 9, "minute": minute ?? 0]
        }
    }

    var summary: String {
        let time = String(format: "%02d:%02d", hour ?? 0, minute ?? 0)
        switch kind {
        case "once":
            return "Once, " + Date(timeIntervalSince1970: (at ?? 0) / 1000).formatted(date: .abbreviated, time: .shortened)
        case "interval":
            let m = minutes ?? 60
            return m % 60 == 0 ? "Every \(m / 60 == 1 ? "hour" : "\(m / 60) hours")" : "Every \(m) minutes"
        case "weekly":
            return "Every \(Calendar.current.weekdaySymbols[(weekday ?? 1) % 7]) at \(time)"
        default:
            return "Every day at \(time)"
        }
    }
}

struct Schedule: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var agentId: String
    var prompt: String
    var `repeat`: Repeat
    var enabled: Bool
    var nextRunAt: Double?
    var lastRunAt: Double?
    var lastConversationId: Int?
    /// Set when an agent made it, with your approval; nil when you did. Only the engine sets it.
    var createdBy: Creator?

    struct Creator: Codable, Equatable {
        let agentId: String
        let conversationId: Int
    }

    func payload(isNew: Bool) -> [String: Any] {
        var result: [String: Any] = ["title": title, "agentId": agentId, "prompt": prompt, "repeat": `repeat`.payload, "enabled": enabled]
        if !isNew { result["id"] = id }
        return result
    }
}

/// What an engine that started after an unclean stop found and resumed.
struct RecoveryReport: Codable, Equatable {
    struct Resumed: Codable, Equatable, Identifiable {
        let id: Int
        let title: String
    }
    let at: Double
    let conversations: [Resumed]
}

enum AccessLevel {
    static let all: [(id: String, title: String, detail: String)] = [
        ("none", "Off", "Chat only"),
        ("read", "Read files", "Can read files in its folder"),
        ("ask", "Ask first", "Can edit files and run commands after you approve each one"),
        ("full", "Full access", "Edits files and runs commands without asking"),
    ]
}

struct ConversationState: Codable, Equatable {
    let busy: Bool
    let turns: Int
    let partial: PartialAnswer?
    let retry: RetryInfo?
    let tools: [LiveTool]
    let failure: RunFailure?
    let queued: [QueuedInput]
    let agent: AgentInfo
    let usage: Spend
    let context: ContextSize
    let compacting: Bool
    let compactionError: String?
    /// The agent's task list; nil when it keeps none.
    let plan: TaskList?
    /// The project instructions file (AGENTS.md or CLAUDE.md) in the conversation's folder, if there is one.
    let projectInstructions: String?
}

/// The task list an agent keeps for a conversation (`update_plan`). `updatedAt` tells one version of it from the next.
struct TaskList: Codable, Equatable {
    let items: [TaskItem]
    let updatedAt: Double

    var doneCount: Int { items.filter { $0.state == .completed }.count }
    var isFinished: Bool { !items.isEmpty && doneCount == items.count }
    /// The step in hand, or the next one waiting.
    var current: TaskItem? { items.first { $0.state == .inProgress } ?? items.first { $0.state == .pending } }
}

struct TaskItem: Codable, Equatable {
    enum Step { case pending, inProgress, completed

        var words: String {
            switch self {
            case .pending: "to do"
            case .inProgress: "in progress"
            case .completed: "done"
            }
        }
    }

    let content: String
    let status: String

    var state: Step { status == "completed" ? .completed : (status == "in_progress" ? .inProgress : .pending) }
}

struct Spend: Codable, Equatable {
    let cost: Double
    let tokens: Int

    var costText: String { Formats.cost(cost) }
    var tokensText: String { Formats.tokens(tokens) }
}

/// How full a conversation's context is. `window` is nil when the model's size is not known.
struct ContextSize: Codable, Equatable {
    let used: Int
    let window: Int?

    var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}

enum Formats {
    static func cost(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        return value < 0.01 ? "< $0.01" : String(format: "$%.2f", value)
    }

    /// Tokens, with the cost only when there is one: subscription and local use has no price.
    static func usage(tokens: Int, cost: Double) -> String {
        cost > 0 ? "\(Formats.tokens(tokens)) · \(Formats.cost(cost))" : "\(Formats.tokens(tokens)) tokens"
    }

    static func tokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}

/// Spend across the whole app, as the engine summarises it.
struct UsageSummary: Codable, Equatable {
    struct ModelRow: Codable, Equatable, Identifiable {
        let key: String
        let input: Int
        let output: Int
        let tokens: Int
        let cost: Double
        /// Paid for by a subscription sign-in, so there is no per-use cost to show.
        var subscription: Bool? = nil
        var id: String { key }
    }
    struct AgentRow: Codable, Equatable, Identifiable {
        let agentId: String
        let cost: Double
        let tokens: Int
        var id: String { agentId }
    }
    struct ConversationRow: Codable, Equatable, Identifiable {
        let id: Int
        let title: String
        let cost: Double
        let tokens: Int
    }
    struct Day: Codable, Equatable, Identifiable {
        let day: String
        let cost: Double
        let tokens: Int
        var id: String { day }
    }
    struct Budget: Codable, Equatable {
        let daily: Double?
    }
    let models: [ModelRow]
    let agents: [AgentRow]
    let conversations: [ConversationRow]
    let total: Spend
    let today: Spend
    let days: [Day]
    let budget: Budget
    let overBudget: Bool
}

struct McpServer: Codable, Equatable, Identifiable {
    struct Tool: Codable, Equatable, Identifiable {
        let name: String
        let toolName: String
        let description: String
        let readOnly: Bool
        var id: String { toolName }
    }
    let id: String
    let name: String
    let transport: String
    let command: String?
    let args: [String]?
    let url: String?
    let enabled: Bool
    let status: String
    let error: String?
    let hasToken: Bool
    let tools: [Tool]
}

struct SearchResult: Codable, Equatable, Identifiable {
    let conversationId: Int
    let title: String
    let entryId: Int
    let role: String
    let snippet: String
    var id: Int { entryId }
}

struct ConversationData: Equatable {
    var items: [Item] = []
    var state: ConversationState?
}

struct EndpointModel: Codable, Equatable, Hashable {
    let id: String
    var name: String? = nil
    var contextWindow: Int? = nil
    var reasoning: Bool? = nil
    /// Whether the person marked the model as able to see pictures.
    var vision: Bool? = nil

    /// What the engine's `endpoints.save` takes; fields that are not set are left out.
    var payload: [String: Any] {
        var result: [String: Any] = ["id": id]
        if let name { result["name"] = name }
        if let contextWindow { result["contextWindow"] = contextWindow }
        if let reasoning { result["reasoning"] = reasoning }
        if vision == true { result["vision"] = true }
        return result
    }
}

struct EndpointConfig: Codable, Equatable {
    let id: String
    let name: String
    let baseUrl: String
    let api: String
    let models: [EndpointModel]
}

struct ProviderInfo: Codable, Identifiable, Equatable {
    struct OAuth: Codable, Equatable {
        let name: String
        let subscription: Bool
    }
    struct Status: Codable, Equatable {
        let type: String
        let source: String?
    }
    let id: String
    let name: String
    let kind: String
    let keyAuth: Bool
    let oauth: OAuth?
    let status: Status?
    let modelCount: Int
    let endpoint: EndpointConfig?

    var statusText: String {
        guard let status else { return "Not connected" }
        if status.type == "oauth" { return "Signed in" }
        if let source = status.source, source != "stored credential" { return "Using \(source)" }
        return "Key saved"
    }
}

struct ModelInfo: Codable, Equatable, Identifiable {
    let provider: String
    let providerName: String
    let id: String
    let name: String
    let thinkingLevels: [String]
    let contextWindow: Int
    /// Left out of the model pickers by the choice made in Settings.
    var hidden: Bool? = nil
    /// Whether the model can be sent pictures. Nil from an engine that does not say.
    var vision: Bool? = nil

    var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
}

/// What a sign-in flow tells or asks the person, as pi-ai's provider-neutral events and prompts.
struct AuthNotice: Codable, Equatable {
    struct Link: Codable, Equatable {
        let url: String
        let label: String?
    }
    let type: String
    let message: String?
    let url: String?
    let instructions: String?
    let userCode: String?
    let verificationUri: String?
    let links: [Link]?
}

struct AuthPromptInfo: Codable, Equatable {
    struct Option: Codable, Equatable, Identifiable {
        let id: String
        let label: String
        let description: String?
    }
    let type: String
    let message: String
    let placeholder: String?
    let options: [Option]?
}

struct SignInFlow: Equatable {
    var loginId: String?
    let providerId: String
    let providerName: String
    var messages: [String] = []
    var openURL: String?
    var userCode: String?
    var promptId: String?
    var prompt: AuthPromptInfo?
    var error: String?
    var finished = false
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
