
import Foundation
import UIKit
import UserNotifications

/// pi²'s notifications as the app takes them (docs/iphone-app.md, "Pushes"; docs/iphone.md section 7): the categories
/// set at launch, the notification centre's delegate, whose tap opens the card's screen once Face ID has opened the
/// session, and a background push that takes a notification away (`Pi2AppDelegate`).
///
/// Nothing here asks iOS for anything the person must allow: setting the categories and the delegate raises no prompt.
/// Registering for remote notifications needs Push Notifications on the app's App ID (#682), and is not done here.
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    /// Where a tap goes: the app's `PhoneSurfaces`, set at launch.
    weak var surfaces: PhoneSurfaces?

    /// Sets section 7's categories and makes this the centre's delegate: at launch, and again when the demo, which
    /// installs its own, is left.
    func install(on center: UNUserNotificationCenter = .current()) {
        PushCategories.register(on: center)
        center.delegate = self
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown while pi² is open too: the person may be on another screen than the card's.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap or a button opens pi² on the card it came from; doing what a button chose is P22's (#691).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tapped = PushResponse(response)
        await MainActor.run {
            surfaces?.pushTapped(tapped)
        }
    }
}

extension PushResponse {
    /// The screen a notification opens (section 7): an orchestrator's answer opens its conversation; a card, its project's
    /// Needs you (all of Needs you for the placeholder, *pi²: Something needs you*, which names nothing).
    var route: Route {
        if kind == .notice {
            if let conversationId, conversationId > 0 { return .conversation(conversationId) }
            if let projectId, !projectId.isEmpty { return .project(projectId, tab: .chat) }
            return .home
        }
        return .needs(project: projectId.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The app delegate, for what SwiftUI's scene has no hook for: a background push (`remote-notification` in the app's
/// `UIBackgroundModes`), which iOS hands to the app, not to the service extension.
@MainActor
final class Pi2AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // A `pushGone`, opened and verified, takes its need's notifications away; anything else changes nothing.
        await PushRemoval.handle(userInfo) ? .newData : .noData
    }
}
