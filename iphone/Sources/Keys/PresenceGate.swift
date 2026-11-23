import SwiftUI
import UIKit

extension View {
    /// Shows this view only in an open session, and the lock screen otherwise (docs/iphone.md 4.5), and keeps the
    /// session's lifecycle: Face ID is asked when pi² comes to the foreground with no open session (and at launch),
    /// the session ends after a minute in the background and when the phone locks, and the view is covered while pi²
    /// is not in the foreground, so the app switcher's picture of it shows nothing (3.6). `isOn` false (no Mac paired)
    /// shows the view as it is.
    func presenceGate(_ session: PresenceSession, isOn: Bool = true) -> some View {
        modifier(PresenceGateModifier(session: session, isOn: isOn))
    }
}

struct PresenceGateModifier: ViewModifier {
    let session: PresenceSession
    let isOn: Bool

    @Environment(\.scenePhase) private var phase
    /// Whether pi² was in the background (or not yet shown) since Face ID was last asked: only then does coming to the
    /// foreground ask. Face ID's own sheet makes the app inactive and active again, which must not ask a second time.
    @State private var fromBackground = true

    private var showsContent: Bool { !isOn || (session.state == .open && phase == .active) }

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(showsContent ? 1 : 0)
                .allowsHitTesting(showsContent)
                .accessibilityHidden(!showsContent)
            if isOn {
                if session.state != .open {
                    PresenceLockScreen(session: session)
                } else if phase != .active {
                    PresenceCover()
                }
            }
        }
        .onChange(of: phase, initial: true) { _, phase in
            guard isOn else { return }
            switch phase {
            case .background:
                fromBackground = true
                session.movedToBackground()
            case .active:
                session.cameToForeground()
                if fromBackground {
                    fromBackground = false
                    if session.state == .locked { Task { await session.open() } }
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            if isOn { session.phoneWillLock() }
        }
    }
}

/// What covers pi² while it is not in the foreground: its mark on the background, nothing of what was open.
struct PresenceCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Text("π²")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
