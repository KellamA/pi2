import Foundation
import UserNotifications

/// Taking a notification away once its card is answered or withdrawn (docs/iphone.md section 7): the Mac sends a
/// background push, `pushGone` sealed inside, which iOS hands to the app, not to the service extension (it has no
/// alert), best effort, since Apple may hold or drop these. The app also takes one away itself when it learns, from the
/// engine, that a need is gone, and when the person answers it.
enum PushRemoval {
    /// For the app's `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`: opens and verifies the
    /// background push and takes away the notifications of the need it names. Returns whether it named one; a push that
    /// does not open, or is not a `pushGone`, takes nothing away.
    @discardableResult @MainActor
    static func handle(
        _ userInfo: [AnyHashable: Any], opener: (any PushOpening)? = PushOpeners.standard,
        keys: () throws -> PushKeys? = { try PushKeychain().keys() }, center: UNUserNotificationCenter = .current(), now: Date = Date()
    ) async -> Bool {
        guard case let .gone(need)? = try? PushDelivery.item(userInfo, opener: opener, keys: keys, now: now) else { return false }
        await takeAway(needs: [need], center: center)
        return true
    }

    /// Takes away every notification shown or waiting for these needs.
    @MainActor static func takeAway(needs: Set<String>, center: UNUserNotificationCenter = .current()) async {
        let shown = await center.deliveredNotifications().map { ($0.request.identifier, $0.request.content.userInfo) }
        let waiting = await center.pendingNotificationRequests().map { ($0.identifier, $0.content.userInfo) }
        center.removeDeliveredNotifications(withIdentifiers: identifiers(of: needs, in: shown))
        center.removePendingNotificationRequests(withIdentifiers: identifiers(of: needs, in: waiting))
    }

    /// The identifiers of the notifications, of those given, that are about one of `needs`.
    static func identifiers(of needs: Set<String>, in notifications: [(String, [AnyHashable: Any])]) -> [String] {
        notifications.compactMap { identifier, info in
            guard let need = info[PushUserInfo.need] as? String, needs.contains(need) else { return nil }
            return identifier
        }
    }
}
