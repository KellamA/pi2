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
    /// The 90% stage is never notified (#232): it is information, and the Dashboard has it.
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

    /// One thing waiting under Needs you, as the `needs` event sends it (docs/projects.md, 3.9; #481). What it asks is
    /// what the card asks.
    func needsYou(_ need: NeedItem) {
        guard enabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        let who = need.agentName ?? "An agent"
        content.title = switch need.kind {
        case "approval": "\(who) needs approval"
        case "question", "decision": "\(who) has a question"
        case "reach": "\(who) asks for more reach"
        case "rule": "\(who) proposes a rule"
        case "limit": "\(who) is held back by a limit"
        default: "\(who) needs you"
        }
        content.body = need.short
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: need.id, content: content, trigger: nil))
    }
}
