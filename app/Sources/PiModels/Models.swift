import Foundation
import Observation

/// Any JSON value, for payloads the app shows but does not interpret (tool arguments, request results).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
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

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Compact text for display.
    public var displayText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

public struct ModelRef: Codable, Hashable, Sendable {
    public let provider: String
    public let modelId: String

    public init(provider: String, modelId: String) {
        self.provider = provider
        self.modelId = modelId
    }
}

public struct ConversationSummary: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let updatedAt: Double
    public let busy: Bool
    public let agentId: String?
    public let createdAt: Double?
    /// Set for a sub-chat: the conversation whose agent opened it.
    public let parent: Int?
    /// A chat with pi²'s own assistant, shown in chat mode only (ChatMode.swift), rather than an agent's conversation.
    public var chat: Bool? = nil
    /// A chat kept at the top of chat mode's sidebar.
    public var pinned: Bool? = nil
    /// An agent's conversation a chat was continued in (Continue with an Agent, ChatContinue.swift): that chat.
    public var continuedFrom: Int? = nil
    /// A chat continued with an agent: the conversations it went on in, oldest first.
    public var continuedIn: [Int]? = nil
    /// Allow everything as the conversation took it at its latest message: nothing it does is asked about.
    public var allowEverything: Bool? = nil
    /// The project it belongs to (docs/projects.md, 3.5).
    public var projectId: String? = nil
    /// The agent it runs as now: its `agentId`, but for a conversation carried over, its project's copy (3.4).
    public var runsAs: String? = nil
    /// "current" or "earlier" for a project's conversation with its orchestrator; nil for any other.
    public var orchestrator: String? = nil
    /// A conversation with a project's orchestrator begun with Start fresh: the one it followed (docs/projects.md, 6.5).
    public var freshFrom: Int? = nil
}

/// The branch a conversation's folder is on, as the engine's tracker last saw it (worktrees.ts). Shown in the sidebar,
/// the hub's headers and a project's Branches tab; see BranchViews.swift.
public struct BranchStatus: Codable, Equatable, Sendable {
    /// The repository's name.
    public let repo: String
    /// The top of the checkout the conversation works in.
    public let root: String
    /// Nil when HEAD is detached.
    public let branch: String?
    public let head: String?
    /// A linked worktree rather than the repository's main checkout.
    public let worktree: Bool
    /// A worktree pi² made for this conversation, which it can remove.
    public let managed: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let base: String?
    /// Commits not on `base` yet.
    public let unmerged: Int?
    /// For a worktree pi² made with commits not on `base`: the repository's default branch as last fetched, when it is
    /// another ref, and the commits not on it. Work merged there counts as merged too (#778). Nil from an older engine.
    public var defaultBranch: String? = nil
    public var unmergedDefault: Int? = nil
    public let changes: Int
    public let conflicts: Int
    /// A merge, rebase, cherry-pick or revert that stopped half way.
    public let operation: String?
    /// The size of the change in lines: what is committed beyond where the branch left `base`, plus what is not committed
    /// yet, new files included. Nil when it could not be measured, or from an engine older than #598.
    public var added: Int? = nil
    public var removed: Int? = nil
    /// "conflict", "changes", "detached", "merged", "ahead", "behind", "clean" or "missing".
    public let state: String

    /// Whether removing the worktree would lose uncommitted work.
    public var isDirty: Bool { changes > 0 || conflicts > 0 }

    /// The ref that holds every commit of HEAD: `base`, else the default branch; nil for neither (worktrees.ts, `containedIn`).
    public var containedIn: String? {
        if let base, unmerged == 0 { return base }
        if let defaultBranch, unmergedDefault == 0 { return defaultBranch }
        return nil
    }
}

/// A worktree pi² made for a conversation that was archived or deleted since: still on disk until it is removed.
/// Listed on a project's Branches tab.
public struct LeftBehindWorktree: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    /// "archived" (it can be restored, and may still want its worktree) or "deleted".
    public let reason: String
    public let status: BranchStatus
}

/// A conversation in the Archive: out of the sidebar, still readable and searchable, and restorable.
public struct ArchivedConversation: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let archivedAt: Double
    public let agentId: String?
    /// How many sub-chats went into the Archive with it.
    public let subChats: Int
    /// For a sub-chat its conversation's agent archived on its own: that conversation, which stays in the sidebar.
    public let parent: Int?
    public let parentTitle: String?
    /// An archived chat with pi²'s own assistant.
    public var chat: Bool? = nil
    /// The project it belongs to, if any.
    public var projectId: String? = nil
}

public struct ToolCall: Codable, Equatable, Identifiable, Sendable {
    public let callId: String
    public let name: String
    public let arguments: JSONValue
    public var id: String { callId }

    /// The one line worth showing for a call: the command, the path, or the raw arguments.
    public var summary: String {
        if let command = arguments["command"]?.stringValue { return command }
        if let path = arguments["path"]?.stringValue { return path }
        if let task = arguments["task"]?.stringValue { return task }
        if let code = arguments["code"]?.stringValue { return code.replacingOccurrences(of: "\n", with: " ") }
        if let question = arguments["question"]?.stringValue { return question }
        return arguments.displayText.replacingOccurrences(of: "\n", with: " ")
    }

    public init(callId: String, name: String, arguments: JSONValue) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }
}

/// One transcript entry. `kind` is "user", "assistant", "tool" or "marker".
public struct Item: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: String
    public let text: String
    public var thinking: String?
    public var toolCalls: [ToolCall]?
    public var stop: String?
    public var error: String?
    public var model: String?
    public var callId: String?
    public var name: String?
    public var isError: Bool?
    public var details: JSONValue?
    /// How many pictures a tool result or a message holds; they are fetched when shown, not sent with the transcript.
    public var images: Int?
    /// What a message was sent with: its pictures and files, by name.
    public var attachments: [AttachmentNote]?
}

public struct PartialAnswer: Codable, Equatable, Sendable {
    public let text: String
    public let thinking: String
    public let toolCalls: [ToolCall]
}

