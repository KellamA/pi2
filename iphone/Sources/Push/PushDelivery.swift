import Foundation
import UserNotifications

/// What the service extension does with each push (docs/iphone.md section 7): opens `sealed` with the phone's record
/// key, checks the Mac's signature, and **always replaces the title and the body**, with what was inside the seal or,
/// when it is missing, does not open, does not verify or is not a notification, with *pi²: Something needs you*,
/// whatever the push's own alert said. So neither a hostile relay nor a leaked push key can put words on a pi²
/// notification. Then the category of its kind (its buttons) and its thread (its project), and the item kept in the
/// extension's own file for the app to merge.
enum PushDelivery {
    static let placeholderTitle = "pi²"
    static let placeholderBody = "Something needs you"

    /// What happened to a push, for the extension's log; never the text.
    enum Outcome: Equatable, Sendable {
        case shown(PushNotice)
        case placeholder(PushRefusal)

        var logLine: String {
            switch self {
            case let .shown(notice): "shown, category \(notice.category ?? "none")"
            case let .placeholder(why): "placeholder: \(why.words)"
            }
        }
    }

    /// The notification to show for a push whose payload is `userInfo`, and what happened. `keys` is read only once
    /// the push is one to open, so a push with no seal reads no Keychain item. `seen` remembers the pushes opened, so
    /// that one handed back is not shown again (none in a build without the app group: nothing is remembered then).
    static func deliver(
        _ userInfo: [AnyHashable: Any], opener: (any PushOpening)?, keys: () throws -> PushKeys?, seen: PushSeen? = nil, now: Date = Date()
    ) -> (content: UNNotificationContent, outcome: Outcome) {
        do {
            let notice = try open(userInfo, opener: opener, keys: keys, seen: seen, now: now)
            return (content(for: notice), .shown(notice))
        } catch let refusal as PushRefusal {
            return (placeholder(), .placeholder(refusal))
        } catch {
            return (placeholder(), .placeholder(.doesNotOpen))
        }
    }

    /// The notice inside a push, opened and verified; throws `PushRefusal` otherwise. A `pushGone` in an alert is
    /// not one to show.
    static func open(
        _ userInfo: [AnyHashable: Any], opener: (any PushOpening)?, keys: () throws -> PushKeys?, seen: PushSeen? = nil, now: Date = Date()
    ) throws -> PushNotice {
        guard case let .notice(notice) = try item(userInfo, opener: opener, keys: keys, seen: seen, now: now) else { throw PushRefusal.notANotice }
        return notice
    }

    /// What a push holds, opened and verified: a notice, or the needs whose notifications are to be taken away. A push
    /// whose id was opened before is refused (`replayed`): only one that opened, verified and was read is remembered, so
    /// that pushes made up by someone else cannot fill the memory.
    static func item(
        _ userInfo: [AnyHashable: Any], opener: (any PushOpening)?, keys: () throws -> PushKeys?, seen: PushSeen? = nil, now: Date = Date()
    ) throws -> PushItem {
        let sealed = try SealedPush.read(userInfo)
        guard let opener else { throw PushRefusal.noOpener }
        guard let keys = try? keys() else { throw PushRefusal.noKeys }
        let opened = try opener.open(sealed, keys: keys)
        let item = try PushItem.read(opened, now: now)
        if let seen, !seen.firstTime(opened.id, now: now) { throw PushRefusal.replayed }
        return item
    }

    /// A notice as iOS shows it. Made afresh, so nothing of the push's own alert, sound or payload is kept.
    static func content(for notice: PushNotice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle ?? ""
        content.body = notice.body
        content.categoryIdentifier = notice.category ?? ""
        content.threadIdentifier = notice.thread
        content.sound = .default
        var info: [String: Any] = [PushUserInfo.item: notice.id]
        if let need = notice.need { info[PushUserInfo.need] = need }
        if let kind = notice.kind { info[PushUserInfo.kind] = kind.rawValue }
        if let project = notice.projectId { info[PushUserInfo.projectId] = project }
        if let conversation = notice.conversationId { info[PushUserInfo.conversationId] = conversation }
        content.userInfo = info
        return content
    }

    /// *pi²: Something needs you*, with no category, so no button, and no thread.
    static func placeholder() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = placeholderTitle
        content.body = placeholderBody
        content.sound = .default
        content.userInfo = [:]
        return content
    }
}
