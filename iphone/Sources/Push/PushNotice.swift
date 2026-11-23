import Foundation

/// The kinds of notification of docs/iphone.md section 7, by their category's name.
enum PushKind: String, CaseIterable, Sendable {
    case approval, question, decision, reach, rule, limit, notice

    var category: String { "pi2.\(rawValue)" }
    /// The category of a notification whose body does not show the whole call, question or rule: without the button
    /// that would act on what was cut (section 7).
    var cutCategory: String { "pi2.\(rawValue).cut" }
    /// Whether a button of this kind acts on what the body shows, and so is offered only when it shows it whole.
    var hasCutCategory: Bool { [.approval, .question, .rule].contains(self) }
}

/// What a push holds once opened and verified (section 7): the Mac item `push`, whose body is
/// `{"kind":…,"title":…,"body":…,"whole":…,"need":…,"projectId":…,"conversationId":…,"pad":…}`, or `pushGone`, whose
/// body is `{"need":…,"pad":…}`, a notification to take away. Only `title` and `body` are required of a `push`; `pad`
/// is the sealer's padding and is not read. This form is #690's assumption of what the engine and pi² Remote send
/// (#689's later parts, not built): the `remote` event's `push { device, kind, title, body, need?, projectId? }`, with
/// `whole` and `conversationId` added.
enum PushItem: Equatable, Sendable {
    case notice(PushNotice)
    case gone(need: String)

    /// The longest title and body shown, in characters; section 7 holds the body to 180.
    static let titleLimit = 120
    static let bodyLimit = 180
    /// How old a push may be when it is opened: the relay keeps an alert an hour (`apns-expiration`) and the mailbox a
    /// day, so an older one can only be one handed back.
    static let oldest: TimeInterval = 24 * 60 * 60

    static func read(_ opened: OpenedPush, now: Date) throws -> PushItem {
        let at = Date(timeIntervalSince1970: TimeInterval(opened.at) / 1000)
        guard now.timeIntervalSince(at) <= oldest else { throw PushRefusal.tooOld }
        guard let body = try? JSONSerialization.jsonObject(with: opened.body) as? [String: Any] else { throw PushRefusal.notANotice }
        switch opened.kind {
        case "push":
            guard let title = Self.shown(body["title"], limit: titleLimit).text, !title.isEmpty,
                  case let (text?, whole) = Self.shown(body["body"], limit: bodyLimit)
            else { throw PushRefusal.notANotice }
            return .notice(PushNotice(
                id: opened.id, at: opened.at,
                kind: PushKind(rawValue: body["kind"] as? String ?? ""),
                title: title, body: text,
                // A button that acts on what is shown is offered only when the Mac says it is shown whole, and nothing
                // was cut here (section 7). Missing means cut.
                whole: whole && Self.isTrue(body["whole"]),
                need: Self.id(body["need"]), projectId: Self.id(body["projectId"]),
                conversationId: (body["conversationId"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) }))
        case "pushGone":
            guard let need = Self.id(body["need"]) else { throw PushRefusal.notANotice }
            return .gone(need: need)
        default:
            throw PushRefusal.notANotice
        }
    }

    /// A text as shown in a notification: on one line, without control characters, cut to `limit` characters with an
    /// ellipsis; and whether nothing was cut or changed but white space.
    static func shown(_ value: Any?, limit: Int) -> (text: String?, whole: Bool) {
        guard let raw = value as? String else { return (nil, false) }
        var line = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : scalar
        }))
        line = line.trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return (line, true) }
        return (String(line.prefix(limit - 1)) + "…", false)
    }

    /// JSON's `true`, and nothing that Foundation would also read as true, such as 1.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func id(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= 128 else { return nil }
        return text
    }
}

/// A notification as the Mac wrote it inside the seal.
struct PushNotice: Equatable, Sendable {
    /// The item's id and when the Mac signed it.
    let id: String
    let at: Int64
    /// Nil for a kind this build does not know, from a newer Mac: shown, with no buttons.
    let kind: PushKind?
    /// "Forge needs approval": the agent's name and the kind, as the Mac's `Notifier.needsYou` says it.
    let title: String
    /// "Demo project · bash: npm test": the project's name and the card's short line.
    let body: String
    /// Whether the body shows the whole call, question or rule.
    let whole: Bool
    /// The need it is about, its project and its conversation, for the buttons, the thread and taking it away.
    let need: String?
    let projectId: String?
    let conversationId: Int?

    /// The category iOS files it under, which decides its buttons; nil for a kind this build does not know.
    var category: String? {
        guard let kind else { return nil }
        return whole || !kind.hasCutCategory ? kind.category : kind.cutCategory
    }

    /// Its thread: the project's, so a project's notifications are grouped together.
    var thread: String { projectId ?? PushNotice.noProject }
    static let noProject = "pi2.no-project"
}