public struct LiveTool: Codable, Equatable, Sendable {
    public let callId: String
    public let name: String
    public let status: String
    public let output: String
    public let details: JSONValue?
    /// For a shell command running in the foreground: when it started, and when it last printed (nil until it has),
    /// in ms since 1970. The conversation page ticks its clock from them (#196).
    public var startedAt: Double?
    public var lastOutputAt: Double?
}

public struct RetryInfo: Codable, Equatable, Sendable {
    public let error: String
    /// The network is away, rather than the provider closing the stream.
    public let network: Bool?
    /// The provider closed the stream before or during the answer (#550): the conversation says so instead.
    public let closed: Bool?
}

/// A run waiting for a provider's rate limit, or for it to stop being overloaded, before it asks again by itself.
public struct LimitWait: Codable, Equatable, Sendable {
    /// "rate_limit" or "overloaded".
    public let kind: String
    /// When the first refusal of this wait came, and when the run asks again, in milliseconds since 1970.
    public let since: Double
    public let until: Double
    /// Whether the provider named that time; otherwise it is pi²'s own backoff.
    public let told: Bool
    public let refusals: Int
    /// The provider's name, as Settings shows it.
    public let provider: String
    /// The model that refused, which may differ from the model now picked in the toolbar.
    public let model: ModelRef?

    /// "14:32" within the next 20 hours, which cannot be mistaken for another day's; "Thu 09:00" within the week; else the date.
    public var untilText: String {
        let date = Date(timeIntervalSince1970: until / 1000)
        let ahead = date.timeIntervalSinceNow
        if ahead < 20 * 3600 { return date.formatted(date: .omitted, time: .shortened) }
        if ahead < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What the conversation says while it waits.
    public var sentence: String {
        let what = kind == "overloaded" ? "\(provider) is overloaded" : "\(provider) refused the request for its rate limit"
        let refused = refusals > 1 ? ", \(refusals) times so far" : ""
        if told {
            return "\(what)\(refused). The run waits until \(untilText), the time it named, then carries on by itself. Stop ends it."
        }
        return "\(what)\(refused), and named no time. The run asks again at \(untilText) and carries on by itself. Stop ends it."
    }

    /// The short form, for a run's row in the menu bar.
    public var tag: String {
        kind == "overloaded" ? "\(provider) overloaded · until \(untilText)" : "waiting for \(provider)’s limit · until \(untilText)"
    }

    /// What a parent conversation says of its sub-chats that wait (#343): one line per provider, kept up to date.
    public static func subChatsLine(_ waits: [LimitWait]) -> String? {
        guard !waits.isEmpty else { return nil }
        let groups = Dictionary(grouping: waits) { "\($0.provider)\u{0}\($0.kind)" }.values.sorted { $0.count > $1.count }
        let parts = groups.map { group -> String in
            let latest = group.max { $0.until < $1.until }!
            let count = group.count == 1 ? "1 sub-chat waits" : "\(group.count) sub-chats wait"
            if latest.kind == "overloaded" { return "\(count) for \(latest.provider), which is overloaded, until \(latest.untilText)" }
            return group.allSatisfy(\.told)
                ? "\(count) for \(latest.provider)’s limit until \(latest.untilText)"
                : "\(count) for \(latest.provider)’s limit, asking again by \(latest.untilText)"
        }
        return parts.joined(separator: "; ") + ". They carry on by themselves; Stop on a sub-chat ends its wait."
    }
}

public struct RunFailure: Codable, Equatable, Sendable {
    public let reason: String
    public let detail: String?

    public var message: String {
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

/// A message the person sent that the conversation does not show yet: on its way to the engine, or taken by it.
public struct OutgoingMessage: Equatable, Identifiable, Sendable {
    /// The request id it is sent with, which the engine uses to recognise it if it is sent again.
    public let id: String
    /// Its text, or what it carries when it is only attachments.
    public let summary: String
    /// The engine's id for it, once the engine has taken it.
    public var submission: Int?

    public init(id: String, summary: String, submission: Int? = nil) {
        self.id = id
        self.summary = summary
        self.submission = submission
    }
}

public struct QueuedInput: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let mode: String
    public let text: String
    public var attachments: [AttachmentNote]? = nil
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public let model: ModelRef?
    public let thinkingLevel: String?
    public let cwd: String?
    public let access: String
    public let agentId: String?
    /// Set for a subagent's conversation: the conversation that delegated to it.
    public let parent: Int?
}

/// One change made in a conversation of a project, as the conversation's state carries it (docs/projects.md, 3.12):
/// what changed, in the record's own words, whether it was undone and whether the person can undo it. Nil from an
/// engine older than projects, and for any conversation in no project.
public struct ProjectChangeLine: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let summary: String
    public let undone: Bool
    public let canUndo: Bool
    /// Why it has no Undo, in a few words; null for a change that has one.
    public let noUndo: String?
    /// When it was undone, in ms since 1970; null while it was not.
    public var undoneAt: Double? = nil
    /// The request whose allowing made this change (docs/projects.md, 3.12), for a change with no call of its own;
    /// null for any other.
    public var need: String? = nil
}

/// Whether an agent may use apps on this Mac: which ones, and whether it asks before acting.
public struct ComputerSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var apps: [String] = []
    public var ask = true
    /// Whether the agent may also use throwaway test copies of pi² (#146). Optional: agents saved before it have none.
    public var testCopies: Bool?

    public init(enabled: Bool = false, apps: [String] = [], ask: Bool = true, testCopies: Bool? = nil) {
        self.enabled = enabled
        self.apps = apps
        self.ask = ask
        self.testCopies = testCopies
    }
}

/// Whether an agent may browse the web in pi²'s own browser, and whether it asks before acting on a page.
public struct BrowserSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var ask = true

    public init(enabled: Bool = false, ask: Bool = true) {
        self.enabled = enabled
        self.ask = ask
    }
}

