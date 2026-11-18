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
    /// A chat with pi²'s own assistant, shown in chat mode only (ChatMode.swift), rather than an agent's conversation.
    var chat: Bool? = nil
    /// A chat kept at the top of chat mode's sidebar.
    var pinned: Bool? = nil
}

/// The branch a conversation's folder is on, as the engine's tracker last saw it (worktrees.ts). Shown in the sidebar,
/// the conversation's toolbar and the Branches page; see BranchViews.swift.
struct BranchStatus: Codable, Equatable {
    /// The repository's name.
    let repo: String
    /// The top of the checkout the conversation works in.
    let root: String
    /// Nil when HEAD is detached.
    let branch: String?
    let head: String?
    /// A linked worktree rather than the repository's main checkout.
    let worktree: Bool
    /// A worktree pi² made for this conversation, which it can remove.
    let managed: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let base: String?
    /// Commits not on `base` yet.
    let unmerged: Int?
    let changes: Int
    let conflicts: Int
    /// A merge, rebase, cherry-pick or revert that stopped half way.
    let operation: String?
    /// "conflict", "changes", "detached", "merged", "ahead", "behind", "clean" or "missing".
    let state: String

    /// Whether removing the worktree would lose uncommitted work.
    var isDirty: Bool { changes > 0 || conflicts > 0 }
}

/// A worktree pi² made for a conversation that was archived or deleted since: still on disk until it is removed.
/// Listed on the Branches page.
struct LeftBehindWorktree: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    /// "archived" (it can be restored, and may still want its worktree) or "deleted".
    let reason: String
    let status: BranchStatus
}

/// A conversation in the Archive: out of the sidebar, still readable and searchable, and restorable.
struct ArchivedConversation: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let updatedAt: Double
    let archivedAt: Double
    let agentId: String?
    let createdAt: Double?
    /// How many sub-chats went into the Archive with it.
    let subChats: Int
    /// For a sub-chat its conversation's agent archived on its own: that conversation, which stays in the sidebar.
    let parent: Int?
    let parentTitle: String?
    /// An archived chat with pi²'s own assistant.
    var chat: Bool? = nil
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
    /// For a shell command running in the foreground: when it started, and when it last printed (nil until it has),
    /// in ms since 1970. The conversation page ticks its clock from them (#196).
    var startedAt: Double?
    var lastOutputAt: Double?
}

struct RetryInfo: Codable, Equatable {
    let at: Double
    let error: String
}

/// A run waiting for a provider's rate limit, or for it to stop being overloaded, before it asks again by itself.
struct LimitWait: Codable, Equatable {
    /// "rate_limit" or "overloaded".
    let kind: String
    /// When the first refusal of this wait came, and when the run asks again, in milliseconds since 1970.
    let since: Double
    let until: Double
    /// Whether the provider named that time; otherwise it is pi²'s own backoff.
    let told: Bool
    let refusals: Int
    /// The provider's name, as Settings shows it.
    let provider: String

