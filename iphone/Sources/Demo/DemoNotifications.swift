
import Foundation
import PiModels
import UserNotifications

/// The demo's notifications (docs/iphone.md 9.4 and section 7): a notification of every kind, scheduled on this iPhone
/// from what the demo holds, with the title, body, category and buttons a sealed push will carry once the Mac sends them
/// (P20 to P22). Nothing is registered for pushes and nothing leaves the phone: they are local notifications, which iOS
/// shows once the person has allowed notifications for pi² (the first time, iOS asks).
///
/// Every button opens pi² (`foreground`) and needs the phone unlocked (`authenticationRequired`), as section 7 says, and
/// opens the card it came from; answering from the notification itself is P22's. The categories here are the contract's;
/// P22 owns the app's own, and the two should come from one place (said on #684).
@MainActor
final class DemoNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DemoNotifications()

    /// The kinds of section 7, by their category's name.
    enum Kind: String, CaseIterable, Sendable {
        case approval, question, decision, reach, rule, limit, notice

        var category: String { "pi2.\(rawValue)" }
        /// The category of a notification whose body does not show the whole call, question or rule: without the button
        /// that would act on what was cut (section 7).
        var cutCategory: String { "pi2.\(rawValue).cut" }
    }

    /// Every identifier the demo's notifications start with, so that leaving takes away only those.
    static let prefix = "demo."
    /// The longest body, as section 7 allows.
    static let bodyLimit = 180

    private var center: UNUserNotificationCenter { .current() }

    /// Makes this the notification centre's delegate and sets the categories, as the demo starts.
    func install() {
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    /// Asks for notifications if iOS has not asked yet, then schedules one of every kind the demo holds, a second apart.
    /// Returns a line to show the person when they cannot be shown.
    func showEveryKind(needs: [NeedItem], projects: [ProjectRow]) async -> String? {
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard allowed else {
            return "Notifications are off for pi². To see the demo's, turn them on in the Settings app, under Notifications › pi²."
        }
        await clear()
        return await schedule(Self.requests(needs: needs, projects: projects))
    }

    /// Schedules the demo's notifications; returns a line to show the person when iOS refuses one.
    func schedule(_ requests: [UNNotificationRequest]) async -> String? {
        for request in requests {
            do {
                try await center.add(request)
            } catch {
                return "iOS did not take the demo's notifications: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// Takes away the demo's notifications, waiting and shown, as leaving the demo does.
    func clear() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        let shown = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: shown)
    }

    // MARK: - What they say

    /// One notification of each kind of card the demo holds (the newest of each), and a notice of an orchestrator's
    /// answer, a second apart from two seconds on.
    static func requests(needs: [NeedItem], projects: [ProjectRow], from start: TimeInterval = 2) -> [UNNotificationRequest] {
        var contents: [(String, UNNotificationContent)] = []
        for kind in Kind.allCases where kind != .notice {
            guard let need = needs.filter({ $0.kind == kind.rawValue }).max(by: { $0.createdAt < $1.createdAt }) else { continue }
            contents.append(("\(prefix)\(kind.rawValue).\(need.id)", content(for: need, project: projects.first { $0.id == need.projectId })))
        }
        if let project = projects.first(where: { $0.lastWords != nil && $0.conversation != nil }) {
            contents.append(("\(prefix)notice.\(project.id)", notice(project)))
        }
        return contents.enumerated().map { index, item in
            UNNotificationRequest(identifier: item.0, content: item.1, trigger: UNTimeIntervalNotificationTrigger(timeInterval: start + Double(index), repeats: false))
        }
    }

    /// A card's notification: the agent and the kind as the title, the project and the card's short line as the body,
    /// the kind's category, and the project as its thread.
    static func content(for need: NeedItem, project: ProjectRow?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let who = need.agentName ?? "An agent"
        let kind = Kind(rawValue: need.kind)
        content.title = switch kind {
        case .approval: "\(who) needs approval"
        case .question, .decision: "\(who) has a question"
        case .reach: "\(who) asks for more reach"
        case .rule: "\(who) proposes a rule"
        case .limit: "\(who) is held back by a limit"
        default: "\(who) needs you"
        }
        let short = need.short.replacingOccurrences(of: "\n", with: " ")
        let (body, whole) = Self.body(project: project?.name, short)
        content.body = body
        // The button that would act on what the body shows is offered only when it shows it whole (section 7).
        if let kind {
            content.categoryIdentifier = whole || ![.approval, .question, .rule].contains(kind) ? kind.category : kind.cutCategory
        }
        content.threadIdentifier = need.projectId ?? "none"
        content.sound = .default
        content.userInfo = ["need": need.id, "kind": need.kind, "projectId": need.projectId ?? "", "conversationId": need.conversationId]
        return content
    }

    /// An orchestrator's answer: "The orchestrator answered", and its last words.
    static func notice(_ project: ProjectRow) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "The orchestrator answered"
        content.body = body(project: project.name, project.lastWords?.text ?? "").text
        content.categoryIdentifier = Kind.notice.category
        content.threadIdentifier = project.id
        content.sound = .default
        content.userInfo = ["kind": Kind.notice.rawValue, "projectId": project.id, "conversationId": project.conversation ?? 0]
        return content
    }

    /// "Project · short line", cut at `bodyLimit` characters; and whether nothing was cut.
    static func body(project: String?, _ short: String) -> (text: String, whole: Bool) {
        let line = [project, short].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        guard line.count > bodyLimit else { return (line, true) }
        return (String(line.prefix(bodyLimit - 1)) + "…", false)
    }

    /// The categories of section 7, each with its buttons. Every button opens pi² on the card, with the phone unlocked.
    static var categories: Set<UNNotificationCategory> {
        let opens: UNNotificationActionOptions = [.foreground, .authenticationRequired]
        func action(_ id: String, _ title: String, destructive: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: destructive ? opens.union(.destructive) : opens)
        }
        let open = action("open", "Open")
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: opens, textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        func category(_ id: String, _ actions: [UNNotificationAction], placeholder: String) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: placeholder, options: [])
        }
        return [
            category(Kind.approval.category, [action("allowOnce", "Allow once"), action("deny", "Deny", destructive: true), open], placeholder: "An agent needs approval"),
            category(Kind.approval.cutCategory, [open, action("deny", "Deny", destructive: true)], placeholder: "An agent needs approval"),
            category(Kind.question.category, [reply, open], placeholder: "An agent has a question"),
            category(Kind.question.cutCategory, [open], placeholder: "An agent has a question"),
            category(Kind.decision.category, [open], placeholder: "An agent has a question"),
            category(Kind.reach.category, [action("allow", "Allow…"), action("refuse", "Refuse", destructive: true)], placeholder: "An agent asks for more reach"),
            category(Kind.rule.category, [action("accept", "Accept"), action("refuse", "Refuse", destructive: true), open], placeholder: "An agent proposes a rule"),
            category(Kind.rule.cutCategory, [action("refuse", "Refuse", destructive: true), open], placeholder: "An agent proposes a rule"),
            category(Kind.limit.category, [action("startAnyway", "Start anyway…"), action("wait", "Wait")], placeholder: "An agent is held back by a limit"),
            category(Kind.notice.category, [], placeholder: "pi²"),
        ]
    }

    /// Where a notification's button opens: the card's project's Needs you, or the orchestrator's conversation for a notice.
    static func route(kind: String?, projectID: String?, conversationID: Int?) -> Route? {
        if kind == Kind.notice.rawValue { return conversationID.flatMap { $0 > 0 ? .conversation($0) : nil } }
        let project = projectID.flatMap { $0.isEmpty ? nil : $0 }
        return .needs(project: project)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown while pi² is open too, as the demo is there to show them.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap or a button opens pi² on the card it came from (section 7: it never answers by itself).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        let project = info["projectId"] as? String
        let conversation = (info["conversationId"] as? NSNumber)?.intValue
        await MainActor.run {
            DemoMode.shared.asked = Self.route(kind: kind, projectID: project, conversationID: conversation)
        }
    }
}