/// Whether an agent may set schedules for itself. You approve each one before it is set.
public struct ScheduleSettings: Codable, Equatable, Sendable {
    public var enabled = false

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

/// One of the built-in tools an agent's settings list, as the engine describes it (engine/src/builtins.ts).
public struct BuiltInTool: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let title: String
    public let detail: String
    /// Where it is offered at all: "files" (any access but none), "changes" (Ask first or Full access), "browser" (the
    /// browser on); nil for anywhere.
    public let needs: String?
    /// Off unless the agent turns it on (`toolsOn`), rather than on unless it leaves it out (`toolsOff`).
    public let offByDefault: Bool?
    public var id: String { key }
}

/// A file or folder an agent may always read, with a note on what it is for.
public struct ReferenceFile: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var note: String
    public var id: String { path }

    public init(path: String, note: String) {
        self.path = path
        self.note = note
    }
}

/// Shell commands an agent may run without asking, in one folder: those that start with `words`.
public struct CommandRule: Codable, Equatable, Identifiable, Sendable {
    public let folder: String
    public let words: [String]
    public let createdAt: Double
    public var id: String { folder + "\n" + command }
    public var command: String { words.joined(separator: " ") }
}

/// An environment variable of an agent's own: its name, and whether a value is kept for it. The value stays in the
/// Keychain and never comes to the app.
public struct AgentVariable: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let set: Bool
    public var id: String { name }
}

/// The template a project agent was made from, when it was copied, and the template's `updatedAt` then
/// (docs/projects.md, 3.3): what tells the board the template has changed since.
public struct TemplateMark: Codable, Equatable, Sendable {
    public let id: String
    public let copiedAt: Double
    public let templateUpdatedAt: Double
}

/// Which agent made this one through a tool, and in which conversation (docs/projects.md, 3.3).
public struct MadeByMark: Codable, Equatable, Sendable {
    public let agentId: String
    public let conversationId: Int
}

/// A saved setup that conversations start from.
public struct AgentProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var color: String
    public var model: ModelRef?
    public var thinkingLevel: String?
    public var instructions: String
    public var access: String
    public var cwd: String?
    /// Whether each conversation the person starts gets a git worktree of its own, made from `cwd`.
    public var worktree: Bool?
    /// A shell command run once in each new worktree of the agent's conversations. Empty for none.
    public var setup: String?
    public var delegates: [String]
    public var maxTurns: Int?
    public var codeMode: Bool?
    public var mcpServers: [String]?
    /// Files and folders every conversation of the agent may read.
    public var files: [ReferenceFile]?
    /// Whether the agent may use apps on this Mac, and which.
    public var computer: ComputerSettings?
    /// Whether the agent may browse the web in pi²'s own browser.
    public var browser: BrowserSettings?
    /// Whether the agent may set schedules for itself.
    public var schedule: ScheduleSettings?
    /// Keys of the built-in tools it is not offered, in the engine's order. Nil or empty: all of them.
    public var toolsOff: [String]?
    /// Keys of the built-in tools off by default that it is offered, in the engine's order. Nil or empty: none of them.
    public var toolsOn: [String]?
    /// The size in tokens at which its conversations' earlier messages are summarised; nil uses the default for all agents.
    public var compactionTokens: Int?
    /// Commands it may run without asking. Changed through their own requests, never by saving the agent.
    public var commandRules: [CommandRule]?
    /// Variables its commands get. Changed through their own requests, never by saving the agent.
    public var variables: [AgentVariable]?
    /// Allow everything: nothing is asked about and any app may be used. Changed only through `agents.allowEverything`,
    /// after a confirmation, never by saving the agent, and not copied to a duplicate.
    public var allowEverything: Bool?
    public var createdAt: Double
    /// The project it belongs to (docs/projects.md, 3.3). Nil for a template, kept under Shared to make a project's agents from.
    /// Kept as stored by the engine, whatever `agents.save` is sent.
    public var projectId: String? = nil
    /// "orchestrator" for a project's orchestrator.
    public var role: String? = nil
    /// A copy: the template it was made from, when, and the template's `updatedAt` then. Kept as stored (3.3).
    public var template: TemplateMark? = nil
    /// Made by an agent through a tool (the board's mark): which agent, in which conversation. Absent: made by the
    /// person or by carrying over. Kept as stored.
    public var madeBy: MadeByMark? = nil
    /// When it was last saved; read as `createdAt` when absent (3.3).
    public var updatedAt: Double? = nil
    /// Removed through a tool (3.3): kept whole for Undo, offered to nobody, and put back by `agents.restore`.
    public var removedAt: Double? = nil

    /// What the engine's `agents.save` takes. Nulls are sent, so clearing a field clears it.
    public var payload: [String: Any] {
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
            "toolsOn": toolsOn ?? [],
            "compactionTokens": compactionTokens as Any? ?? NSNull(),
        ]
    }

    /// The agent as `agents.save` would store it: missing settings filled with their defaults and text tidied the way
    /// the engine tidies it. Rules are left out, since saving never changes them. Two agents that are the same here
    /// save the same, so the editor compares these to tell whether there is anything to save. The starter agents are
    /// made without most of the optional settings, and saving fills them in.
    public var asSaved: AgentProfile {
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
        agent.toolsOn = toolsOn ?? []
        agent.commandRules = nil
        agent.variables = nil
        agent.allowEverything = nil
        return agent
    }
}