    /// "14:32", or with the day when it is not today.
    var untilText: String {
        let date = Date(timeIntervalSince1970: until / 1000)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What the conversation says while it waits.
    var sentence: String {
        let what = kind == "overloaded" ? "\(provider) is overloaded" : "\(provider) refused the request for its rate limit"
        let refused = refusals > 1 ? ", \(refusals) times so far" : ""
        if told {
            return "\(what)\(refused). The run waits until \(untilText), the time it named, then carries on by itself. Stop ends it."
        }
        return "\(what)\(refused), and named no time. The run asks again at \(untilText) and carries on by itself. Stop ends it."
    }

    /// The short form, for a row in Activity.
    var tag: String {
        kind == "overloaded" ? "provider overloaded · until \(untilText)" : "rate limit · until \(untilText)"
    }
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
    /// Whether the agent may also use throwaway test copies of pi² (#146). Optional: agents saved before it have none.
    var testCopies: Bool?
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

/// One of the built-in tools an agent's settings list, as the engine describes it (engine/src/builtins.ts).
struct BuiltInTool: Codable, Equatable, Identifiable {
    let key: String
    let tools: [String]
    let title: String
    let detail: String
    /// Where it is offered at all: "files" (any access but none), "changes" (Ask first or Full access), "browser" (the
    /// browser on); nil for anywhere.
    let needs: String?
    var id: String { key }
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

/// An environment variable of an agent's own: its name, and whether a value is kept for it. The value stays in the
/// Keychain and never comes to the app.
struct AgentVariable: Codable, Equatable, Identifiable {
    let name: String
    let set: Bool
    var id: String { name }
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
    /// Whether each conversation the person starts gets a git worktree of its own, made from `cwd`.
    var worktree: Bool?
    /// A shell command run once in each new worktree of the agent's conversations. Empty for none.
    var setup: String?
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
    /// Keys of the built-in tools it is not offered, in the engine's order. Nil or empty: all of them.
    var toolsOff: [String]?
    /// Commands it may run without asking. Changed through their own requests, never by saving the agent.
    var commandRules: [CommandRule]?
    /// Variables its commands get. Changed through their own requests, never by saving the agent.
    var variables: [AgentVariable]?
    var createdAt: Double

    /// What the engine's `agents.save` takes. Nulls are sent, so clearing a field clears it.
    var payload: [String: Any] {
        [
            "id": id, "name": name, "description": description, "color": color,
            "model": model.map { ["provider": $0.provider, "modelId": $0.modelId] as Any } ?? NSNull(),
            "thinkingLevel": thinkingLevel as Any? ?? NSNull(),
            "instructions": instructions, "access": access,
            "cwd": cwd as Any? ?? NSNull(),
            "worktree": worktree ?? false,
            "setup": setup ?? "",
            "delegates": delegates,
            "maxTurns": maxTurns as Any? ?? NSNull(),
            "codeMode": codeMode ?? false,
            "mcpServers": mcpServers ?? [],
            "files": (files ?? []).map { ["path": $0.path, "note": $0.note] },
            "computer": [
                "enabled": computer?.enabled ?? false, "apps": computer?.apps ?? [], "ask": computer?.ask ?? true,
                "testCopies": computer?.testCopies ?? false,
            ],
            "browser": ["enabled": browser?.enabled ?? false, "ask": browser?.ask ?? true],
            "schedule": ["enabled": schedule?.enabled ?? false],
            "toolsOff": toolsOff ?? [],
        ]
    }

    /// The agent as `agents.save` would store it: missing settings filled with their defaults and text tidied the way
    /// the engine tidies it. Rules are left out, since saving never changes them. Two agents that are the same here
    /// save the same, so the editor compares these to tell whether there is anything to save. The starter agents are
    /// made without most of the optional settings, and saving fills them in.
    var asSaved: AgentProfile {
        var agent = self
        agent.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.worktree = worktree ?? false
        agent.setup = (setup ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        agent.delegates = delegates.filter { $0 != id }
        agent.codeMode = codeMode ?? false
        agent.mcpServers = mcpServers ?? []
        var paths = Set<String>()
        agent.files = (files ?? []).compactMap { file in
            let path = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard paths.insert(path).inserted else { return nil }
            return ReferenceFile(path: path, note: String(file.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
        }
        var apps = Set<String>()
        agent.computer = ComputerSettings(
            enabled: computer?.enabled ?? false,
            apps: (computer?.apps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && apps.insert($0).inserted },
            ask: computer?.ask ?? true,
            testCopies: computer?.testCopies ?? false)
        agent.browser = browser ?? BrowserSettings()
        agent.schedule = schedule ?? ScheduleSettings()
        agent.toolsOff = toolsOff ?? []
        agent.commandRules = nil
        agent.variables = nil
        return agent
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
    /// For a command: it would be started and left running in the background, so the card says so.
    var background: Bool? = nil
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
    /// The rule is kept for a repository's main checkout, so it also holds in the worktrees pi² makes from it.
    var worktrees: Bool? = nil
    var command: String { words.joined(separator: " ") }
    /// How the approval's button ends, after the command: "Here", or "in This Repository" when the rule also holds in
    /// the repository's main checkout and its pi² worktrees. The conversation page says the same (`ruleOffer` in tools.js).
    var place: String { worktrees == true ? "in This Repository" : "Here" }
}

/// A command an agent left running in the background, as the Activity view lists it.
struct BackgroundCommand: Codable, Equatable, Identifiable {
    /// "bg-3": what the agent and the transcript call it.
    let id: String
    let conversationId: Int
    /// The conversation in the sidebar it belongs to; differs from `conversationId` for a sub-chat's command.
    let rootConversationId: Int
    let command: String
    /// The folder it was started in.
    let cwd: String
    let startedAt: Double
}

/// A background command and the output of it the engine keeps, as the person reads it (`background.output`).
struct BackgroundOutput: Decodable, Equatable {
    struct Ended: Decodable, Equatable {
        let at: Double
        /// Worded to follow "It": "exited with code 1 after 4 seconds".
        let how: String
        let failed: Bool
    }

    let id: String
    let conversationId: Int
    let rootConversationId: Int
    let command: String
    let cwd: String
    let startedAt: Double
    let running: Bool
    /// Asked to stop, and not yet over.
    let stopping: Bool
    let ended: Ended?
    /// False for a command an engine that stopped had started: its output went with that engine.
    let kept: Bool
    /// Characters it has printed in all, counted as the engine counts them (UTF-16 units). The next request starts here.
    let total: Int
    /// Where `output` begins, counted from the first character it printed.
    let from: Int
    /// Characters printed after the point asked for that were not kept.
    let dropped: Int
    let output: String
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
    /// Set while the run waits for a provider's limit; nil otherwise, and from an engine older than this field.
    let limit: LimitWait?
    /// Its shell commands running in the foreground, oldest first, with their clocks (#196). Absent from an older engine.
    var commands: [RunningCommand]?
    /// A chat answering, rather than an agent's work (docs/chat.md).
    var chat: Bool?
    var id: Int { conversationId }
}

/// A shell command running in the foreground: what it runs, when it started and when it last printed, in ms since 1970.
struct RunningCommand: Codable, Equatable {
    let callId: String
    let command: String
    let startedAt: Double
    let lastOutputAt: Double?

    /// A command shows how long it has been quiet only after this long, so a busy one's row is still.
    static let quietAfter: TimeInterval = 30

    /// "45s", "3m 12s", "1h 4m", as the conversation page writes them.
    static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// How long it has run at `now`.
    func elapsed(at now: Date) -> String { Self.short(now.timeIntervalSince1970 - startedAt / 1000) }

    /// "quiet for 45s" once it has printed nothing for `quietAfter`, else nil.
    func quiet(at now: Date) -> String? {
        let since = max(startedAt, lastOutputAt ?? startedAt) / 1000
        let seconds = now.timeIntervalSince1970 - since
        return seconds >= Self.quietAfter ? "quiet for \(Self.short(seconds))" : nil
    }
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
    /// A command an agent had left running in the background, and what the new engine did about it.
    struct LeftCommand: Codable, Equatable, Identifiable {
        /// "bg-3".
        let id: String
        let conversationId: Int
        /// The conversation in the sidebar it belongs to, and its title; differs from `conversationId` for a sub-chat's command.
        let rootConversationId: Int
        let title: String
        let command: String
        /// "stopped", "partly" (what carried the run's marker was stopped, the rest left), "gone" (it had ended), "unsure"
        /// (left alone, as pi² could not tell it was the same) or "unknown" (left alone: its process had not been noted yet).
        let outcome: String
        let group: Int?
    }
    /// A worktree's set-up command that was running, and what the new engine did about it. One per conversation at most.
    struct LeftSetup: Codable, Equatable, Identifiable {
        var id: Int { conversationId }
        let conversationId: Int
        let rootConversationId: Int
        let title: String
        let command: String
        /// As for `LeftCommand`, but for "unknown": a set-up whose process was not noted yet counts as "gone".
        let outcome: String
        let group: Int?
    }
    let at: Double
    let conversations: [Resumed]
    /// Absent from an engine older than this app.
    let background: [LeftCommand]?
    let setups: [LeftSetup]?
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
    /// Set while the run waits for a provider's limit; nil otherwise, and from an engine older than this field.
    let limitWait: LimitWait?
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
    /// The nearest project instructions file (AGENTS.md or CLAUDE.md) in effect, if there is one.
    let projectInstructions: String?
    /// Every project instructions file in effect: in the conversation's folder and the folders above it up to the top of its
    /// git repository, the outermost first. Nil from an engine older than this field.
    let projectInstructionFiles: [ProjectInstructionsFile]?
    /// The conversation's title, for one that is not in the sidebar's list (an archived one, or its sub-chat).
    let title: String?
    /// It, or the conversation it is a sub-chat of, is archived: it can be read but not continued.
    let archived: Bool?
    /// The agent's set-up command running in the conversation's new worktree, with what it has printed so far. Nil when
    /// none is running, and from an engine older than this field.
    let setup: LiveSetup?
    /// Its model runs on this Mac: whether it is loading, loaded, stopped or could not start. Nil for any other model,
    /// and from an engine older than this field.
    let local: LocalModelState?
    /// A chat with pi²'s own assistant (docs/chat.md). Nil from an engine older than chat mode.
    var chat: Bool? = nil
}

/// A worktree set-up command still running: which run it is (its transcript entry's `details.run`) and the end of its output.
struct LiveSetup: Codable, Equatable {
    let run: String
    let output: String
}

/// One project instructions file in effect for a conversation: its name, and the real path of the folder it is in.
struct ProjectInstructionsFile: Codable, Equatable {
    let folder: String
    let file: String
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
        /// Added by hand, so pi² does not know its price: the tokens are counted, the cost is not.
        var unpriced: Bool? = nil
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
    /// A server run as a program: its own environment variables, by name. The values stay in the Keychain.
    let variables: [AgentVariable]?
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
    /// Found in an archived conversation.
    let archived: Bool?
    /// Found in a chat rather than an agent's conversation.
    var chat: Bool? = nil
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
    /// Whether a signed-in or keyed built-in provider can be asked which models it offers, where, or why not.
    var ask: Ask? = nil

    struct Ask: Codable, Equatable {
        let can: Bool
        /// The address asked; nil for a provider whose list the library refreshes itself.
        var url: String? = nil
        var why: String? = nil
    }

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
    /// Added by its id to a built-in provider whose list pi² has does not have it yet (Settings › Providers › Models…).
    var addedByHand: Bool? = nil

    var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
    /// The name as a model menu lists it, marked when it was added by hand.
    var listName: String { addedByHand == true ? "\(name) (added by hand)" : name }
}

/// What a provider said when asked which models its key or sign-in can use (`providers.ask`).
struct ProviderListing: Codable, Equatable {
    struct Listed: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        /// In pi²'s own list of the provider's models.
        let known: Bool
    }
    let provider: String
    let providerName: String
    let asked: String?
    let refreshed: Bool
    let catalogCount: Int
    let models: [Listed]
}

/// What the engine's `providers.draftModel` proposes for a model added by its id: settings taken from a model it knows.
struct ModelDraft: Codable, Equatable {
    struct Template: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let api: String
    }
    let provider: String
    let providerName: String
    let id: String
    var name: String
    let basedOn: String
    let basedOnName: String
    /// "family": the newest of the id's family; "nearest": no model of that family, so the closest; "chosen": picked.
    let match: String
    /// What the provider said itself when asked ("context size", "pictures"), in place of the template's.
    var told: [String]? = nil
    let api: String
    let apis: [String]
    var contextWindow: Int
    var maxTokens: Int
    var vision: Bool
    var thinkingLevels: [String]
    let templates: [Template]
    let editing: Bool
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
