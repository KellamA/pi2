import Foundation
import PiModels

/// Something the person did in the transcript page, as the page reports it through the `pi2` message handler.
///
/// The page shows untrusted text, so every message is checked here before it is believed: a known type, fields of the
/// right kinds, sizes within reason, and links only to http, https and mailto. Whether an approval, an entry or a
/// sub-chat it names really belongs to the conversation is checked by whoever acts on it.
public enum TranscriptAction: Equatable {
    /// The page has loaded and wants the whole conversation.
    case ready
    /// The reader is near the top of what the page has, and there are older entries to ask for (#440).
    case older
    case copy(String)
    case openLink(URL)
    case decide(inbox: String, decision: String)
    case answer(inbox: String, text: String)
    /// A sub-chat to show: in place of this conversation, or `beside` it in a pane of its own.
    case openChat(Int, beside: Bool)
    case fork(entry: Int)
    /// Try Again under a chat's answer, with the model chosen for it, if one was (#285).
    case retry(entry: Int, model: ModelRef?)
    /// One of the person's messages in a chat, sent again with this text as a new version.
    case edit(entry: Int, text: String)
    /// Another of a chat's versions at a point: `after` the entry they part at (nil: the first message).
    case version(after: Int?, index: Int)
    case picture(entry: Int, index: Int)
    /// The window with a background command's output, by the id the engine gave it ("bg-3").
    case output(String)
    /// Save text from the page (a code block, an output, a long answer) as a file, offering `name`: the person chooses where.
    case save(text: String, name: String)
    /// Save one of an entry's pictures as a file.
    case savePicture(entry: Int, index: Int)
    /// Open, or save a copy of, the document a `write_document` call wrote: named by the call's entry, never by a path.
    case openDocument(entry: Int)
    case saveDocument(entry: Int)
    /// A click on a link to a file on this Mac (#451): the target as the answer wrote it, which the app makes whole.
    case showFile(String)
    /// A right-click: on a file link or a path written as code (`code`), whose items go at the top of the menu WebKit
    /// is about to show; or, with no path, on anything else.
    case fileMenu(path: String?, code: Bool)
    /// The person's Undo of a change a tool call made in this conversation (docs/projects.md, 3.12), by the change's
    /// number as the page was sent it.
    case undo(change: Int)
    /// The person's answer to a reach request or a proposed rule at the call that asked (7.2), by the need's id as
    /// the page was sent it: the same `needs.answer` the board's card answers it with.
    case answerNeed(id: String, answer: NeedAnswer)
    /// A presented picture, or a page's snapshot, for a `present` call's card (#946): by the presentation's id ("p2"),
    /// the version's number and the item's index, as the page was sent the conversation's records.
    case presentedImage(presentation: String, version: Int, item: Int)
    /// Expand, or a click on an item of a `present` call's card: the presentation's window at that version and item.
    case expand(presentation: String, version: Int, item: Int)
    /// One of a `present` question's choices, by its id ("c1"), and the question's need, as the record names it.
    case choose(need: String, choice: String)
    /// An answer in the person's words to a `present` question, by its need's id.
    case answerPresented(need: String, text: String)

    static let copyLimit = 20_000_000
    static let answerLimit = 100_000
    /// An edited message: as long as a message can be, within reason.
    static let editLimit = 1_000_000

