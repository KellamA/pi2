import SwiftUI

/// What is running, what agents left running in the background, what the engine recovered, and what is scheduled.
struct ActivityView: View {
    @Bindable var model: AppModel
    @State private var editing: Schedule?
    @State private var creating = false
    private var engine: EngineClient { model.engine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let recovery = engine.recovery { recoveryBanner(recovery) }
                running
                if !engine.backgroundCommands.isEmpty { background }
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
        .sheet(item: $editing) { ScheduleSheet(engine: engine, original: $0) }
        .sheet(isPresented: $creating) { ScheduleSheet(engine: engine, original: nil) }
    }

    /// "2 running · 1 background command": the agents at work, then what they left running.
    private var subtitle: String {
        let commands = engine.backgroundCommands.count
        let left = commands == 0 ? nil : "\(commands) background command\(commands == 1 ? "" : "s")"
        let working = engine.activity.isEmpty ? nil : "\(engine.activity.count) running"
        let parts = [working, left].compactMap(\.self)
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }

    private func recoveryBanner(_ recovery: RecoveryReport) -> some View {
        let when = Date(timeIntervalSince1970: recovery.at / 1000).formatted(date: .omitted, time: .shortened)
        let left = recovery.background ?? []
        let setups = recovery.setups ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Label("The engine restarted after stopping unexpectedly (\(when))", systemImage: "arrow.clockwise.circle.fill")
                .font(.callout.weight(.semibold))
            if recovery.conversations.isEmpty && left.isEmpty && setups.isEmpty {
                Text("Nothing was running at the time. Everything is as it was.").font(.callout).foregroundStyle(.secondary)
            }
            if !recovery.conversations.isEmpty {
                Text("These conversations were working and were picked up from where they stopped. A model request that was cut off is sent again; a shell command that was cut off is not run again, and its agent is told.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(recovery.conversations) { conversation in
                    Button(conversation.title.isEmpty ? "New conversation" : conversation.title) {
                        model.selection = .conversation(conversation.id)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.acc)
                }
            }
            if !left.isEmpty {
                Text(leftIntro(left))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, recovery.conversations.isEmpty ? 0 : 4)
                ForEach(left) { command in
                    leftRow(title: command.title, conversation: command.rootConversationId, command: command.command, outcome: command.outcome, group: command.group, background: true)
                }
            }
            if !setups.isEmpty {
                Text(setupsIntro(setups))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, recovery.conversations.isEmpty && left.isEmpty ? 0 : 4)
                ForEach(setups) { setup in
                    leftRow(title: setup.title, conversation: setup.rootConversationId, command: setup.command, outcome: setup.outcome, group: setup.group, background: false)
                }
            }
            Button("Dismiss") { engine.perform("recovery.dismiss") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(fill: Theme.ok.opacity(0.08), border: Theme.ok.opacity(0.35))
    }

    /// What the notice says of the commands agents had left running in the background when the engine stopped.
    private func leftIntro(_ left: [RecoveryReport.LeftCommand]) -> String {
        let intro = left.count == 1
            ? "An agent had left a command running in the background. It is not started again; its conversation has a line about it, and its agent is told."
            : "Agents had left commands running in the background. None is started again; each conversation has a line about it, and its agent is told."
        let unsure = left.contains { ["partly", "unsure", "unknown"].contains($0.outcome) }
        return unsure ? intro + " pi² leaves alone whatever it cannot be sure belongs to a command, so part of one may still be running." : intro
    }

    /// What the notice says of the worktrees' set-up commands that were running when the engine stopped.
    private func setupsIntro(_ setups: [RecoveryReport.LeftSetup]) -> String {
        let intro = setups.count == 1
            ? "A worktree’s set-up command was running. It is not run again; its conversation has a line about it, and its agent is told."
            : "Set-up commands were running in new worktrees. None is run again; each conversation has a line about it, and its agent is told."
        let unsure = setups.contains { ["partly", "unsure", "unknown"].contains($0.outcome) }
        return unsure ? intro + " pi² leaves alone whatever it cannot be sure belongs to a set-up, so part of one may still be running." : intro
    }

    /// One command the last engine left, in the background or setting up a worktree: its conversation, the command, and
    /// what became of it.
    private func leftRow(title: String, conversation: Int, command: String, outcome: String, group: Int?, background: Bool) -> some View {
        let group = group.map { " (process group \($0))" } ?? ""
        let said: String
        switch outcome {
        case "stopped": said = "stopped"
        case "partly": said = "stopped in part; the rest may still be running\(group)"
        // A set-up that was not running any more had not finished: it was cut off.
        case "gone": said = background ? "had already ended" : "cut off"
        case "unsure", "unknown": said = "left alone; it may still be running\(group)"
        default: said = "ended"
        }
        let settled = outcome == "stopped" || outcome == "gone"
        return VStack(alignment: .leading, spacing: 1) {
            Button(title.isEmpty ? "New conversation" : title) {
                model.selection = .conversation(conversation)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.acc)
            .lineLimit(1).truncationMode(.tail)
            .help(background ? "Open the conversation that started it" : "Open the conversation whose worktree it was setting up")
            // The command is what gets cut short; what became of it keeps its size.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(command.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(Theme.mono).foregroundStyle(Theme.tx2)
                    .lineLimit(1).truncationMode(.tail)
                    .help(command)
                Text("·").foregroundStyle(Theme.tx3)
                Text(said)
                    .font(.callout).foregroundStyle(settled ? Theme.tx2 : Theme.warn)
                    .fixedSize()
            }
        }
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

    /// Commands agents started with `background: true` and left running: each with its conversation, and a way to stop it.
    private var background: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background commands").font(.headline)
            Text("Commands agents started and left running. Each runs until it ends, its agent or you stop it, its conversation is archived, or pi² stops.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(engine.backgroundCommands) { command in
                BackgroundCommandRow(model: model, command: command)
            }
        }
    }

    private var scheduled: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scheduled").font(.headline)
                Spacer()
                Button("New Schedule…", systemImage: "plus") { creating = true }
            }
            if engine.schedules.isEmpty {
                Text("Have an agent start a conversation on its own: every morning, every hour, or once at a set time.")
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.schedules) { schedule in
                HStack(spacing: 10) {
                    AgentAvatar(agent: engine.agent(schedule.agentId), size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(schedule.title)
                        Text(detail(schedule)).font(.caption).foregroundStyle(.secondary)
                    }
                    .help(origin(schedule))
                    Spacer()
                    if let last = schedule.lastConversationId, engine.conversations.contains(where: { $0.id == last }) {
                        Button("Last Run") { model.selection = .conversation(last) }.buttonStyle(.plain).foregroundStyle(Theme.acc)
                    }
                    Button("Run Now") { engine.perform("schedules.runNow", ["id": schedule.id]) }
                    Button("Edit…") { editing = schedule }
                    Button("Delete", systemImage: "trash", role: .destructive) { engine.perform("schedules.delete", ["id": schedule.id]) }
                        .labelStyle(.iconOnly)
                        .help("Delete this schedule")
                }
                .padding(10)
                .panel()
                .opacity(schedule.enabled ? 1 : 0.6)
            }
        }
    }

    private func detail(_ schedule: Schedule) -> String {
        let agent = engine.agent(schedule.agentId)?.name ?? "Unknown agent"
        // The person approved an agent's schedule once, perhaps long ago; this tells it apart from the ones they made.
        let setBy = schedule.createdBy.map { " · set by \(engine.agent($0.agentId)?.name ?? "a deleted agent")" } ?? ""
        guard schedule.enabled, let next = schedule.nextRunAt else { return "\(agent) · \(schedule.repeat.summary) · off\(setBy)" }
        let when = Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened)
        return "\(agent) · \(schedule.repeat.summary) · next \(when)\(setBy)"
    }

    /// Where an agent's schedule came from, for the row's tooltip.
    private func origin(_ schedule: Schedule) -> String {
        guard let createdBy = schedule.createdBy else { return "You made this schedule" }
        let agent = engine.agent(createdBy.agentId)?.name ?? "An agent that has since been deleted"
        let title = engine.conversations.first { $0.id == createdBy.conversationId }?.title ?? ""
        return title.isEmpty ? "\(agent) set this schedule, and you approved it" : "\(agent) set this schedule in “\(title)”, and you approved it"
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
                Text(run.title.isEmpty ? "New conversation" : run.title).lineLimit(1)
                Text(engine.agent(run.agentId)?.name ?? "Agent").font(.system(size: 11.5)).foregroundStyle(Theme.tx3)
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
            Button("Open") { model.selection = .conversation(run.rootConversationId) }
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

/// The shell command a run is waiting on: what it runs, for how long, and how long it has printed nothing once that is
/// a while (#196), so a stuck command can be told from a slow one. Ticks by itself; the engine sends only the times.
private struct CommandClockLine: View {
    let command: RunningCommand
    /// Other commands of the same run running beside it.
    let more: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let quiet = command.quiet(at: context.date)
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tx3)
                Text(command.command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command.command)
                    .font(Theme.mono).foregroundStyle(Theme.tx2)
                    .lineLimit(1).truncationMode(.tail)
                Text(command.elapsed(at: context.date)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.tx3)
                    .fixedSize()
                if let quiet {
                    Text(quiet).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.warn).fixedSize()
                }
                if more > 0 {
                    Text("and \(more) more").font(.system(size: 11.5)).foregroundStyle(Theme.tx3).fixedSize()
                }
            }
            .help(quiet == nil
                ? "Running for \(command.elapsed(at: context.date)): \(command.command)"
                : "Running for \(command.elapsed(at: context.date)), and nothing printed for a while. It may be waiting on something, such as a prompt on the screen. Stop stops the run.")
        }
    }
}

