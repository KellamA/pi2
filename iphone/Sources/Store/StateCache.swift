import Foundation

/// The phone's cache (docs/iphone.md 3.6): the last state it saw of its Mac, as the engine's own lines, so that while
/// the Mac is out of reach the same client (EngineKit's `EngineSession`) can be shown it again (`CachedTransport`) and
/// every screen draws it as it was, dated.
///
/// - **The state**: the latest line of each event that replaces what came before it (projects, needs, the library,
///   activity, the board's lists, and every other the engine sends a phone), in the order they first came.
/// - **Conversations**: the newest 300 entries, and the state, of at most 20 conversations, each sent in the last seven
///   days. The engine sends a conversation's lines only while the phone has it open, so these are the ones opened.
///   Entries are kept as the engine sent them, attachments named but not copied ("with no attachments but those shown
///   in them").
///
/// It keeps no line of what the engine never sends a phone (5.7), nor any answer to a request.
struct StateCache: Codable, Equatable, Sendable {
    static let entries = 300
    static let conversationLimit = 20
    static let conversationDays = 7
    /// Events not kept: those the engine never sends a device session (5.7), and `local.progress`, which only changes
    /// `local`.
    static let notKept: Set<String> = ["auth", "computer", "browser", "local", "local.progress", "mcp", "devices", "device"]

    struct Event: Codable, Equatable, Sendable {
        var kind: String
        /// The line as the engine sent it, without its line break.
        var line: String
    }

    struct Conversation: Codable, Equatable, Sendable {
        var id: Int
        /// Each entry as the JSON the engine sent, oldest first: at most the newest 300.
        var items: [String]
        /// The conversation's state as the JSON the engine last sent.
        var state: String
        /// When the Mac last sent a line of it.
        var updatedAt: Date
    }

    private(set) var events: [Event] = []
    private(set) var conversations: [Conversation] = []
    /// When the Mac sent the newest line kept here: the date the screens show beside the last state.
    private(set) var heardAt: Date?

    var isEmpty: Bool { events.isEmpty && conversations.isEmpty }

    /// Takes one line the engine sent, at `date`. True when it changed what is kept.
    @discardableResult
    mutating func take(_ line: Data, at date: Date) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let kind = object["event"] as? String, !Self.notKept.contains(kind) else { return false }
        heardAt = date
        switch kind {
        case "conversation":
            return takeConversation(object, at: date)
        case "conversation.older":
            return takeOlder(object, at: date)
        default:
            guard let read = String(data: line, encoding: .utf8) else { return false }
            let text = read.trimmingCharacters(in: .newlines)
            if let index = events.firstIndex(where: { $0.kind == kind }) {
                events[index].line = text
            } else {
                events.append(Event(kind: kind, line: text))
            }
            return true
        }
    }

    /// The state's lines, each ending with a line break, in the order they first came.
    var stateLines: Data {
        var data = Data()
        for event in events {
            data.append(Data(event.line.utf8))
            data.append(0x0A)
        }
        return data
    }

    /// Conversation `id` as one line sent from the start (`reset`), with nothing older to ask for, ending with a line
    /// break; nil when it is not kept.
    func conversationLine(_ id: Int) -> Data? {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return nil }
        let text = "{\"event\":\"conversation\",\"id\":\(id),\"reset\":true,\"earlier\":0,\"more\":false,\"items\":["
            + conversation.items.joined(separator: ",") + "],\"state\":" + conversation.state + "}\n"
        return Data(text.utf8)
    }

    /// Leaves out the conversations not sent for seven days, and all but the 20 sent most recently.
    mutating func prune(at date: Date) {
        let oldest = date.addingTimeInterval(-Double(Self.conversationDays) * 86_400)
        conversations.removeAll { $0.updatedAt < oldest }
        if conversations.count > Self.conversationLimit {
            conversations.sort { $0.updatedAt > $1.updatedAt }
            conversations.removeLast(conversations.count - Self.conversationLimit)
        }
    }

    // MARK: - Conversations

    private mutating func takeConversation(_ object: [String: Any], at date: Date) -> Bool {
        guard let id = object["id"] as? Int, let state = object["state"], let stateText = Self.text(state) else { return false }
        let items = ((object["items"] as? [Any]) ?? []).compactMap(Self.text)
        let reset = object["reset"] as? Bool ?? false
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            if reset { conversations[index].items = [] }
            conversations[index].items.append(contentsOf: items)
            conversations[index].items = Array(conversations[index].items.suffix(Self.entries))
            conversations[index].state = stateText
            conversations[index].updatedAt = date
        } else {
            // An update with no list sent from the start before it has nothing to go on.
            guard reset else { return false }
            conversations.append(Conversation(id: id, items: Array(items.suffix(Self.entries)), state: stateText, updatedAt: date))
        }
        prune(at: date)
        return true
    }

    /// Entries older than those kept, which the engine sends a long conversation after its newest: only while fewer
    /// than 300 are kept.
    private mutating func takeOlder(_ object: [String: Any], at date: Date) -> Bool {
        guard let id = object["id"] as? Int, let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        let first = conversations[index].items.first.flatMap(Self.entryID) ?? Int.max
        let older = ((object["items"] as? [Any]) ?? []).filter { (($0 as? [String: Any])?["id"] as? Int ?? Int.max) < first }.compactMap(Self.text)
        let room = Self.entries - conversations[index].items.count
        guard room > 0, !older.isEmpty else { return false }
        conversations[index].items.insert(contentsOf: older.suffix(room), at: 0)
        conversations[index].updatedAt = date
        return true
    }

    private static func text(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func entryID(_ text: String) -> Int? {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["id"] as? Int
    }
}
