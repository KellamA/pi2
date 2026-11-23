import EngineKit
import PiModels
import SwiftUI

/// The Dashboard on a phone: a page for each watched project, swiped sideways (docs/design/iphone.md, "The Dashboard on
/// a phone"). A strip along the top names the pages, with a mark on any that needs the person or has agents working;
/// each page shows what needs the person, who is working, what finished today and the orchestrator's last words; the
/// field at the foot messages the orchestrator of the page shown. The Mac's columns, one per page.
struct DashboardView: View {
    /// The project whose page it opens on, as `ProjectRow.id`; nil for the first.
    let projectID: String?

    @Environment(AppSession.self) private var session
    @State private var watched = DashboardWatched.shared
    /// The page shown, by project id.
    @State private var page: String?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }

    var body: some View {
        let engine = session.engine
        let listed = engine.hubListedProjects
        let pages = watched.watched(listed)
        Group {
            if pages.isEmpty {
                DashboardEmpty(waiting: engine.status != .connected || !engine.hasLoadedLibrary, anyListed: !listed.isEmpty)
            } else {
                TabView(selection: $page) {
                    ForEach(pages) { project in
                        DashboardPage(project: project)
                            .tag(Optional(project.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .safeAreaInset(edge: .top, spacing: 0) {
                    DashboardStrip(pages: pages, page: $page)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let project = pages.first(where: { $0.id == page }) {
                        DashboardField(project: project)
                            .id(project.id)
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !listed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(listed) { project in
                            Toggle(project.name, isOn: Binding(
                                get: { watched.watching(project.id, listed: listed) },
                                set: { _ in watched.toggle(project.id, listed: listed) }
                            ))
                        }
                    } label: {
                        Label("Projects", systemImage: "square.grid.2x2")
                    }
                    .accessibilityHint("Choose the projects the Dashboard shows a page for.")
                }
            }
        }
        // Opened at the project asked for once it is known; a page that goes (unticked, archived) gives way to the first.
        .onChange(of: pages.map(\.id), initial: true) { _, ids in
            if page == nil || !ids.contains(page ?? "") {
                page = DashboardWatched.opening(page == nil ? projectID : nil, in: pages)
            }
        }
    }
}

/// What the Dashboard shows with no page: while the engine's lists are coming, a wait; with no project, how one is made;
/// with every project unticked, how to tick one.
private struct DashboardEmpty: View {
    let waiting: Bool
    let anyListed: Bool

    var body: some View {
        if waiting {
            ProgressView("Waiting for your Mac…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if anyListed {
            ContentUnavailableView(
                "Nothing watched", systemImage: "square.grid.2x2",
                description: Text("Choose the projects to show here with Projects, above.")
            )
        } else {
            ContentUnavailableView(
                "No projects yet", systemImage: "square.grid.2x2",
                description: Text("A project made on your Mac, from a folder, shows here with a page of its own.")
            )
        }
    }
}
