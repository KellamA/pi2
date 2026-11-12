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
}

struct AgentInfo: Codable, Equatable {
    let model: ModelRef?
    let thinkingLevel: String?
    let cwd: String?
    let access: String
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
}

struct ConversationData: Equatable {
    var items: [Item] = []
    var state: ConversationState?
}

struct EndpointModel: Codable, Equatable, Hashable {
    let id: String
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
