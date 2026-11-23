
import PiModels
import SwiftUI

/// The hub's More tab: the board's pages the tab bar has no room for, Agents, Rules, Notes and Branches, then the
/// project's settings and its other conversations (docs/design/iphone.md, "A project's hub"). Each row opens its screen
/// by its route, pushed onto the navigation stack.
struct HubMoreTab: View {
    let project: ProjectRow

    var body: some View {
        List {
            Section {
                row("Agents", icon: "person.2", .board(project: project.id, page: .agents))
                row("Rules", icon: "list.bullet.rectangle", .board(project: project.id, page: .rules))
                row("Notes", icon: "note.text", .board(project: project.id, page: .notes))
                row("Branches", icon: "arrow.triangle.branch", .board(project: project.id, page: .branches))
            }
            Section {
                row("Conversations", icon: "bubble.left.and.bubble.right", .conversations(project: project.id))
                row("Project Settings", icon: "gearshape", .projectSettings(project.id))
            }
        }
        .listStyle(.insetGrouped)
    }

    /// A row that pushes `route` onto the app's navigation stack, whose destinations are every route's view.
    private func row(_ title: LocalizedStringKey, icon: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.pi2Accent)
            }
        }
    }
}
