import SwiftUI

/// Every screen the app can open (docs/iphone-app.md; docs/design/iphone.md, "The screens"). A screen opens another
/// only by its route, with `@Environment(\.openRoute)`, never by naming its view, so that each feature's folder is its
/// own: `RouteView` is the one place that maps a route to a feature's view.
enum Route: Hashable, Sendable {
    /// The projects list, with Needs you at the top: the root (#685, `Home/`).
    case home
    /// A project's hub on one of its tabs (#688, `Hub/`), by the project's id.
    case project(String, tab: HubTab = .chat)
    /// The Dashboard's pages, one for each watched project, opened at this project's page or the first (#688,
    /// `Dashboard/`).
    case dashboard(project: String? = nil)
    /// A conversation on its own screen: an orchestrator's or an agent's (#687, `Conversation/`), by its id.
    case conversation(Int)
    /// What needs the person, of one project or of all (#686, `Needs/`).
    case needs(project: String? = nil)
}

/// The tabs of a project's hub (docs/design/iphone.md, "A project's hub"): Chat · Now · Work · More.
enum HubTab: String, CaseIterable, Hashable, Sendable {
    case chat, now, work, more
}

/// Where a feature's view is drawn: as a screen of its own, pushed or at the root, or inside another feature's screen
/// (`RouteView(route, placement: .inline)`), such as Needs you at the top of the projects list or the orchestrator's
/// conversation in a hub's Chat tab. A view reads it with `@Environment(\.placement)` and leaves out what only a whole
/// screen has (a navigation title, its own scrolling).
enum Placement: Hashable, Sendable {
    case screen
    case inline
}

/// Opens a route: `openRoute(.conversation(id))`. `.home` goes back to the projects list; any other route is pushed onto
/// the navigation stack, except a project's hub opened from that same hub, which changes its tab in place.
struct OpenRoute {
    let action: @MainActor (Route) -> Void

    @MainActor func callAsFunction(_ route: Route) {
        action(route)
    }
}

extension EnvironmentValues {
    /// Opens a route. Outside the app's root (a preview, a test) it does nothing.
    @Entry var openRoute = OpenRoute { _ in }
    @Entry var placement = Placement.screen
}

/// A route's view: the one place that names each feature's entry view. A feature draws another feature inside its own
/// screen with this, never with the other's view.
struct RouteView: View {
    let route: Route
    let placement: Placement

    init(_ route: Route, placement: Placement = .screen) {
        self.route = route
        self.placement = placement
    }

    var body: some View {
        AnyView(Self.view(for: route))
            .environment(\.placement, placement)
    }

    /// Each route's entry view, by the initialiser its feature agreed to (docs/iphone-app.md).
    static func view(for route: Route) -> any View {
        switch route {
        case .home: HomeView()
        case .project(let id, let tab): HubView(projectID: id, tab: tab)
        case .dashboard(let project): DashboardView(projectID: project)
        case .conversation(let id): ConversationView(conversationID: id)
        case .needs(let project): NeedsView(projectID: project)
        }
    }
}

/// The navigation stack's path, which `openRoute` changes.
@MainActor
@Observable
final class Navigator {
    var path: [Route] = []

    func open(_ route: Route) {
        switch route {
        case .home:
            path = []
        case .project(let id, _):
            if case .project(let top, _) = path.last, top == id {
                path[path.count - 1] = route
            } else {
                path.append(route)
            }
        default:
            path.append(route)
        }
    }
}
