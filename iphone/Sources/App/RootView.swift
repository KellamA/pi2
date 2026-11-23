import SwiftUI

/// The app's one navigation root (docs/iphone-app.md): the first screen while no Mac is paired and the demo is off;
/// otherwise a navigation stack on the projects list, onto which `openRoute` pushes each route's view, under the Demo bar
/// while the demo is on (#684). pi²'s accent is the tint of all of it.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @State private var navigator = Navigator()
    #if DEBUG
    @State private var shown = false
    #endif

    var body: some View {
        Group {
            if session.connection == .notPaired {
                FirstScreen()
            } else {
                NavigationStack(path: $navigator.path) {
                    RouteView(.home)
                        .navigationDestination(for: Route.self) { route in
                            RouteView(route)
                        }
                }
                .demoBar()
            }
        }
        .tint(.pi2Accent)
        .environment(\.openRoute, OpenRoute { [navigator] route in navigator.open(route) })
        #if DEBUG
        .onChange(of: session.engine.projects, initial: true) { _, projects in
            guard !shown, let route = DebugLaunch.current?.route(projects: projects) else { return }
            shown = true
            navigator.open(route)
        }
        #endif
    }
}
