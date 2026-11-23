import SwiftUI

/// Covers the window whenever pi² is not the active app (docs/iphone.md 3.6, "Nothing in the app switcher"): iOS takes
/// the picture the app switcher shows as the app leaves the foreground, and that picture must show nothing of a
/// conversation or a card. The cover comes as the scene stops being active, which is before iOS takes its picture; it
/// also shows while Notification Center or Control Center is pulled over pi², as a banking app's does.
///
/// `RootView` (App/, #680) puts it over everything: `.coveredInAppSwitcher()`.
struct AppSwitcherCover: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.overlay {
            if phase != .active {
                AppSwitcherCoverView()
                    .transition(.identity)
            }
        }
    }
}

extension View {
    /// Covers the view while the app is not active, so the app switcher's picture of it shows nothing.
    func coveredInAppSwitcher() -> some View {
        modifier(AppSwitcherCover())
    }
}

/// What the app switcher shows of pi²: its name, and nothing of what it held.
struct AppSwitcherCoverView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Text("pi²")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