/// Something a run is waiting on the person for: approval of a tool call, or an answer to a question.
public struct InboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let conversationId: Int
    public let callId: String
    public let tool: String
    public let arguments: JSONValue
    public let question: String?
    /// For a browser action: the site it would act on, which is what "always allow" then covers.
    public var site: String? = nil
    /// For a schedule an agent asks to set: when it would run, in words.
    public var when: String? = nil
    /// For a command: the rule the engine offers to make of it. Answering "rule" makes this rule; nothing else is sent.
    public var rule: RuleOffer? = nil
    /// For an approval a project's switch asked for: the switch's name (docs/projects.md, 8.1). Only Allow Once and Deny
    /// answer it: the asking is the project's setting, and the conversation cannot change it.
    public var projectSwitch: String? = nil
    /// For a command: it would be started and left running in the background, so the card says so.
    public var background: Bool? = nil
    public let title: String
    public let agentName: String?
    /// The conversation in the sidebar this belongs to; differs from `conversationId` for a subagent.
    public let rootConversationId: Int
    /// The engine's mark of an approval whose call it partly kept from a device (#776; iphone.md 5.7): a key masked as
    /// `[key hidden]`, or a value nested too deep to send, which leaves nothing in the call a phone could notice. Such
    /// an approval can be allowed only on the Mac; a phone reads this and offers Deny only. False, and the key absent,
    /// when nothing was hidden, so every older recording decodes as before.
    public var partHidden: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, kind, conversationId, callId, tool, arguments, question, site, when, rule, projectSwitch, background
        case title, agentName, rootConversationId, partHidden
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        conversationId = try values.decode(Int.self, forKey: .conversationId)
        callId = try values.decode(String.self, forKey: .callId)
        tool = try values.decode(String.self, forKey: .tool)
        arguments = try values.decode(JSONValue.self, forKey: .arguments)
        question = try values.decodeIfPresent(String.self, forKey: .question)
        site = try values.decodeIfPresent(String.self, forKey: .site)
        when = try values.decodeIfPresent(String.self, forKey: .when)
        rule = try values.decodeIfPresent(RuleOffer.self, forKey: .rule)
        projectSwitch = try values.decodeIfPresent(String.self, forKey: .projectSwitch)
        background = try values.decodeIfPresent(Bool.self, forKey: .background)
        title = try values.decode(String.self, forKey: .title)
        agentName = try values.decodeIfPresent(String.self, forKey: .agentName)
        rootConversationId = try values.decode(Int.self, forKey: .rootConversationId)
        // The engine marks only an approval it hid part of, so the key is missing from every older recording, and a
        // value that is not `true` counts as no mark.
        partHidden = (try? values.decodeIfPresent(Bool.self, forKey: .partHidden)) ?? false
    }

    /// The item as the page and a phone read it, with the mark written only when there is one: what every older
    /// recording and reader holds stays as it was.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(conversationId, forKey: .conversationId)
        try values.encode(callId, forKey: .callId)
        try values.encode(tool, forKey: .tool)
        try values.encode(arguments, forKey: .arguments)
        try values.encodeIfPresent(question, forKey: .question)
        try values.encodeIfPresent(site, forKey: .site)
        try values.encodeIfPresent(when, forKey: .when)
        try values.encodeIfPresent(rule, forKey: .rule)
        try values.encodeIfPresent(projectSwitch, forKey: .projectSwitch)
        try values.encodeIfPresent(background, forKey: .background)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(agentName, forKey: .agentName)
        try values.encode(rootConversationId, forKey: .rootConversationId)
        if partHidden { try values.encode(true, forKey: .partHidden) }
    }

    public var call: ToolCall { ToolCall(callId: callId, name: tool, arguments: arguments) }
}

/// The rule an approval for a command offers: commands that start with `words`, in `folder`.
public struct RuleOffer: Codable, Equatable, Sendable {
    public let words: [String]
    public let folder: String
    /// The rule is kept for a repository's main checkout, so it also holds in the worktrees pi² makes from it.
    public var worktrees: Bool? = nil
    public var command: String { words.joined(separator: " ") }
    /// How the approval's button ends, after the command: "Here", or "in This Repository" when the rule also holds in
    /// the repository's main checkout and its pi² worktrees. The conversation page says the same (`ruleOffer` in tools.js).
    public var place: String { worktrees == true ? "in This Repository" : "Here" }
}

/// A command an agent left running in the background, as the Activity view lists it.
public struct BackgroundCommand: Codable, Equatable, Identifiable, Sendable {
    /// "bg-3": what the agent and the transcript call it.
    public let id: String
    public let conversationId: Int
    /// The conversation in the sidebar it belongs to; differs from `conversationId` for a sub-chat's command.
    public let rootConversationId: Int
    public let command: String
    /// The folder it was started in.
    public let cwd: String
    public let startedAt: Double
}

/// Something that will wake a conversation's agent when it ends: a sub-chat handed work without waiting, or a background
/// command started with `wake`. Or one that has ended and waits for the agent to stop answering (docs/wakes.md).
public struct WakeItem: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    /// The conversation that will be woken.
    public let conversationId: Int
    /// "subchat" or "background".
    public let kind: String
    /// The sub-chat's number, or the command's id.
    public let ref: String
    /// For a sub-chat of a project's orchestrator, when its report wakes it and the batch it belongs to
    /// (docs/projects.md, 4.3). Absent from an engine older than these fields.
    public var wake: String?
    public var batch: String?
    /// "sub-chat 12 “Fix login”", "background command bg-3 (`npm test`)".
    public let label: String
    public let startedAt: Double
    /// "running", or "arrived": over, and waiting to be handed to the agent.
    public let state: String
    public var id: String { key }
}

/// Why a conversation's agent is not woken for now: "stopped" (the person's Stop), "cap" (woken too often this hour,
/// until `until`) or "budget".
public struct WakeHold: Codable, Equatable, Sendable {
    public let conversationId: Int
    public let why: String
    public let until: Double?
}

/// A background command and the output of it the engine keeps, as the person reads it (`background.output`).
public struct BackgroundOutput: Decodable, Equatable, Sendable {
    public struct Ended: Decodable, Equatable, Sendable {
        /// Worded to follow "It": "exited with code 1 after 4 seconds".
        public let how: String
        public let failed: Bool
    }

    public let conversationId: Int
    public let rootConversationId: Int
    public let command: String
    public let cwd: String
    public let startedAt: Double
    public let running: Bool
    /// Asked to stop, and not yet over.
    public let stopping: Bool
    public let ended: Ended?
    /// False for a command an engine that stopped had started: its output went with that engine.
    public let kept: Bool
    /// Characters it has printed in all, counted as the engine counts them (UTF-16 units). The next request starts here.
    public let total: Int
    /// Where `output` begins, counted from the first character it printed.
    public let from: Int
    /// Characters printed after the point asked for that were not kept.
    public let dropped: Int
    public let output: String
}

