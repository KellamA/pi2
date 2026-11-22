import SwiftUI

/// What is running, what agents left running in the background, what the engine recovered, and what is scheduled.
struct ActivityView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let recovery = engine.recovery {
                    RecoveryNotice(engine: engine, recovery: recovery, open: { _, root in model.openConversation(root) })
                }
                running
                if !engine.localRunning.isEmpty { LocalModelsActivity(model: model) }
                if !engine.backgroundCommands.isEmpty { BackgroundCommandsSection(model: model) }
                scheduled
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Stop All", systemImage: "stop.fill") {
                    for run in engine.activity where run.parent == nil { engine.perform("abort", ["id": run.conversationId]) }
                }
                .labelStyle(.titleAndIcon)
                .disabled(engine.activity.isEmpty)
                .help("Stop every running conversation")
            }
        }
    }

    /// "2 running · 1 background command": the agents at work, then what they left running.
    private var subtitle: String {
        let commands = engine.backgroundCommands.count
        let left = commands == 0 ? nil : "\(commands) background command\(commands == 1 ? "" : "s")"
        // A run waiting for a provider's limit is not counted as running (#343).
        let waiting = engine.limitWaits.count
        let running = engine.activity.count - waiting
        let counts = [running > 0 ? "\(running) running" : nil, waiting > 0 ? "\(waiting) waiting for a limit" : nil].compactMap(\.self)
        let working = counts.isEmpty ? nil : counts.joined(separator: ", ")
        let models = engine.localRunning.count
        let loaded = models == 0 ? nil : "\(models) model\(models == 1 ? "" : "s") on this Mac"
        let parts = [working, loaded, left].compactMap(\.self)
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }

    /// Conversations in the sidebar that are working, plus any subagent whose parent is not itself listed.
    private var topLevelRuns: [ActivityRun] {
        let listed = Set(engine.activity.map(\.conversationId))
        return engine.activity.filter { run in run.parent == nil || !listed.contains(run.rootConversationId) }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running now").font(.headline)
            if engine.activity.isEmpty {
                Text("No agent is working right now.").foregroundStyle(.secondary)
            }
            // Top-level conversations first, each followed by its subagents.
            ForEach(topLevelRuns) { run in
                RunRow(model: model, run: run, indented: false)
                ForEach(engine.activity.filter { $0.parent != nil && $0.rootConversationId == run.conversationId }) { child in
                    RunRow(model: model, run: child, indented: true)
                }
            }
        }
    }

    // The list, its row and its editor are ScheduleViews.swift's, shared with a project's Settings tab and a template's
    // page (docs/projects.md, 3.13).
    private var scheduled: some View {
        ScheduleList(
            model: model,
            schedules: engine.schedules,
            agents: engine.agents,
            empty: "Have an agent start a conversation on its own: every morning, every hour, or once at a set time.",
            cards: true,
            heading: "Scheduled"
        )
    }
}

private struct RunRow: View {
    let model: AppModel
    let run: ActivityRun
    let indented: Bool
    private var engine: EngineClient { model.engine }

    var body: some View {
        HStack(spacing: 10) {
            if indented { Image(systemName: "arrow.turn.down.right").foregroundStyle(Theme.tx3) }
            AgentAvatar(agent: engine.agent(run.agentId), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title.isEmpty ? (run.chat == true ? "New chat" : "New conversation") : run.title).lineLimit(1)
                Text(run.chat == true ? "Chat" : engine.agent(run.agentId)?.name ?? "Agent").font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
                if let command = run.commands?.first {
                    CommandClockLine(command: command, more: (run.commands?.count ?? 1) - 1)
                }
            }
            Spacer()
            if run.status == "waiting" {
                Tag("waiting for you", .warn)
            } else if let wait = run.limit {
                Tag(wait.tag, .warn)
                    .help(wait.sentence)
            } else {
                Tag("running", .acc)
                Spinner()
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(until: context.date)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tx2)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            Button("Open") { model.openConversation(run.rootConversationId) }
                .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
            Button("Stop", systemImage: "stop.fill") { engine.perform("abort", ["id": run.conversationId]) }
                .labelStyle(.iconOnly)
                .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
                .help("Stop this run")
        }
        .padding(10)
        .padding(.leading, indented ? 18 : 0)
        .panel()
    }

    private func elapsed(until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - run.since / 1000))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