/// One command left running in the background: what it is, whose it is, for how long, its output, and Stop.
private struct BackgroundCommandRow: View {
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
            Button("Open") { model.selection = .conversation(command.rootConversationId) }
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

    private func elapsed(until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - command.startedAt / 1000))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ScheduleSheet: View {
    let engine: EngineClient
    /// Nil when creating.
    let original: Schedule?
    @State private var title = ""
    @State private var agentId = ""
    @State private var prompt = ""
    @State private var kind = "daily"
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var date = Date.now.addingTimeInterval(3600)
    @State private var weekday = 1
    @State private var minutesText = "60"
    @State private var enabled = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $title, prompt: Text("Morning brief"))
                    Picker("Agent", selection: $agentId) {
                        ForEach(engine.agents) { Text($0.name).tag($0.id) }
                    }
                }
                Section("What should it do?") {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Prompt")
                }
                Section("When") {
                    Picker("Repeat", selection: $kind) {
                        Text("Every day").tag("daily")
                        Text("Every week").tag("weekly")
                        Text("Every few minutes").tag("interval")
                        Text("Once").tag("once")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch kind {
                    case "once":
                        DatePicker("At", selection: $date, in: Date.now...)
                    case "interval":
                        TextField("Every (minutes)", text: $minutesText)
                    case "weekly":
                        Picker("Day", selection: $weekday) {
                            ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                        }
                        DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                    default:
                        DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                    }
                    Toggle("On", isOn: $enabled)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20) }
            HStack {
                Text("Each run starts a new conversation. Runs missed while the engine was off happen once when it starts.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add Schedule" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 540, height: 560)
        .onAppear(perform: load)
    }

    private func load() {
        agentId = engine.agents.first?.id ?? ""
        guard let original else { return }
        title = original.title
        agentId = original.agentId
        prompt = original.prompt
        kind = original.repeat.kind
        enabled = original.enabled
        weekday = original.repeat.weekday ?? 1
        minutesText = String(original.repeat.minutes ?? 60)
        if let at = original.repeat.at { date = Date(timeIntervalSince1970: at / 1000) }
        if let hour = original.repeat.hour, let minute = original.repeat.minute {
            time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? time
        }
    }

    private func save() {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        var rule = Repeat(kind: kind)
        switch kind {
        case "once": rule.at = (date.timeIntervalSince1970 * 1000).rounded()
        case "interval":
            guard let minutes = Int(minutesText.trimmingCharacters(in: .whitespaces)), minutes >= 1 else {
                error = "Enter the number of minutes between runs."
                return
            }
            rule.minutes = minutes
        default:
            rule.hour = clock.hour
            rule.minute = clock.minute
            if kind == "weekly" { rule.weekday = weekday }
        }
        let schedule = Schedule(id: original?.id ?? "", title: title, agentId: agentId, prompt: prompt, repeat: rule, enabled: enabled)
        Task {
            do {
                try await engine.call("schedules.save", ["schedule": schedule.payload(isNew: original == nil)])
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