/// A conversation with work in flight, as the Activity view lists it.
public struct ActivityRun: Codable, Equatable, Identifiable, Sendable {
    public let conversationId: Int
    public let parent: Int?
    public let rootConversationId: Int
    public let title: String
    public let agentId: String?
    public let status: String
    public let since: Double
    /// Set while the run waits for a provider's limit; nil otherwise, and from an engine older than this field.
    public let limit: LimitWait?
    /// Its shell commands running in the foreground, oldest first, with their clocks (#196). Absent from an older engine.
    public var commands: [RunningCommand]?
    /// A chat answering, rather than an agent's work (docs/chat.md).
    public var chat: Bool?
    /// The project its conversation belongs to, and the agent it runs as (docs/projects.md, 4.3).
    public var projectId: String?
    public var runsAs: String?
    /// The last line of text its agent wrote, at most 140 characters, or nil from an engine older than this field
    /// (docs/projects.md, 4.3): the Now tab's "working" row.
    public var lastLine: String?
    public var id: Int { conversationId }
}

/// A shell command running in the foreground: what it runs, when it started and when it last printed, in ms since 1970.
public struct RunningCommand: Codable, Equatable, Sendable {
    public let command: String
    public let startedAt: Double
    public let lastOutputAt: Double?

    /// A command shows how long it has been quiet only after this long, so a busy one's row is still.
    public static let quietAfter: TimeInterval = 30

    /// "45s", "3m 12s", "1h 4m", as the conversation page writes them.
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// How long it has run at `now`.
    public func elapsed(at now: Date) -> String { Self.short(now.timeIntervalSince1970 - startedAt / 1000) }

    /// "quiet for 45s" once it has printed nothing for `quietAfter`, else nil.
    public func quiet(at now: Date) -> String? {
        let since = max(startedAt, lastOutputAt ?? startedAt) / 1000
        let seconds = now.timeIntervalSince1970 - since
        return seconds >= Self.quietAfter ? "quiet for \(Self.short(seconds))" : nil
    }
}

public struct Repeat: Codable, Equatable, Sendable {
    public var kind: String
    public var at: Double?
    public var minutes: Int?
    public var hour: Int?
    public var minute: Int?
    public var weekday: Int?

    public var payload: [String: Any] {
        switch kind {
        case "once": ["kind": kind, "at": at ?? 0]
        case "interval": ["kind": kind, "minutes": minutes ?? 60]
        case "weekly": ["kind": kind, "weekday": weekday ?? 1, "hour": hour ?? 9, "minute": minute ?? 0]
        default: ["kind": "daily", "hour": hour ?? 9, "minute": minute ?? 0]
        }
    }

    public var summary: String {
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

    public init(kind: String, at: Double? = nil, minutes: Int? = nil, hour: Int? = nil, minute: Int? = nil, weekday: Int? = nil) {
        self.kind = kind
        self.at = at
        self.minutes = minutes
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }
}

public struct Schedule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var agentId: String
    public var prompt: String
    public var `repeat`: Repeat
    public var enabled: Bool
    public var holdReason: String?
    public var nextRunAt: Double?
    public var lastConversationId: Int?
    /// Set when an agent made it, with your approval; nil when you did. Only the engine sets it.
    public var createdBy: Creator?
    /// For a schedule on a template carried over: the project's copy of it, which it runs as
    /// (docs/projects.md, 3.13; `EngineClient.runsAs`). Only the engine sets it.
    public var projectAgentId: String? = nil

    public struct Creator: Codable, Equatable, Sendable {
        public let agentId: String
        public let conversationId: Int
    }

    public func payload(isNew: Bool) -> [String: Any] {
        var result: [String: Any] = ["title": title, "agentId": agentId, "prompt": prompt, "repeat": `repeat`.payload, "enabled": enabled]
        if !isNew { result["id"] = id }
        return result
    }

    public init(id: String, title: String, agentId: String, prompt: String, repeat: Repeat, enabled: Bool, holdReason: String? = nil, nextRunAt: Double? = nil, lastConversationId: Int? = nil, createdBy: Creator? = nil, projectAgentId: String? = nil) {
        self.id = id
        self.title = title
        self.agentId = agentId
        self.prompt = prompt
        self.`repeat` = `repeat`
        self.enabled = enabled
        self.holdReason = holdReason
        self.nextRunAt = nextRunAt
        self.lastConversationId = lastConversationId
        self.createdBy = createdBy
        self.projectAgentId = projectAgentId
    }
}

/// What an engine that started after an unclean stop found and resumed.
public struct RecoveryReport: Codable, Equatable, Sendable {
    public struct Resumed: Codable, Equatable, Identifiable, Sendable {
        public let id: Int
        public let title: String
    }
    /// A command an agent had left running in the background, and what the new engine did about it.
    public struct LeftCommand: Codable, Equatable, Identifiable, Sendable {
        /// "bg-3".
        public let id: String
        public let conversationId: Int
        /// The conversation in the sidebar it belongs to, and its title; differs from `conversationId` for a sub-chat's command.
        public let rootConversationId: Int
        public let title: String
        public let command: String
        /// "stopped", "partly" (what carried the run's marker was stopped, the rest left), "gone" (it had ended), "unsure"
        /// (left alone, as pi² could not tell it was the same) or "unknown" (left alone: its process had not been noted yet).
        public let outcome: String
        public let group: Int?
    }
    /// A worktree's set-up command that was running, and what the new engine did about it. One per conversation at most.
    public struct LeftSetup: Codable, Equatable, Identifiable, Sendable {
        public var id: Int { conversationId }
        public let conversationId: Int
        public let rootConversationId: Int
        public let title: String
        public let command: String
        /// As for `LeftCommand`, but for "unknown": a set-up whose process was not noted yet counts as "gone".
        public let outcome: String
        public let group: Int?
    }
    public let at: Double
    public let conversations: [Resumed]
    /// Absent from an engine older than this app.
    public let background: [LeftCommand]?
    public let setups: [LeftSetup]?
}

