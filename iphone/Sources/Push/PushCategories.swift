import Foundation
import UserNotifications

/// The notification categories of docs/iphone.md section 7, each with its buttons and its Lock Screen placeholder, in
/// one place for the app and the service extension, so the two cannot disagree about what a category offers. The app
/// registers them as it starts, and the service extension again before it hands on a notification, so that they are
/// there even before the app has run since it was installed or updated.
///
/// **Every button opens pi²** (`foreground`) **with the phone unlocked** (`authenticationRequired`), since an action
/// counts as opening (4.5): the app then asks Face ID if no session is open, shows the whole card and only then does
/// what was chosen (P22). None answers from the Lock Screen.
///
/// **On the Lock Screen** a notification shows its title ("Forge needs approval", who and what kind) and its
/// category's placeholder in place of the body (the project and the command), while iOS hides previews: which it does
/// on a locked phone unless the person has set pi²'s Show Previews to Always in iOS's Settings. The phone's own
/// **Details on the Lock Screen** is then off, as section 7 wants by default; an app cannot show more than iOS's own
/// setting allows, nor less than Always shows.
enum PushCategories {
    /// The buttons' identifiers, which the app reads in the response (`PushResponse`).
    enum Action: String, CaseIterable, Sendable {
        case allowOnce, deny, open, reply, allow, refuse, accept, startAnyway, wait
    }

    /// Sets them on `center`, in place of whatever was set before.
    static func register(on center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(all)
    }

    static var all: Set<UNNotificationCategory> {
        Set(PushKind.allCases.flatMap { kind in
            var categories = [category(kind.category, actions(kind, whole: true), kind)]
            if kind.hasCutCategory { categories.append(category(kind.cutCategory, actions(kind, whole: false), kind)) }
            return categories
        })
    }

    /// The buttons of a kind, in order (section 7's table). `whole` is false when the body does not show the whole call,
    /// question or rule: the button that would act on it is left out.
    static func actions(_ kind: PushKind, whole: Bool) -> [Action] {
        switch kind {
        case .approval: whole ? [.allowOnce, .deny, .open] : [.open, .deny]
        case .question: whole ? [.reply, .open] : [.open]
        case .decision: [.open]
        case .reach: [.allow, .refuse]
        case .rule: whole ? [.accept, .refuse, .open] : [.refuse, .open]
        case .limit: [.startAnyway, .wait]
        case .notice: []
        }
    }

    /// What a button says.
    static func title(_ action: Action) -> String {
        switch action {
        case .allowOnce: "Allow once"
        case .deny: "Deny"
        case .open: "Open"
        case .reply: "Reply"
        case .allow: "Allow…"
        case .refuse: "Refuse"
        case .accept: "Accept"
        case .startAnyway: "Start anyway…"
        case .wait: "Wait"
        }
    }

    static func isDestructive(_ action: Action) -> Bool { action == .deny || action == .refuse }

    /// What the Lock Screen shows in place of the body while previews are hidden, beside the title.
    static func placeholder(_ kind: PushKind) -> String {
        switch kind {
        case .approval: "A command waits for approval. Unlock to see it."
        case .question: "A question waits for an answer. Unlock to see it."
        case .decision: "A decision waits. Unlock to see it."
        case .reach: "A request for more reach waits. Unlock to see it."
        case .rule: "A proposed rule waits. Unlock to see it."
        case .limit: "A start waits on a limit. Unlock to see it."
        case .notice: "Unlock to see the answer."
        }
    }

    private static func category(_ id: String, _ actions: [Action], _ kind: PushKind) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: id, actions: actions.map(notificationAction), intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: placeholder(kind), options: [.hiddenPreviewsShowTitle])
    }

    private static func notificationAction(_ action: Action) -> UNNotificationAction {
        var options: UNNotificationActionOptions = [.foreground, .authenticationRequired]
        if isDestructive(action) { options.insert(.destructive) }
        if action == .reply {
            return UNTextInputNotificationAction(
                identifier: action.rawValue, title: title(action), options: options,
                textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        }
        return UNNotificationAction(identifier: action.rawValue, title: title(action), options: options)
    }
}

/// A button or a tap on one of pi²'s notifications, as the app reads it to open the card (P22 answers it): which
/// button, the need, its kind, project and conversation, and what was typed for **Reply**.
struct PushResponse: Equatable, Sendable {
    /// Nil for a tap on the notification itself, or a button this build does not know.
    let action: PushCategories.Action?
    let need: String?
    let kind: PushKind?
    let projectId: String?
    let conversationId: Int?
    let reply: String?

    init(action identifier: String, userInfo: [AnyHashable: Any], reply: String?) {
        action = PushCategories.Action(rawValue: identifier)
        need = userInfo[PushUserInfo.need] as? String
        kind = (userInfo[PushUserInfo.kind] as? String).flatMap(PushKind.init(rawValue:))
        projectId = userInfo[PushUserInfo.projectId] as? String
        conversationId = (userInfo[PushUserInfo.conversationId] as? NSNumber)?.intValue
        self.reply = reply
    }

    init(_ response: UNNotificationResponse) {
        self.init(
            action: response.actionIdentifier, userInfo: response.notification.request.content.userInfo,
            reply: (response as? UNTextInputNotificationResponse)?.userText)
    }
}

/// The keys of a shown notification's `userInfo`, which the service extension writes and the app reads. Nothing of the
/// push's own payload is kept, `sealed` included.
enum PushUserInfo {
    static let need = "need"
    static let kind = "kind"
    static let projectId = "projectId"
    static let conversationId = "conversationId"
    static let item = "item"
}
