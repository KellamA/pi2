import Foundation
import PiModels

/// The whole of an approval's call, as the phone shows it before any answer (docs/iphone.md P17; docs/design/iphone.md,
/// "A card that needs the person"): every argument the agent gave, each in full. The Mac's card shows the call's one
/// line (`ToolCall.summary`) and a long text beside it; the phone shows that line first and then everything else, so that
/// nothing the call would do is left out of what the person reads.
struct NeedCall: Equatable, Sendable {
    /// One argument: its name (nil for the line that is the call itself, such as a command), and its value as text.
    struct Part: Equatable, Sendable, Identifiable {
        let label: String?
        let text: String
        /// Shown as code: a command, a path, a script, or a value that is not text.
        let code: Bool
        var id: String { label ?? "" }
    }

    let tool: String
    let parts: [Part]

    /// The arguments read first, in this order, as `ToolCall.summary` reads them: the first one present is the call's own
    /// line.
    static let leading = ["command", "path", "task", "code", "question"]
    /// The arguments shown as code when they are text.
    private static let codeLike: Set<String> = ["command", "path", "code", "oldText", "newText", "old_string", "new_string", "content", "cwd", "url", "selector"]

    init(tool: String, arguments: JSONValue) {
        self.tool = tool
        guard case .object(let object) = arguments else {
            parts = arguments == .null ? [] : [Part(label: nil, text: arguments.displayText, code: true)]
            return
        }
        let first = Self.leading.first { object[$0]?.stringValue != nil }
        let rest = object.keys.filter { $0 != first }.sorted { a, b in
            let order = Self.leading
            switch (order.firstIndex(of: a), order.firstIndex(of: b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        var parts: [Part] = []
        if let first, let text = object[first]?.stringValue {
            // A command is the call itself; a path or a task keeps its name, which says what it is.
            parts.append(Part(label: first == "command" ? nil : first, text: text, code: first != "task" && first != "question"))
        }
        for key in rest {
            guard let value = object[key] else { continue }
            if let text = value.stringValue {
                parts.append(Part(label: key, text: text, code: Self.codeLike.contains(key)))
            } else {
                parts.append(Part(label: key, text: Self.text(of: value), code: true))
            }
        }
        self.parts = parts
    }

    /// A value that is not text, as the person reads it: a number or a switch plainly, anything larger as JSON.
    private static func text(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        default: value.displayText
        }
    }

    /// Everything shown, as one text: what VoiceOver reads, and what the tests check is whole.
    var wholeText: String {
        parts.map { part in part.label.map { "\($0): \(part.text)" } ?? part.text }.joined(separator: "\n")
    }
}

/// What part of a call the engine kept from the phone, and what follows from it (docs/iphone.md 5.7; pull request #776):
/// the engine masks every key-shaped string it sends a device, replacing it with `[key hidden]`, and an approval whose
/// call was changed so can be allowed only on the Mac, which saw it whole. From the phone it can only be denied.
enum NeedHiddenCall {
    /// What the engine puts in place of a key it does not send a phone (`KEY_HIDDEN` in `engine/src/devices.ts`).
    static let keyHidden = "[key hidden]"
    /// What it puts in place of a value nested too deep to send (`TOO_DEEP` there).
    static let tooDeep = "[too deep to show]"

    /// Whether part of this approval's call was hidden from the phone. **The one place that reads the mark.**
    ///
    /// The engine marks such an approval itself (#776, #809): `partHidden` on the `NeedItem` and the `InboxItem` it was
    /// sent in. A value too deep to send leaves nothing in the call the phone could see, so the field is the only way
    /// to know of it; a key masked in the call still shows its placeholder, so that is read beside the field. That errs
    /// on the safe side: a call whose own text holds a placeholder is treated as hidden, and can be allowed on the Mac.
    static func isPartlyHidden(mark: Bool = false, arguments: JSONValue?) -> Bool {
        if mark { return true }
        guard let arguments else { return false }
        return holdsPlaceholder(arguments)
    }

    private static func holdsPlaceholder(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): text.contains(keyHidden) || text.contains(tooDeep)
        case .array(let values): values.contains(where: holdsPlaceholder)
        case .object(let object): object.contains { key, value in key.contains(keyHidden) || holdsPlaceholder(value) }
        default: false
        }
    }

    /// A text cut where the engine hid a key: the call's own words, and the places it hid one, in order.
    enum Piece: Equatable {
        case text(String)
        case hidden
    }

    static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(text)
        while let range = rest.range(of: keyHidden) {
            if range.lowerBound > rest.startIndex { pieces.append(.text(String(rest[..<range.lowerBound]))) }
            pieces.append(.hidden)
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { pieces.append(.text(String(rest))) }
        return pieces
    }

    /// The text as VoiceOver reads it: a hidden key said as such, never as the placeholder's brackets.
    static func spoken(_ text: String) -> String {
        pieces(of: text).map { piece in
            switch piece {
            case .text(let words): words
            case .hidden: " (a hidden key) "
            }
        }.joined()
    }
}
