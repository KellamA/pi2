import AppKit
import UserNotifications

/// Native notifications for things that need the person, when they have turned them on and the app is not in front.
@MainActor
final class Notifier {
    static let shared = Notifier()
    static let defaultsKey = "notifyWhenNeeded"

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    /// Asks macOS for permission. Returns whether notifications may be shown.
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func needsYou(_ item: InboxItem) {
        guard enabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = item.kind == "approval" ? "\(item.agentName ?? "An agent") needs approval" : "\(item.agentName ?? "An agent") has a question"
        // A browser action comes described in words; other calls are shown as they were written.
        let asked = item.tool == "browser" ? (item.question ?? "An action on a web page") : "\(item.tool): \(item.call.summary)"
        content.body = item.kind == "approval" ? asked : (item.question ?? "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }
}