public enum AccessLevel: Sendable {
    public static let all: [(id: String, title: String, detail: String)] = [
        ("none", "Off", "Chat only"),
        ("read", "Read files", "Can read files in its folder"),
        ("ask", "Ask first", "Can edit files and run commands after you approve each one"),
        ("full", "Full access", "Edits files and runs commands without asking"),
    ]
}

public struct ConversationState: Codable, Equatable, Sendable {
    public let busy: Bool
    public let partial: PartialAnswer?
    public let retry: RetryInfo?
    /// Set while the run waits for a provider's limit; nil otherwise, and from an engine older than this field.
    public let limitWait: LimitWait?
    public let tools: [LiveTool]
    public let failure: RunFailure?
    public let queued: [QueuedInput]
    public let agent: AgentInfo
    public let usage: Spend
    public let context: ContextSize
    public let compacting: Bool
    public let compactionError: String?
    public var compactionErrorId: Int? = nil
    /// What the last request to the model read, in tokens (input and the prompt cache, not the answer). Nil when it is not
    /// known, and from an engine older than this field.
    public var lastRequestInputTokens: Int? = nil
    /// The agent's task list; nil when it keeps none.
    public let plan: TaskList?
    /// The nearest project instructions file (AGENTS.md or CLAUDE.md) in effect, if there is one.
    public let projectInstructions: String?
    /// Every project instructions file in effect: in the conversation's folder and the folders above it up to the top of its
    /// git repository, the outermost first. Nil from an engine older than this field.
    public let projectInstructionFiles: [ProjectInstructionsFile]?
    /// The conversation's title, for one that is not in the sidebar's list (an archived one, or its sub-chat).
    public let title: String?
    /// It, or the conversation it is a sub-chat of, is archived: it can be read but not continued.
    public let archived: Bool?
    /// The agent's set-up command running in the conversation's new worktree, with what it has printed so far. Nil when
    /// none is running, and from an engine older than this field.
    public let setup: LiveSetup?
    /// Its model runs on this Mac: whether it is loading, loaded, stopped or could not start. Nil for any other model,
    /// and from an engine older than this field.
    public let local: LocalModelState?
    /// A chat with pi²'s own assistant (docs/chat.md). Nil from an engine older than chat mode.
    public var chat: Bool? = nil
    /// A chat's web switch (#287): whether its next message may search the web and read pages. Nil for any other
    /// conversation, and from an engine older than the switch.
    public var web: Bool? = nil
    /// While it works: what a message sent to steer it now would wait for, and which waits it would end. Nil when idle,
    /// and from an engine older than this field.
    public var messageWaits: MessageWaits? = nil
    /// Where the versions of what is shown part, and which is shown (Try Again and Edit). Nil where versions are not
    /// offered: an agent's conversation, or an engine older than this field.
    public var versions: [VersionPoint]? = nil
    /// The changes made in this conversation by its project's agents, oldest first (docs/projects.md, 3.12), each drawn
    /// where the tool call that made it is. Nil in no project, and from an engine older than this field.
    public var projectChanges: [ProjectChangeLine]? = nil
}

/// What a message sent to steer a working agent waits for (engine/src/heed.ts): `holds`, the calls it comes after, such
/// as "the command `npm test`"; and `ends`, the waits it ends at once, such as "the wait for Scout's sub-chat 12".
public struct MessageWaits: Codable, Equatable, Sendable {
    public let holds: [String]
    public let ends: [String]
    /// Set while the run waits to ask the model again (a retry, or a provider's limit): a message sent to steer is placed
    /// when it does, so that request carries it (#324). Ms since 1970; absent from an engine older than this field.
    public var retryAt: Double? = nil

    private static func joined(_ parts: [String]) -> String {
        ListFormatter.localizedString(byJoining: parts)
    }

    /// What happens to a message sent now, in a line for the message field: steered, or queued until the answer.
    /// `limit` is the provider's limit the run waits for, if it does.
    public func sentence(agent: String, steer: Bool, limit: LimitWait? = nil) -> String {
        if let limit {
            // It cannot be answered before the limit resets, and does not end the wait: the provider would only refuse it.
            let wait = limit.kind == "overloaded" ? "\(limit.provider) to stop being overloaded" : "\(limit.provider)’s limit"
            guard steer else { return "\(agent) reads this once it has answered, after the wait for \(wait) at \(limit.untilText)." }
            return "\(agent) reads this after the wait for \(wait), at \(limit.untilText); until then you can take it back."
        }
        guard steer else { return "\(agent) reads this once it has answered." }
        if let retryAt, holds.isEmpty, ends.isEmpty {
            return "\(agent) reads this when it asks the model again, at \(Date(timeIntervalSince1970: retryAt / 1000).formatted(date: .omitted, time: .standard))."
        }
        let ended = ends.isEmpty ? "" : " It ends \(Self.joined(ends)); \(ends.count == 1 ? "that work carries on" : "the work carries on")."
        if holds.isEmpty {
            return ends.isEmpty ? "\(agent) reads this after its current step." : "\(agent) reads this at once.\(ended)"
        }
        return "\(agent) reads this once \(Self.joined(holds)) \(holds.count == 1 ? "has" : "have") finished.\(ended)"
    }

    /// What a message already sent to steer is waiting for, for its chip; nil when it is only waiting for the current step.
    public var waitingFor: String? {
        holds.isEmpty ? nil : Self.joined(holds)
    }
}

/// A point where a chat's versions part: after entry `after` (nil: before the first message), version `index` of `count`.
public struct VersionPoint: Codable, Equatable, Sendable {
    public let after: Int?
    public let index: Int
    public let count: Int

