import os
import UserNotifications

/// pi²'s notification service extension (docs/iphone.md section 7), an empty shell for now: every push with
/// `mutable-content` passes through here before iOS shows it, and this one hands it on unchanged. #690 (P21) fills it:
/// opening `sealed` with the record key, checking the Mac's signature, always replacing the title and the body, setting
/// the category and the thread, and writing the item to the extension's own small file for the app to merge into its
/// store. What it shares with the app goes in `iphone/Sources/Push/`, which is built into both; how the extensions are
/// put together is "The extensions" in docs/iphone-app.md.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "dev.pi2.ios.notifications", category: "service")

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // A line in the simulator's log, so that a test push shows the extension ran (docs/iphone-app.md). Not built yet: #690.
        Self.log.notice("pi² notification service: delivered unchanged (not built yet: #690)")
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // didReceive hands every notification on at once, so there is nothing left to hand on here.
    }
}
