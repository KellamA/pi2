
import SwiftUI

/// The bar across the top of every screen in the demo mode (docs/iphone.md 9.4; the drafts' figure 5): it says
/// **Demo** and that nothing here is real, shows a notification of every kind, and **Leave** goes back to the first
/// screen, forgetting what the demo changed. It draws nothing outside the demo. The app's root puts it above every
/// screen with `.demoBar()`; it also opens the screen a demo notification's button asked for.
struct DemoBar: View {
    @Environment(AppSession.self) private var session: AppSession?
    @Environment(\.openRoute) private var openRoute
    @State private var demo = DemoMode.shared
    @State private var confirmsLeaving = false
    @State private var problem: String?

    var body: some View {
        if let session, session.connection == .demo {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // The whole line where it fits; at the largest text sizes, Demo alone, so the bar stays one line.
                ViewThatFits(in: .horizontal) {
                    Text("**Demo** · nothing here is real")
                    Text("**Demo**")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Demo mode. Nothing here is real: no Mac, no network.")
                .accessibilityAddTraits(.isHeader)
                Button {
                    Task {
                        problem = await DemoNotifications.shared.showEveryKind(needs: session.engine.needs, projects: session.engine.projects)
                    }
                } label: {
                    Image(systemName: "bell.badge")
                }
                .accessibilityLabel("Show a notification of each kind")
                .accessibilityHint("They arrive over the next few seconds, as they would from your Mac.")
                Button("Leave") { confirmsLeaving = true }
                    .fontWeight(.semibold)
                    .accessibilityHint("Goes back to the first screen and forgets what you did in the demo.")
            }
            .font(.subheadline)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .foregroundStyle(.tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    Rectangle().fill(.bar)
                    Rectangle().fill(.tint.opacity(0.14))
                }
                .ignoresSafeArea(edges: .top)
            }
            .confirmationDialog("Leave the demo?", isPresented: $confirmsLeaving, titleVisibility: .visible) {
                Button("Leave the Demo") { DemoMode.leave(session) }
            } message: {
                Text("What you did in it is forgotten.")
            }
            .alert("No notifications", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .onChange(of: demo.asked, initial: true) { _, route in
                guard let route else { return }
                demo.asked = nil
                openRoute(route)
            }
        }
    }
}

extension View {
    /// Puts the Demo bar above this view, while the demo is on. The view goes below it, navigation bar and all, rather
    /// than under it.
    func demoBar() -> some View {
        VStack(spacing: 0) {
            DemoBar()
            self
        }
    }
}

#Preview("Demo bar") {
    let session = AppSession(connection: .demo)
    return NavigationStack {
        List { Text("A screen of the demo") }
            .navigationTitle("pi²")
    }
    .demoBar()
    .environment(session)
}