    private enum CodingKeys: String, CodingKey { case after, index, count }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        after = try container.decodeIfPresent(Int.self, forKey: .after)
        index = try container.decode(Int.self, forKey: .index)
        count = try container.decode(Int.self, forKey: .count)
    }

    /// `after` as null when there is none: the page tells "before the first message" from a missing field.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(after, forKey: .after)
        try container.encode(index, forKey: .index)
        try container.encode(count, forKey: .count)
    }
}

/// A worktree set-up command still running: which run it is (its transcript entry's `details.run`) and the end of its output.
public struct LiveSetup: Codable, Equatable, Sendable {
    public let run: String
    public let output: String
}

/// One project instructions file in effect for a conversation: its name, and the real path of the folder it is in.
public struct ProjectInstructionsFile: Codable, Equatable, Sendable {
    public let folder: String
    public let file: String
}

/// The task list an agent keeps for a conversation (`update_plan`). `updatedAt` tells one version of it from the next.
public struct TaskList: Codable, Equatable, Sendable {
    public let items: [TaskItem]
    public let updatedAt: Double

    public var doneCount: Int { items.filter { $0.state == .completed }.count }
    public var isFinished: Bool { !items.isEmpty && doneCount == items.count }
    /// The step in hand, or the next one waiting.
    public var current: TaskItem? { items.first { $0.state == .inProgress } ?? items.first { $0.state == .pending } }
}

public struct TaskItem: Codable, Equatable, Sendable {
    public enum Step: Sendable { case pending, inProgress, completed

        public var words: String {
            switch self {
            case .pending: "to do"
            case .inProgress: "in progress"
            case .completed: "done"
            }
        }
    }

    public let content: String
    public let status: String

    public var state: Step { status == "completed" ? .completed : (status == "in_progress" ? .inProgress : .pending) }
}

public struct Spend: Codable, Equatable, Sendable {
    public let cost: Double
    public let tokens: Int

    public var costText: String { Formats.cost(cost) }
    public var tokensText: String { Formats.tokens(tokens) }
}

/// How full a conversation's context is. `window` is nil when the model's size is not known.
public struct ContextSize: Codable, Equatable, Sendable {
    public let used: Int
    public let window: Int?

    public var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}

public enum Formats: Sendable {
    public static func cost(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        return value < 0.01 ? "< $0.01" : String(format: "$%.2f", value)
    }

    /// Tokens, with the cost only when there is one: subscription and local use has no price.
    public static func usage(tokens: Int, cost: Double) -> String {
        cost > 0 ? "\(Formats.tokens(tokens)) · \(Formats.cost(cost))" : "\(Formats.tokens(tokens)) tokens"
    }

    public static func tokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}

/// Spend across the whole app, as the engine summarises it.
public struct UsageSummary: Codable, Equatable, Sendable {
    public struct ModelRow: Codable, Equatable, Identifiable, Sendable {
        public let key: String
        public let tokens: Int
        public let cost: Double
        /// Paid for by a subscription sign-in, so there is no per-use cost to show.
        public var subscription: Bool? = nil
        /// Some or all of the use had no known price: the tokens are counted, the cost is not.
        public var unpriced: Bool? = nil
        /// Picture models are in a different catalog from the models that answer in a conversation.
        public var pictureName: String? = nil
        /// A model that looked at pictures for one that cannot see them (#540): its own spend, apart from its answers.
        public var lookName: String? = nil
        public var id: String { pictureName == nil && lookName == nil ? key : "extra:\(pictureName ?? lookName ?? key)" }
    }
    public struct AgentRow: Codable, Equatable, Identifiable, Sendable {
        public let agentId: String
        public let cost: Double
        public let tokens: Int
        public var id: String { agentId }
    }
    /// Today's spending of one project (docs/projects.md, 4.3), as the board's Settings tab reads of its limits (#478).
    public struct ProjectSpend: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let today: Spend
    }
    public struct ConversationRow: Codable, Equatable, Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let cost: Double
        public let tokens: Int
    }
    public struct Day: Codable, Equatable, Identifiable, Sendable {
        public let day: String
        public let cost: Double
        public let tokens: Int
        public var id: String { day }
    }
    public struct Budget: Codable, Equatable, Sendable {
        public let daily: Double?
    }
    public let models: [ModelRow]
    public let agents: [AgentRow]
    public var projects: [ProjectSpend]? = nil
    public let conversations: [ConversationRow]
    public let total: Spend
    public let today: Spend
    public let days: [Day]
    public let budget: Budget
    public let overBudget: Bool
}

public struct McpServer: Codable, Equatable, Identifiable, Sendable {
    public struct Tool: Codable, Equatable, Identifiable, Sendable {
        public let name: String
        public let toolName: String
        public var id: String { toolName }
    }
    public let id: String
    public let name: String
    public let transport: String
    public let command: String?
    public let args: [String]?
    public let url: String?
    /// A server run as a program: its own environment variables, by name. The values stay in the Keychain.
    public let variables: [AgentVariable]?
    public let status: String
    public let error: String?
    public let tools: [Tool]
}

public struct SearchResult: Codable, Equatable, Identifiable, Sendable {
    public let conversationId: Int
    public let title: String
    public let entryId: Int
    public let snippet: String
    /// Found in an archived conversation.
    public let archived: Bool?
    /// Found in a chat rather than an agent's conversation.
    public var chat: Bool? = nil
    public var id: Int { entryId }
}

/// The latest event of each kind that a feature in a file of its own reads, by kind ("limits", "memory"). Each kind is
/// observed on its own, so a view that reads one is not drawn again when another comes, and a value is only set when it
/// changed (#347).
@MainActor
public final class ExtraEvents {
    @MainActor
    @Observable
    public final class Slot {
        public var value: JSONValue?
    }

    private var slots: [String: Slot] = [:]
    /// How many times each kind has changed, for a reading of it worked out once per change rather than at every look
    /// (`WorkListings`, #599). Not observed: what reads it reads the value too.
    private var generations: [String: Int] = [:]

    public func generation(_ kind: String) -> Int { generations[kind] ?? 0 }

