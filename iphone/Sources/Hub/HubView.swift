import EngineKit
import PiModels
import SwiftUI

/// A project's hub: the orchestrator's conversation, with the tab bar Chat · Now · Work · More, which is the Mac's board
/// on a phone (docs/design/iphone.md, "A project's hub"). The Chat tab draws the orchestrator's conversation through its
/// route; Now is the Mac's Now tab; Work and More are the issues that build them (#694; #696 and #697). A badge on Now
/// counts what needs the person in the project.
struct HubView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// The tab it opens on.
    let tab: HubTab

    @Environment(AppSession.self) private var session
    @State private var selection: HubTab

    init(projectID: String, tab: HubTab = .chat) {
        self.projectID = projectID
        self.tab = tab
        _selection = State(initialValue: tab)
    }

    var body: some View {
        let engine = session.engine
        Group {
            if let project = engine.hubProject(projectID) {
                tabs(project, needs: engine.hubNeeds(projectID).count)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            HubTitle(project: project)
                        }
                    }
            } else {
                HubMissing(waiting: engine.status != .connected || !engine.hasLoadedLibrary)
            }
        }
        .navigationTitle(engine.hubProject(projectID)?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        // The route opened on another tab of this same hub (`openRoute(.project(id, tab:))`) changes the tab in place.
        .onChange(of: tab) { _, tab in selection = tab }
    }

    private func tabs(_ project: ProjectRow, needs: Int) -> some View {
        TabView(selection: $selection) {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: HubTab.chat) {
                HubChatTab(project: project)
            }
            Tab("Now", systemImage: "bolt", value: HubTab.now) {
                HubNowTab(project: project)
            }
            .badge(needs)
            Tab("Work", systemImage: "checklist", value: HubTab.work) {
                FeaturePlaceholder(screen: "Work", issue: 694, details: ["The project's work list, a piece of work, giving it to an agent, filing"])
                    .environment(\.placement, .inline)
                    .frame(maxHeight: .infinity)
            }
            Tab("More", systemImage: "ellipsis", value: HubTab.more) {
                FeaturePlaceholder(screen: "More", issue: 696, details: ["Agents, Rules, Notes, Branches: #696", "The project's settings and limits: #697"])
                    .environment(\.placement, .inline)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// What the hub shows when the project is not among the Mac's: while the engine's lists are still coming, a wait;
/// once they have come, that the Mac has no such project.
private struct HubMissing: View {
    let waiting: Bool

    var body: some View {
        if waiting {
            ProgressView("Waiting for your Mac…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No such project", systemImage: "questionmark.folder",
                description: Text("Your Mac has no project by this name now. It may have been deleted.")
            )
        }
    }
}
