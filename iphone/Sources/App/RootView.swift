
import SwiftUI

/// The app's one navigation root (docs/iphone-app.md): the first screen while no Mac is paired and the demo is off;
/// otherwise a navigation stack on the projects list, onto which `openRoute` pushes each route's view, under the Demo bar
/// while the demo is on (#684). A paired Mac's screens are behind the lock screen outside a session Face ID opened
/// (`.presenceGate`), and the window is covered in the app switcher. pi²'s accent is the tint of all of it.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(PhoneLink.self) private var link: PhoneLink?
    @Environment(PhoneSurfaces.self) private var surfaces: PhoneSurfaces?
    @Environment(\.scenePhase) private var phase
    @State private var navigator = Navigator()
    #if DEBUG
    @State private var shown = false
    #endif

    /// Which screen is the root, for the session's connection: the first screen while nothing is paired and the demo
    /// is off, else the projects list.
    enum Screen: Equatable {
        case firstScreen
        case projects
    }

    nonisolated static func screen(for connection: AppSession.Connection) -> Screen {
        connection == .notPaired ? .firstScreen : .projects
    }

    var body: some View {
        gated
            .coveredInAppSwitcher()
            .tint(.pi2Accent)
            .environment(\.openRoute, OpenRoute { [navigator] route in navigator.open(route) })
            .onChange(of: phase) { _, phase in
                switch phase {
                case .active:
                    if let swept = link?.store.sweep() { surfaces?.swept(swept) }
                case .background:
                    link?.store.saveNow()
                    surfaces?.movedToBackground()
                default: break
                }
            }
            // At launch too: the share sheet's drafts and the Live Activities are taken in hand in the foreground.
            .onChange(of: phase, initial: true) { _, phase in
                if phase == .active { surfaces?.movedToForeground() }
            }
            // A widget's or a Live Activity's tap: its route waits until Face ID has opened the session.
            .onOpenURL { url in surfaces?.open(url) }
            .onChange(of: surfaces?.pendingRoute, initial: true) { _, _ in openPendingRoute() }
            .onChange(of: isOpen) { _, _ in openPendingRoute() }
            .onChange(of: Self.screen(for: session.connection)) { _, _ in openPendingRoute() }
            #if DEBUG
            .onChange(of: session.engine.projects, initial: true) { _, projects in
                guard !shown, let route = DebugLaunch.current?.route(projects: projects) else { return }
                shown = true
                navigator.open(route)
            }
            #endif
    }

    /// Whether the screens are shown: nothing paired, or a session Face ID opened.
    private var isOpen: Bool {
        guard let link, link.paired else { return true }
        return link.keyring.session.state == .open
    }

    /// Opens the route a widget, a notification or a Live Activity asked for, once the screens are shown and the projects
    /// list is the root.
    private func openPendingRoute() {
        guard let surfaces, let route = surfaces.pendingRoute, isOpen, Self.screen(for: session.connection) == .projects else { return }
        surfaces.pendingRoute = nil
        navigator.open(.home)
        if route != .home { navigator.open(route) }
    }

    @ViewBuilder private var gated: some View {
        if let link {
            content.presenceGate(link.keyring.session, isOn: link.paired)
        } else {
            content
        }
    }

    /// Under the projects list, while anything the person wrote waits for the Mac or was not sent: the Outbox's line,
    /// which opens it.
    @ViewBuilder private var outboxLine: some View {
        if let link, link.paired, link.store.isOpen, Self.outboxShows(link.outbox.items) {
            Button { navigator.open(.outbox) } label: {
                RouteView(.outbox, placement: .inline)
            }
            .buttonStyle(.plain)
            .environment(link.outbox)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// Whether the Outbox's line shows: something waits, or was not sent (`OutboxLine` counts both).
    nonisolated static func outboxShows(_ items: [OutboxItem]) -> Bool {
        items.contains { item in
            if item.isPending { return true }
            if case .notSent = item.state { return true }
            return false
        }
    }

    @ViewBuilder private var content: some View {
        switch Self.screen(for: session.connection) {
        case .firstScreen:
            FirstScreen()
        case .projects:
            NavigationStack(path: $navigator.path) {
                RouteView(.home)
                    .toolbar {
                        if let link, link.paired {
                            // The design names no place for Lock; Settings (#697) is to hold it too, in its first rows.
                            ToolbarItem(placement: .topBarLeading) {
                                PresenceLockButton(session: link.keyring.session)
                            }
                        }
                    }
                    .navigationDestination(for: Route.self) { route in
                        RouteView(route)
                    }
                    .safeAreaInset(edge: .bottom) { outboxLine }
            }
            // The Outbox is the store's, which opens with the session Face ID opened: before that its screen says so.
            .environment(link.flatMap { $0.store.isOpen ? $0.outbox : nil })
            .safeAreaInset(edge: .bottom) {
                if let link, let problem = link.connection?.problem {
                    ConnectionProblemNotice(problem: problem, tryAgain: { link.tryAgain() })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .demoBar()
        }
    }
}
