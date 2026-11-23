import EngineKit
import PiModels
import SwiftUI

/// One project's page on the Dashboard: what needs the person, who is working and what finished today (the hub's Now,
/// without its switch), then what the orchestrator last said, and a button to the project's hub.
struct DashboardPage: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        ScrollViewReader { scroller in
            List {
                HubProjectSections(project: project, showsEmptyFinished: false)
                Section {
                    DashboardLastWords(project: project)
                        .id("words")
                } header: {
                    HubSectionHeader(title: "The orchestrator said")
                }
                Section {
                    Button {
                        openRoute(.project(project.id))
                    } label: {
                        Label("Open \(project.name)’s hub", systemImage: "rectangle.stack")
                    }
                }
            }
            .listStyle(.insetGrouped)
            #if DEBUG
            .task { await HubDebugScroll.scroll(scroller) }
            #endif
        }
    }
}

/// The orchestrator's last words, as the Mac's strip under a Dashboard column shows them, with how long ago; or that it
/// is answering now.
struct DashboardLastWords: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session

    var body: some View {
        let busy = session.engine.hubOrchestratorBusy(project)
        VStack(alignment: .leading, spacing: 6) {
            if let words = project.lastWords {
                Text(words.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.tint).frame(width: 2)
                    }
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Date(timeIntervalSince1970: words.at / 1000), format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                HubQuietLine(text: busy ? "The orchestrator is answering." : "The orchestrator has not answered yet.")
            }
            if busy, project.lastWords != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Answering now")
                }
                .font(.footnote)
                .foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
