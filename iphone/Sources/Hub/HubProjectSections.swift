import EngineKit
import PiModels
import SwiftUI

/// What is happening in a project, as sections of a list: what needs the person (drawn by Needs you's own view, through
/// its route), who is working now, and what finished today. The hub's Now tab shows them (docs/design/iphone.md, "A
/// project's hub": Now "as it is"), with the project's switch for reports waking the orchestrator; a Dashboard page shows
/// them without it, as a Dashboard column does on the Mac.
struct HubProjectSections: View {
    let project: ProjectRow
    /// Whether the switch for reports waking the orchestrator shows (the Now tab's, not a Dashboard page's).
    var showsWakeSwitch = false
    /// Whether Finished today shows when nothing has finished yet, to say so.
    var showsEmptyFinished = true

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute

    /// The runs Stop was asked for, until the engine says they ended or it refused.
    @State private var stopping: Set<Int> = []
    /// What the engine said when a Stop was refused.
    @State private var stopProblem: String?
    /// The wake switch as the person last set it, until the engine's `projects` event says which it is, or refuses.
    @State private var wakeChoice: Bool?
    @State private var wakeProblem: String?

    private var engine: EngineSession<MessageField> { session.engine }
    private var waking: Bool { wakeChoice ?? project.settings?.wakeOnReports ?? false }

    var body: some View {
        let needs = engine.hubNeeds(project.id)
        let runs = engine.hubRuns(project.id)
        Group {
            Section {
                if needs.isEmpty {
                    HubQuietLine(text: "Nothing needs you right now.")
                } else {
                    RouteView(.needs(project: project.id), placement: .inline)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } header: {
                HubSectionHeader(title: "Needs you", count: needs.count)
            }

            Section {
                if runs.isEmpty {
                    HubQuietLine(text: "Nobody is working right now.")
                }
                ForEach(runs) { run in
                    HubWorkingRow(
                        engine: engine, run: run, stopping: stopping.contains(run.conversationId),
                        open: { openRoute(.conversation(run.conversationId)) },
                        stop: { stop(run) }
                    )
                }
                if let stopProblem {
                    HubProblem(text: stopProblem)
                        .id("stop-problem")
                }
                if showsWakeSwitch {
                    Toggle("Reports wake the orchestrator", isOn: wakeBinding)
                        .disabled(engine.status != .connected || project.archivedAt != nil)
                        .id("wake")
                    if let wakeProblem {
                        HubProblem(text: wakeProblem)
                    }
                }
            } header: {
                HubSectionHeader(title: "Working", count: runs.count)
            } footer: {
                if showsWakeSwitch {
                    Text("When a run the orchestrator handed out ends, its report is given to the orchestrator at once, instead of waiting to be read.")
                }
            }

            finished
        }
        .onChange(of: project.settings?.wakeOnReports) { _, _ in wakeChoice = nil }
        #if DEBUG
        .task {
            guard HubDebugAct.act != nil else { return }
            await HubDebugAct.whenLive(session)
            if showsWakeSwitch, HubDebugAct.take("wake") { wakeBinding.wrappedValue = true }
            if HubDebugAct.take("stop"), let first = HubDebugAct.stopTarget(in: engine.hubRuns(project.id), engine: engine) { stop(first) }
        }
        #endif
        // A run that has ended is no longer being stopped.
        .onChange(of: runs.map(\.conversationId)) { _, ids in stopping.formIntersection(ids) }
    }

    @ViewBuilder
    private var finished: some View {
        let reports = engine.hubReports(project.id)
        if !reports.isEmpty || showsEmptyFinished {
            Section {
                if reports.isEmpty {
                    HubQuietLine(text: "Nothing has finished today yet.")
                }
                ForEach(reports) { report in
                    HubFinishedRow(engine: engine, report: report)
                }
            } header: {
                HubSectionHeader(title: "Finished today", count: reports.count)
                    .id("finished")
            }
        }
    }

    private var wakeBinding: Binding<Bool> {
        Binding(
            get: { waking },
            set: { on in
                wakeChoice = on
                wakeProblem = nil
                Task {
                    if let problem = await HubRequests.setWake(engine, project: project.id, on: on) {
                        // Not taken: the switch shows what the engine still has.
                        wakeChoice = nil
                        wakeProblem = "The switch was not changed: \(problem)"
                    }
                }
            }
        )
    }

    private func stop(_ run: ActivityRun) {
        let id = run.conversationId
        guard !stopping.contains(id) else { return }
        stopping.insert(id)
        stopProblem = nil
        Task {
            if let problem = await HubRequests.stop(engine, conversation: id) {
                stopping.remove(id)
                let name = engine.agent(run.runsAs ?? run.agentId ?? "")?.name ?? "the agent"
                stopProblem = "Could not stop \(name): \(problem)"
            } else {
                // Taken: the run ends shortly. One that has not ended a while after can be stopped again, as on the Mac.
                try? await Task.sleep(for: .seconds(10))
                stopping.remove(id)
            }
        }
    }
}

/// A section's name, with its count when there is one: "Needs you · 3".
struct HubSectionHeader: View {
    let title: String
    var count: Int = 0

    var body: some View {
        Text(count > 0 ? "\(title) · \(count)" : title)
            .accessibilityAddTraits(.isHeader)
    }
}
