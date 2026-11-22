import SwiftUI

// Activity with the Projects preview on (#655; docs/projects.md, 10.3): what keeps running on this Mac across every
// conversation, apart from the agents' runs. Those are on Now and the Dashboard, with Stop (#645), with the restart
// notice; schedules are each project's Settings tab's (#656). A view of its own rather than the old page with sections
// off, so that it outlives ActivityViews.swift, which goes with the old pages (#483), and so that what the old page
// shows with the switch off stays exactly as it was.

/// Background commands left running and models running on this Mac, each with what can be done to it.
struct ActivityPage: View {
    let model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if engine.backgroundCommands.isEmpty && engine.localRunning.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing is running in the background").font(.headline)
                        Text("Commands an agent leaves running, and models running on this Mac, show here with a way to stop them. The agents at work are on each project’s Now tab and on the Dashboard.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !engine.backgroundCommands.isEmpty { BackgroundCommandsSection(model: model) }
                if !engine.localRunning.isEmpty { LocalModelsActivity(model: model) }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .navigationTitle("Activity")
        .navigationSubtitle(ActivityCounts(engine: engine).words ?? "Nothing running in the background")
    }
}

/// How many background commands and models on this Mac are running, in words: "2 background commands · 1 model on this
/// Mac". Nil when neither is.
@MainActor
struct ActivityCounts {
    let engine: EngineClient

    var commands: Int { engine.backgroundCommands.count }
    var models: Int { engine.localRunning.count }

    var words: String? {
        let parts = [
            commands == 0 ? nil : "\(commands) background command\(commands == 1 ? "" : "s")",
            models == 0 ? nil : "\(models) model\(models == 1 ? "" : "s") on this Mac",
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The row of Activity under Shared in the sidebar of projects: how many things it lists, with what they are in its
/// help. A view of its own, as the old row's badges are, so that a command starting or ending draws only this.
struct ActivityRowBadge: View {
    let engine: EngineClient

    var body: some View {
        let counts = ActivityCounts(engine: engine)
        if let words = counts.words {
            Tag("\(counts.commands + counts.models)", .acc).fixedSize()
                .help(words)
                .accessibilityLabel(words)
        }
    }
}

/// Commands agents started with `background: true` and left running: each with its conversation, and a way to stop it.
struct BackgroundCommandsSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background commands").font(.headline)
            Text("Commands agents started and left running. Each runs until it ends, its agent or you stop it, its conversation is archived, or pi² stops.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.engine.backgroundCommands) { command in
                BackgroundCommandRow(model: model, command: command)
            }
        }
    }
}

/// One command left running in the background: what it is, whose it is, for how long, its output, and Stop.
struct BackgroundCommandRow: View {
    let model: AppModel
    let command: BackgroundCommand
    /// Set when Stop was pressed: the row stays until the engine says the command is gone, which can take a few seconds.
    @State private var stopping = false
    @Environment(\.openWindow) private var openWindow
    private var engine: EngineClient { model.engine }

    /// The conversation that started it: a sub-chat's command names the sub-chat, and opens the conversation it belongs to.
    private var conversation: ConversationSummary? { engine.conversations.first { $0.id == command.conversationId } }

    private var source: String {
        let title = conversation?.title ?? ""
        let agent = engine.agent(conversation?.agentId)?.name
        return [title.isEmpty ? "New conversation" : title, agent, engine.folderName(command.cwd)].compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tx2)
                .frame(width: 22, height: 22)
                .background(Theme.line2.opacity(0.5), in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(command.command.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(Theme.mono)
                    .lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(command.command)
                Text(source).font(.system(size: 11.5)).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.middle)
            }
            // The command takes the room the rest of the row leaves, and is what gets cut short: the id, the time and the
            // buttons keep their size.
            .frame(maxWidth: .infinity, alignment: .leading)
            Tag(stopping ? "stopping" : command.id, stopping ? .warn : .neutral)
                .fixedSize()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(until: context.date)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tx2)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .fixedSize()
            Button("Output") { openWindow(id: BackgroundOutputScene.id, value: command.id) }
                .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
                .help("Show what it has printed, as it prints it")
            Button("Open", action: open)
                .buttonStyle(PiButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
                .help("Open the conversation that started it")
            Button("Stop", systemImage: "stop.fill") {
                stopping = true
                engine.perform("background.stop", ["id": command.id])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
            .disabled(stopping)
            .fixedSize()
            .help("Stop this command and everything it started")
        }
        .padding(10)
        .panel()
    }

    /// With the projects preview on, the conversation that started it, a sub-chat's in place of the board; with it off,
    /// the conversation it belongs to, in the old panes, as before.
    private func open() {
        if engine.projectsPreview {
            model.openConversation(command.conversationId, from: command.rootConversationId == command.conversationId ? nil : command.rootConversationId)
        } else {
            model.openConversation(command.rootConversationId)
        }
    }

    private func elapsed(until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - command.startedAt / 1000))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
