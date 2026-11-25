import Foundation

// What an agent's `present` call showed, as the engine stores it in a conversation's `pi2.presented` document and sends
// it in `presented.list` and `conversation.presented` (docs/design/presenting.md, "What is stored"; engine/src/presented.ts).
// Fields the app does not know are ignored; a record it cannot read is left out of a list rather than failing it
// (`PresentationRecord.list`), so a later engine's shape never takes the others down.

/// One presentation of a conversation: "p2", with every version an agent presented under that id, oldest first.
public struct PresentationRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let versions: [PresentedVersion]

    public init(id: String, versions: [PresentedVersion]) {
        self.id = id
        self.versions = versions
    }

    /// A version by its number.
    public func version(_ number: Int) -> PresentedVersion? { versions.first { $0.version == number } }
    /// The newest version.
    public var latest: PresentedVersion? { versions.max { $0.version < $1.version } }

    /// A list of records as the engine sends one (`presented.list`'s `items`): each it cannot read is left out.
    public static func list(from value: Data, key: String = "items") -> [PresentationRecord] {
        guard let decoded = try? JSONDecoder().decode([String: Lossy].self, from: value) else { return [] }
        return decoded[key]?.records ?? []
    }

    /// Whether `id` is a presentation's id as the engine makes them: "p" and a whole number from 1.
    public static func isID(_ id: String) -> Bool {
        let digits = Array(id.utf8.dropFirst())
        return id.hasPrefix("p") && (1...9).contains(digits.count) && digits[0] != UInt8(ascii: "0")
            && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// Decodes a list element by element, keeping those that decode.
    private struct Lossy: Decodable {
        var records: [PresentationRecord] = []
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                if let record = try? container.decode(PresentationRecord.self) { records.append(record) }
                else { _ = try? container.decode(JSONValue.self) }
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard Self.isID(id) else { throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "not a presentation's id") }
        versions = try container.decode([PresentedVersion].self, forKey: .versions)
    }

    private enum CodingKeys: String, CodingKey { case id, versions }
}

/// One version of a presentation: what one `present` call showed.
public struct PresentedVersion: Codable, Equatable, Sendable {
    public let version: Int
    /// The call that presented it: the transcript draws that call's card from this version.
    public let callId: String
    /// Milliseconds since 1970.
    public let createdAt: Double
    public let title: String
    public let items: [PresentedItem]
    public let question: PresentedQuestion?
    /// The person's "Allow network for this page", for this version's pages alone, and each change of it with when.
    public let network: PresentedNetwork

    public init(version: Int, callId: String, createdAt: Double, title: String, items: [PresentedItem], question: PresentedQuestion?, network: PresentedNetwork) {
        self.version = version
        self.callId = callId
        self.createdAt = createdAt
        self.title = title
        self.items = items
        self.question = question
        self.network = network
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        callId = try container.decode(String.self, forKey: .callId)
        createdAt = try container.decode(Double.self, forKey: .createdAt)
        title = try container.decode(String.self, forKey: .title)
        items = try container.decode([PresentedItem].self, forKey: .items)
        question = try container.decodeIfPresent(PresentedQuestion.self, forKey: .question)
        // A record from before the switch was stored reads as off, which is what it was.
        network = try container.decodeIfPresent(PresentedNetwork.self, forKey: .network) ?? PresentedNetwork(allowed: false, changes: [])
        guard version >= 1 else { throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "a version is a whole number from 1") }
    }

    private enum CodingKeys: String, CodingKey { case version, callId, createdAt, title, items, question, network }
}

public struct PresentedNetwork: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public let allow: Bool
        /// Milliseconds since 1970.
        public let at: Double

        public init(allow: Bool, at: Double) {
            self.allow = allow
            self.at = at
        }
    }

    public let allowed: Bool
    /// The newest 100 changes, oldest first.
    public let changes: [Change]

    public init(allowed: Bool, changes: [Change]) {
        self.allowed = allowed
        self.changes = changes
    }
}

