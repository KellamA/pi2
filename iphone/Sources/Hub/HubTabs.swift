import EngineKit
import PiModels
import SwiftUI

/// The hub's Now tab: what needs the person, who is working now with the switch for reports waking the orchestrator,
/// and what finished today. While it shows, the engine is told so (`projects.watch`), as the Mac's Now tab does.
struct HubNowTab: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session

    var body: some View {
        ScrollViewReader { scroller in
            List {
                HubProjectSections(project: project, showsWakeSwitch: true)
            }
            .listStyle(.insetGrouped)
            #if DEBUG
            .task { await HubDebugScroll.scroll(scroller) }
            #endif
        }
        .onAppear { HubTabWatch.shared.shows(project.id, tab: .now, engine: session.engine) }
        .onDisappear { HubTabWatch.shared.hides(project.id, tab: .now, engine: session.engine) }
    }
}

/// The hub's Chat tab: the conversation with the orchestrator, full width, drawn by the conversation's own view through
/// its route. A project with no conversation yet (one carried over whose orchestrator was never opened, or whose
/// conversation was deleted) gets one as the tab opens, as the Mac's hub does.
struct HubChatTab: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session
    @State private var starting = false
    @State private var problem: String?

    var body: some View {
        if let id = project.conversation {
            RouteView(.conversation(id), placement: .inline)
                .id(id)
        } else if project.archivedAt != nil {
            ContentUnavailableView(
                "No conversation", systemImage: "archivebox",
                description: Text("This project is archived, and has no conversation with its orchestrator.")
            )
        } else {
            let live = HubRequests.isLive(session)
            ContentUnavailableView {
                Label(problem == nil ? "Starting the conversation" : "The conversation did not start", systemImage: "bubble.left.and.bubble.right")
            } description: {
                if let problem {
                    Text(problem)
                } else if live {
                    Text("This project has no conversation with its orchestrator yet. Your Mac is starting one.")
                } else {
                    Text("This project has no conversation with its orchestrator yet. Your Mac starts one once it is reached.")
                }
            } actions: {
                if problem != nil {
                    Button("Try Again") { start() }
                        .buttonStyle(.bordered)
                        .disabled(starting || !live)
                }
            }
            // Asked for once the Mac is reached, and again each time it is: tried against a copy (#688), a hub opened while
            // the phone still showed its store's last state was refused there ("can't be reached") and asked no more.
            .task(id: "\(project.id) \(live)") {
                if Self.startsNow(project, live: live, starting: starting) { start() }
            }
        }
    }

    /// Whether the Chat tab asks the Mac to start the orchestrator's conversation now: the project has none and is not
    /// archived, the phone reaches the Mac, and no start is under way.
    static func startsNow(_ project: ProjectRow, live: Bool, starting: Bool) -> Bool {
        project.conversation == nil && project.archivedAt == nil && live && !starting
    }

    private func start() {
        guard project.conversation == nil, project.archivedAt == nil, !starting else { return }
        starting = true
        problem = nil
        Task {
            problem = await HubRequests.startConversation(session.engine, project: project.id)
            starting = false
        }
    }
}

/// The hub's bar: the project's name, the branch its orchestrator works on and the orchestrator's model, with the plan's
/// week as a thin meter when a subscription reports one (docs/design/iphone.md, "A project's hub").
struct HubTitle: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session

    var body: some View {
        let engine = session.engine
        let details = [engine.hubBranch(project), engine.hubModelName(agent: project.orchestratorId)].compactMap { $0 }
        let week = engine.hubPlanWeek()
        VStack(spacing: 2) {
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let week {
                ProgressView(value: week.usedPercent, total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .tint(week.usedPercent >= 80 ? .orange : .accentColor)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([project.name] + details + (week.map { ["\($0.plan) week \(Int($0.usedPercent.rounded())) percent used"] } ?? [])).joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
        .accessibilityShowsLargeContentViewer {
            Text(project.name)
        }
    }
}
