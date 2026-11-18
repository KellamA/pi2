import AppKit
import UserNotifications

/// Native notifications for things that need the person, when they have turned them on and the app is not in front.
@MainActor
final class Notifier {
    static let shared = Notifier()
    static let defaultsKey = "notifyWhenNeeded"
    /// Whether a subscription's limit being reached, and work carrying on, are notified (#343). On unless turned off.
    static let limitsKey = "notifyLimits"

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
    var limitsEnabled: Bool { UserDefaults.standard.object(forKey: Self.limitsKey) as? Bool ?? true }

    /// The stages of limit notices already seen, by notice id: each is notified once, when it is new.
    private var seenStages: [String: String]?

    /// The engine's limit notices changed. A notice that has come to `reached` or `carried_on` since the last look is
    /// notified, once; those there when the app first hears of them are not, so a launch is not a burst of old news.
    /// The 90% stage is never notified (#232): it is information, and the Inbox has it.
    func limitNotices(_ notices: [PlanLimits.Notice]) {
        let now = Dictionary(notices.map { ($0.id, $0.currentStage) }, uniquingKeysWith: { _, last in last })
        defer { seenStages = now }
        guard let seen = seenStages, limitsEnabled, !NSApp.isActive else { return }
        for notice in notices where seen[notice.id] != notice.currentStage {
            guard let words = notice.notification else { continue }
            let content = UNMutableNotificationContent()
            content.title = words.title
            content.body = words.body
            // Asks nothing of macOS: without its permission, the request is dropped.
            let request = UNNotificationRequest(identifier: "limit-\(notice.id)-\(notice.currentStage)", content: content, trigger: nil)
            Task {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                guard status == .authorized || status == .provisional else { return }
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }

    /// Asks macOS for permission. Returns whether notifications may be shown.
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func needsYou(_ item: InboxItem) {
        guard enabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = item.kind == "approval" ? "\(item.agentName ?? "An agent") needs approval" : "\(item.agentName ?? "An agent") has a question"
        // A browser action and a schedule come described in words; other calls are shown as they were written.
        let asked = switch item.tool {
        case "browser": item.question ?? "An action on a web page"
        case "schedule_task": item.question ?? "A new schedule"
        default: "\(item.tool): \(item.call.summary)"
        }
        content.body = item.kind == "approval" ? asked : (item.question ?? "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }
}