    public init?(message body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "older":
            self = .older
        case "copy":
            guard let text = body["text"] as? String, !text.isEmpty, text.utf16.count <= Self.copyLimit else { return nil }
            self = .copy(text)
        case "openLink":
            guard let url = Self.link(body["url"]) else { return nil }
            self = .openLink(url)
        case "decide":
            // "rule" carries no words: the engine makes the rule it offered with the approval.
            guard let id = Self.identifier(body["inbox"]), let decision = body["decision"] as? String,
                  ["once", "always", "rule", "deny"].contains(decision) else { return nil }
            self = .decide(inbox: id, decision: decision)
        case "answer" where body["need"] != nil:
            // A `present` question's, by its need: never one that names an Inbox item as well.
            guard body["inbox"] == nil, let need = Self.identifier(body["need"]), let text = body["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= Self.answerLimit else { return nil }
            self = .answerPresented(need: need, text: text)
        case "answer":
            guard let id = Self.identifier(body["inbox"]), let text = body["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= Self.answerLimit else { return nil }
            self = .answer(inbox: id, text: text)
        case "openChat":
            guard let id = Self.integer(body["id"]) else { return nil }
            self = .openChat(id, beside: body["beside"] as? Bool == true)
        case "fork":
            guard let entry = Self.integer(body["entry"]) else { return nil }
            self = .fork(entry: entry)
        case "retry":
            guard let entry = Self.integer(body["entry"]) else { return nil }
            if body["model"] == nil {
                self = .retry(entry: entry, model: nil)
            } else {
                guard let model = body["model"] as? [String: Any], let provider = Self.identifier(model["provider"]),
                      let id = Self.identifier(model["modelId"]) else { return nil }
                self = .retry(entry: entry, model: ModelRef(provider: provider, modelId: id))
            }
        case "edit":
            // Empty text is the engine's to refuse or not: a message of attachments alone keeps them.
            guard let entry = Self.integer(body["entry"]), let text = body["text"] as? String, text.utf16.count <= Self.editLimit else { return nil }
            self = .edit(entry: entry, text: text)
        case "version":
            guard let index = Self.integer(body["index"]), index >= 0 else { return nil }
            if body["after"] is NSNull {
                self = .version(after: nil, index: index)
            } else {
                guard let after = Self.integer(body["after"]) else { return nil }
                self = .version(after: after, index: index)
            }
        case "image":
            guard let entry = Self.integer(body["entry"]), let index = Self.integer(body["index"]), index >= 0, index < 1000 else { return nil }
            self = .picture(entry: entry, index: index)
        case "output":
            guard let id = Self.backgroundCommand(body["id"]) else { return nil }
            self = .output(id)
        case "save":
            guard let text = body["text"] as? String, !text.isEmpty, text.utf16.count <= Self.copyLimit,
                  let name = Self.fileName(body["name"]) else { return nil }
            self = .save(text: text, name: name)
        case "savePicture":
            guard let entry = Self.integer(body["entry"]), let index = Self.integer(body["index"]), index >= 0, index < 1000 else { return nil }
            self = .savePicture(entry: entry, index: index)
        case "openDocument", "saveDocument":
            guard let entry = Self.integer(body["entry"]) else { return nil }
            self = type == "openDocument" ? .openDocument(entry: entry) : .saveDocument(entry: entry)
        case "showFile":
            guard let path = Self.fileTarget(body["path"]) else { return nil }
            self = .showFile(path)
        case "fileMenu":
            if body["path"] == nil {
                self = .fileMenu(path: nil, code: false)
            } else {
                guard let path = Self.fileTarget(body["path"]) else { return nil }
                self = .fileMenu(path: path, code: body["code"] as? Bool == true)
            }
        case "undo":
            guard let change = Self.integer(body["change"]) else { return nil }
            self = .undo(change: change)
        case "answerNeed":
            guard let id = Self.identifier(body["need"]), let answer = body["answer"] as? [String: Any],
                  let kind = answer["kind"] as? String else { return nil }
            if kind == "reach", let allow = answer["allow"] as? Bool {
                self = .answerNeed(id: id, answer: .reach(allow: allow))
            } else if kind == "rule", let accept = answer["accept"] as? Bool {
                self = .answerNeed(id: id, answer: .rule(accept: accept))
            } else {
                return nil
            }
        case "presentedImage", "expand":
            guard let presentation = Self.presentation(body["presentation"]), let version = Self.integer(body["version"]), version >= 1,
                  let item = Self.integer(body["item"]), (0..<Self.presentedItems).contains(item) else { return nil }
            self = type == "expand" ? .expand(presentation: presentation, version: version, item: item) : .presentedImage(presentation: presentation, version: version, item: item)
        case "choose":
            guard let need = Self.identifier(body["need"]), let choice = Self.choiceID(body["choice"]) else { return nil }
            self = .choose(need: need, choice: choice)
        default:
            return nil
        }
    }

    /// The most items a version of a presentation has (engine/src/presented.ts, `LIMITS.items`).
    static let presentedItems = 6

    /// A presentation's id as the engine makes them, "p" and a whole number from 1, and nothing else.
    static func presentation(_ value: Any?) -> String? {
        guard let text = value as? String, PresentationRecord.isID(text) else { return nil }
        return text
    }

    /// A choice's id: short printable text. The engine makes them "c1", "c2", …; whether it is one of the question's
    /// is `PresentedChecks`'s to say.
    static func choiceID(_ value: Any?) -> String? {
        guard let text = value as? String, (1...64).contains(text.utf16.count),
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// What a message about a presentation may ask, checked against what the conversation has (#946): the bridge acts on
    /// one only if `allows` says so. The page names presentations, versions, items and needs; it is believed only where
    /// the conversation's own records have them.
    public struct PresentedChecks {
        /// The conversation's records, by presentation, as the engine gave them.
        public let records: [String: PresentationRecord]
        /// The needs waiting for the person in this conversation that are decisions, as the engine's `needs` list has them.
        public let waiting: Set<String>

        public init(records: [String: PresentationRecord], waiting: Set<String>) {
            self.records = records
            self.waiting = waiting
        }

        /// An item the conversation's records have.
        public func item(_ presentation: String, _ version: Int, _ item: Int) -> PresentedItem? {
            guard let found = records[presentation]?.version(version), found.items.indices.contains(item) else { return nil }
            return found.items[item]
        }

        /// A `present` question of the conversation's records by its need, still open in the record and still waiting in
        /// this conversation: never another conversation's, one already answered, nor a need that is not a `present` question.
        public func question(_ need: String) -> PresentedQuestion? {
            guard waiting.contains(need) else { return nil }
            for record in records.values {
                for version in record.versions {
                    if let question = version.question, question.need == need { return question.isOpen ? question : nil }
                }
            }
            return nil
        }

        /// Whether the bridge may act on `action`: true for an action about no presentation, which is checked elsewhere.
        public func allows(_ action: TranscriptAction) -> Bool {
            switch action {
            case .presentedImage(let presentation, let version, let index), .expand(let presentation, let version, let index):
                return item(presentation, version, index) != nil
            case .choose(let need, let choice):
                return question(need)?.choices.contains { $0.id == choice } == true
            case .answerPresented(let need, _):
                return question(need) != nil
            default:
                return true
            }
        }
    }

    /// An answer to a reach request or a proposed rule, as the contract's `NeedAnswer` gives that kind (docs/projects.md,
    /// 3.9): what `needs.answer` is sent for the card's button.
    public enum NeedAnswer: Equatable {
        case reach(allow: Bool)
        case rule(accept: Bool)

        /// The answer as the request takes it.
        public var params: [String: Any] {
            switch self {
            case .reach(let allow): ["kind": "reach", "allow": allow]
            case .rule(let accept): ["kind": "rule", "accept": accept]
            }
        }
    }

    /// A web or mail address the person may be sent to, and nothing else.
    static func link(_ value: Any?) -> URL? {
        guard let text = value as? String, text.utf16.count <= 8192, let url = URL(string: text),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            return text.count > "mailto:".count ? url : nil
        default:
            return nil
        }
    }

    /// A file link's target as the page sends it: text of a reasonable length with nothing unprintable. Which file it
    /// names, if any, is `FileLink.path`'s to say.
    static func fileTarget(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf16.count <= 4096,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// A name the page offers for a file, which the save panel shows and the person can change: one name, no folder,
    /// nothing hidden, nothing that is not printable.
    static func fileName(_ value: Any?) -> String? {
        guard let text = value as? String, (1...120).contains(text.count), !text.hasPrefix("."),
              !text.contains("/"), !text.contains(":"),
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// An id the engine gives a background command, "bg-" and a number, and nothing else.
    static func backgroundCommand(_ value: Any?) -> String? {
        guard let text = value as? String, text.hasPrefix("bg-") else { return nil }
        // Byte by byte, so that no other kind of digit, and no mark joined to one, passes for a number.
        let digits = Array(text.utf8.dropFirst(3))
        guard (1...9).contains(digits.count), digits[0] != UInt8(ascii: "0"),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return text
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf16.count <= 200 else { return nil }
        return text
    }

    private static func integer(_ value: Any?) -> Int? {
        // JavaScript numbers arrive as NSNumber; a fraction, a Boolean or anything out of range is not an ID.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return number.intValue
    }
}
