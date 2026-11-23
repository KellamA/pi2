import os
import UserNotifications

/// pi²'s notification service extension (docs/iphone.md section 7): every push with `mutable-content` passes through
/// here before iOS shows it. It opens `sealed` with the phone's record key and checks the Mac's signature, and always
/// replaces the title and the body: with what was inside the seal, under its kind's category (its buttons) and its
/// project's thread, or with *pi²: Something needs you* when the push has no seal or it does not open or verify. It keeps
/// what it showed in its own small file, for the app to merge into its store when the phone is unlocked.
///
/// The work is in `iphone/Sources/Push/`, which the app builds too and the unit tests reach: this file only hands
/// the push to `PushDelivery` and its answer to iOS.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "dev.pi2.ios.notifications", category: "service")

    private var handler: ((UNNotificationContent) -> Void)?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        PushCategories.register()
        let (content, outcome) = PushDelivery.deliver(request.content.userInfo, opener: PushOpeners.standard, keys: { try PushKeychain().keys() })
        if case let .shown(notice) = outcome {
            do {
                try PushInbox.shared?.keep(notice)
            } catch {
                Self.log.error("pi² notification service: the notice was shown but not kept for the app")
            }
        }
        // The outcome in fixed words, never the text (docs/remotekit.md, "Errors").
        Self.log.notice("pi² notification service: \(outcome.logLine, privacy: .public)")
        hand(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Never the push's own alert: if time ran out first, the placeholder (section 7).
        hand(PushDelivery.placeholder())
    }

    private func hand(_ content: UNNotificationContent) {
        guard let handler else { return }
        self.handler = nil
        handler(content)
    }
}