    private func slot(_ kind: String) -> Slot {
        if let slot = slots[kind] { return slot }
        let slot = Slot()
        slots[kind] = slot
        return slot
    }

    public subscript(kind: String) -> JSONValue? {
        get { slot(kind).value }
        set {
            let slot = slot(kind)
            if slot.value != newValue {
                slot.value = newValue
                generations[kind, default: 0] += 1
            }
        }
    }

    public init() {}
}

public struct EndpointModel: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String? = nil
    public var contextWindow: Int? = nil
    public var reasoning: Bool? = nil
    /// Whether the person marked the model as able to see pictures.
    public var vision: Bool? = nil

    /// What the engine's `endpoints.save` takes; fields that are not set are left out.
    public var payload: [String: Any] {
        var result: [String: Any] = ["id": id]
        if let name { result["name"] = name }
        if let contextWindow { result["contextWindow"] = contextWindow }
        if let reasoning { result["reasoning"] = reasoning }
        if vision == true { result["vision"] = true }
        return result
    }

    public init(id: String, name: String? = nil, contextWindow: Int? = nil, reasoning: Bool? = nil, vision: Bool? = nil) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.reasoning = reasoning
        self.vision = vision
    }
}

public struct EndpointConfig: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseUrl: String
    public let api: String
    public let models: [EndpointModel]
}

public struct ProviderInfo: Codable, Identifiable, Equatable, Sendable {
    public struct OAuth: Codable, Equatable, Sendable {
        public let name: String
        public let subscription: Bool
    }
    public struct Status: Codable, Equatable, Sendable {
        public let type: String
        public let source: String?
    }
    public let id: String
    public let name: String
    public let kind: String
    public let keyAuth: Bool
    public let oauth: OAuth?
    public let status: Status?
    public let modelCount: Int
    public let endpoint: EndpointConfig?
    /// Whether a signed-in or keyed built-in provider can be asked which models it offers, where, or why not.
    public var ask: Ask? = nil

    public struct Ask: Codable, Equatable, Sendable {
        public let can: Bool
        /// The address asked; nil for a provider whose list the library refreshes itself.
        public var url: String? = nil
        public var why: String? = nil
    }

    public var statusText: String {
        guard let status else { return "Not connected" }
        if status.type == "oauth" { return "Signed in" }
        if let source = status.source, source != "stored credential" { return "Using \(source)" }
        return "Key saved"
    }
}

public struct ModelInfo: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let providerName: String
    public let id: String
    public let name: String
    public let thinkingLevels: [String]
    /// Left out of the model pickers by the choice made in Settings.
    public var hidden: Bool? = nil
    /// Whether the model can be sent pictures. Nil from an engine that does not say.
    public var vision: Bool? = nil
    /// Added by its id to a built-in provider whose list pi² has does not have it yet (Settings › Providers › Models…).
    public var addedByHand: Bool? = nil

    public var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
    /// The name as a model menu lists it, marked when it was added by hand.
    public var listName: String { addedByHand == true ? "\(name) (added by hand)" : name }
}

/// What a provider said when asked which models its key or sign-in can use (`providers.ask`).
public struct ProviderListing: Codable, Equatable, Sendable {
    public struct Listed: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        /// In pi²'s own list of the provider's models.
        public let known: Bool
    }
    public let providerName: String
    public let asked: String?
    public let catalogCount: Int
    public let models: [Listed]
}

/// What the engine's `providers.draftModel` proposes for a model added by its id: settings taken from a model it knows.
public struct ModelDraft: Codable, Equatable, Sendable {
    public struct Template: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
    }
    public let providerName: String
    public let id: String
    public var name: String
    public let basedOn: String
    public let basedOnName: String
    /// "family": the newest of the id's family; "nearest": no model of that family, so the closest; "chosen": picked.
    public let match: String
    /// What the provider said itself when asked ("context size", "pictures"), in place of the template's.
    public var told: [String]? = nil
    public let api: String
    public let apis: [String]
    public var contextWindow: Int
    public var maxTokens: Int
    public var vision: Bool
    public var thinkingLevels: [String]
    public let templates: [Template]
    public let editing: Bool
}

/// What a sign-in flow tells or asks the person, as pi-ai's provider-neutral events and prompts.
public struct AuthNotice: Codable, Equatable, Sendable {
    public let type: String
    public let message: String?
    public let url: String?
    public let instructions: String?
    public let userCode: String?
    public let verificationUri: String?
}

public struct AuthPromptInfo: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let description: String?
    }
    public let type: String
    public let message: String
    public let placeholder: String?
    public let options: [Option]?
}

public struct SignInFlow: Equatable, Sendable {
    public var loginId: String?
    public let providerName: String
    public var messages: [String] = []
    public var openURL: String?
    public var userCode: String?
    public var promptId: String?
    public var prompt: AuthPromptInfo?
    public var error: String?
    public var finished = false

    public init(loginId: String? = nil, providerName: String, messages: [String] = [], openURL: String? = nil, userCode: String? = nil, promptId: String? = nil, prompt: AuthPromptInfo? = nil, error: String? = nil, finished: Bool = false) {
        self.loginId = loginId
        self.providerName = providerName
        self.messages = messages
        self.openURL = openURL
        self.userCode = userCode
        self.promptId = promptId
        self.prompt = prompt
        self.error = error
        self.finished = finished
    }
}

public struct EngineError: LocalizedError, Sendable {
    public let message: String
    /// No answer came: the engine was not connected, or the connection went before it answered. A request that is safe to
    /// send again (a message with its request id) can be sent again once the engine is back.
    public var unanswered = false
    /// What a refusal carries beside its message (docs/projects.md, 4.1): the new report of a plan that changed since the
    /// person looked, say. Nil for most refusals.
    public var data: [String: JSONValue]? = nil
    public var errorDescription: String? { message }

    public init(message: String, unanswered: Bool = false, data: [String: JSONValue]? = nil) {
        self.message = message
        self.unanswered = unanswered
        self.data = data
    }
}
