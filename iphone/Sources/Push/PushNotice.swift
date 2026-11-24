import Foundation

/// The kinds of notification of docs/iphone.md section 7, by their category's name.
enum PushKind: String, CaseIterable, Sendable {
    case approval, question, decision, reach, rule, limit, notice

    var category: String { "pi2.\(rawValue)" }

    /// The kind of an alert's `category`, as the engine names it (`pi2.approval`); nil for one this build does not know.
    init?(category: String) {
        guard let kind = Self.allCases.first(where: { $0.category == category }) else { return nil }
        self = kind
    }
    /// The category of a notification whose body does not show the whole call, question or rule: without the button
    /// that would act on what was cut (section 7).
    var cutCategory: String { "pi2.\(rawValue).cut" }
    /// Whether a button of this kind acts on what the body shows, and so is offered only when it shows it whole.
    var hasCutCategory: Bool { [.approval, .question, .rule].contains(self) }
}

/// What a push holds once opened and verified (section 7): the engine's own body, as pi² Remote sealed it inside the Mac
/// item (`PushSealing`, docs/iphone.md 7.1). The Mac item `push` holds an alert's, `{"v":1,"type":"need"|"limit"|
/// "answer","category":"pi2.approval"…,"title","subtitle"?,"body","projectId"?,"need"?,"conversationId"?,"whole",
/// "partHidden"?,"until"?,"at"}`; `pushGone` a background push's, `{"v":1,"type":"gone","needs":[…],"at"}`, the
/// notifications to take away. This is the engine's shape (#689), which replaced #690's assumption (`kind`, a body with
/// the project in front, one `need` gone): the phone's side changed to read it.
enum PushItem: Equatable, Sendable {
    case notice(PushNotice)
    case gone(needs: [String])

    /// The longest title, subtitle and body shown, in characters, as the engine cuts them (7.1: 80, 64, 180).
    static let titleLimit = 80
    static let subtitleLimit = 64
    static let bodyLimit = 180
    /// The most items one background push names (the engine's 50).
    static let goneLimit = 50
    /// How old a push may be when it is opened: the relay keeps an alert an hour (`apns-expiration`) and the mailbox a
    /// day, so an older one can only be one handed back.
    static let oldest: TimeInterval = 24 * 60 * 60

    static func read(_ opened: OpenedPush, now: Date) throws -> PushItem {
        let at = Date(timeIntervalSince1970: TimeInterval(opened.at) / 1000)
        guard now.timeIntervalSince(at) <= oldest else { throw PushRefusal.tooOld }
        guard let body = try? JSONSerialization.jsonObject(with: opened.body) as? [String: Any], (body["v"] as? NSNumber)?.intValue == 1,
              let type = body["type"] as? String
        else { throw PushRefusal.notANotice }
        switch (opened.kind, type) {
        case ("push", "need"), ("push", "limit"), ("push", "answer"):
            let (title, titleWhole) = Self.shown(body["title"], limit: titleLimit)
            let (text, textWhole) = Self.shown(body["body"], limit: bodyLimit)
            guard let title, !title.isEmpty, let text else { throw PushRefusal.notANotice }
            var subtitle: String?
            var subtitleWhole = true
            if body["subtitle"] != nil {
                let shown = Self.shown(body["subtitle"], limit: subtitleLimit)
                guard let given = shown.text else { throw PushRefusal.notANotice }
                (subtitle, subtitleWhole) = (given.isEmpty ? nil : given, shown.whole)
            }
            return .notice(PushNotice(
                id: opened.id, at: opened.at,
                kind: (body["category"] as? String).flatMap(PushKind.init(category:)),
                title: title, subtitle: subtitle, body: text,
                // A button that acts on what is shown is offered only when the Mac says it is shown whole, nothing of it
                // was hidden, and nothing was cut or changed here (section 7, 7.1). Missing means not whole.
                whole: titleWhole && subtitleWhole && textWhole && Self.isTrue(body["whole"]) && body["partHidden"] == nil,
                need: Self.id(body["need"]), projectId: Self.id(body["projectId"]),
                conversationId: (body["conversationId"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) }))
        case ("pushGone", "gone"):
            guard let list = body["needs"] as? [Any], (1...goneLimit).contains(list.count) else { throw PushRefusal.notANotice }
            let needs = list.compactMap { Self.id($0) }
            guard needs.count == list.count else { throw PushRefusal.notANotice }
            return .gone(needs: needs)
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
    /// "Demo project": the project's name, when it is in one.
    let subtitle: String?
    /// "bash: npm test": the card's short line.
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