/// One picture or page of a version.
public struct PresentedItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case picture, page }

    public let label: String
    public let caption: String?
    public let kind: Kind
    /// The path as the agent gave it.
    public let name: String
    /// "image/png", …, "image/svg+xml"; "text/html" for a page.
    public let mimeType: String
    /// A picture's blob, or a page's manifest.
    public let sha256: String
    public let bytes: Int
    public let files: Int
    /// A picture's pixels; a page's drawn size in CSS pixels, nil until drawn.
    public let width: Int?
    public let height: Int?
    /// A page's picture as drawn; nil for a picture.
    public let snapshot: PresentedSnapshot?
    /// What drawing a page found, as the agent was told; nil for a picture, and for a page not drawn yet.
    public let drawn: PresentedDrawn?

    public init(label: String, caption: String?, kind: Kind, name: String, mimeType: String, sha256: String, bytes: Int, files: Int, width: Int?, height: Int?, snapshot: PresentedSnapshot?, drawn: PresentedDrawn?) {
        self.label = label
        self.caption = caption
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.sha256 = sha256
        self.bytes = bytes
        self.files = files
        self.width = width
        self.height = height
        self.snapshot = snapshot
        self.drawn = drawn
    }
}

/// A page's snapshot: drawn, with its blob; pending while no app has drawn it; or failed, with why.
public enum PresentedSnapshot: Codable, Equatable, Sendable {
    case drawn(sha256: String)
    case pending
    case failed(reason: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .state) {
        case "drawn": self = .drawn(sha256: try container.decode(String.self, forKey: .sha256))
        case "pending": self = .pending
        case "failed": self = .failed(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        default: throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "an unknown state")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .drawn(let sha256):
            try container.encode("drawn", forKey: .state)
            try container.encode(sha256, forKey: .sha256)
        case .pending:
            try container.encode("pending", forKey: .state)
        case .failed(let reason):
            try container.encode("failed", forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }

    public var isDrawn: Bool { if case .drawn = self { true } else { false } }

    private enum CodingKeys: String, CodingKey { case state, sha256, reason }
}

/// What drawing a page found: how long it took to load, whether it was blank, its console and what it was refused.
public struct PresentedDrawn: Codable, Equatable, Sendable {
    public let loadMs: Double
    public let blank: Bool
    public let console: [String]
    public let blocked: [String]

    public init(loadMs: Double, blank: Bool, console: [String], blocked: [String]) {
        self.loadMs = loadMs
        self.blank = blank
        self.console = console
        self.blocked = blocked
    }
}

/// A version's question, and its answer once it has ended.
public struct PresentedQuestion: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        /// "c1", "c2", …
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let text: String
    public let choices: [Choice]
    /// The Inbox item's id (it waits) or the stored need's (`wait: false`).
    public let need: String
    public let answer: PresentedAnswer?

    public init(text: String, choices: [Choice], need: String, answer: PresentedAnswer?) {
        self.text = text
        self.choices = choices
        self.need = need
        self.answer = answer
    }

    /// Whether the engine still has it waiting, as far as the record says.
    public var isOpen: Bool { answer == nil }
}

/// How a question ended: a choice's label, the person's words, or why it ended without an answer.
public enum PresentedAnswer: Codable, Equatable, Sendable {
    case chose(String)
    case words(String)
    case ended(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let label = try container.decodeIfPresent(String.self, forKey: .chose) { self = .chose(label) }
        else if let words = try container.decodeIfPresent(String.self, forKey: .words) { self = .words(words) }
        else { self = .ended(try container.decode(String.self, forKey: .ended)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chose(let label): try container.encode(label, forKey: .chose)
        case .words(let words): try container.encode(words, forKey: .words)
        case .ended(let why): try container.encode(why, forKey: .ended)
        }
    }

    private enum CodingKeys: String, CodingKey { case chose, words, ended }
}

/// A presentation of a conversation, as a window is opened for it: one window for each.
public struct PresentationRef: Codable, Hashable, Sendable {
    /// The conversation as the app shows it (the chat's id for a chat), as its number in text.
    public let conversationId: String
    /// "p2".
    public let presentation: String

    public init(conversationId: String, presentation: String) {
        self.conversationId = conversationId
        self.presentation = presentation
    }

    public init(conversation: Int, presentation: String) {
        self.init(conversationId: String(conversation), presentation: presentation)
    }

    /// The conversation's number, as the engine's requests take it.
    public var conversation: Int? { Int(conversationId) }
}
