import SwiftUI

/// What is running, what the engine recovered, and what is scheduled.
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
                scheduled
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .navigationTitle("Activity")
        .navigationSubtitle(engine.activity.isEmpty ? "Nothing running" : "\(engine.activity.count) running")
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

    private func recoveryBanner(_ recovery: RecoveryReport) -> some View {
        let when = Date(timeIntervalSince1970: recovery.at / 1000).formatted(date: .omitted, time: .shortened)
        return VStack(alignment: .leading, spacing: 6) {
            Label("The engine restarted after stopping unexpectedly (\(when))", systemImage: "arrow.clockwise.circle.fill")
                .font(.callout.weight(.semibold))
            if recovery.conversations.isEmpty {
                Text("Nothing was running at the time. Everything is as it was.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("These conversations were working and were picked up from where they stopped. A model request that was cut off is sent again; a shell command that was cut off is not run again, and its agent is told.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(recovery.conversations) { conversation in
                    Button(conversation.title.isEmpty ? "New conversation" : conversation.title) {
                        model.selection = .conversation(conversation.id)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.acc)
                }
            }
            Button("Dismiss") { engine.perform("recovery.dismiss") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(fill: Theme.ok.opacity(0.08), border: Theme.ok.opacity(0.35))
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
        guard schedule.enabled, let next = schedule.nextRunAt else { return "\(agent) · \(schedule.repeat.summary) · off" }
        let when = Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened)
        return "\(agent) · \(schedule.repeat.summary) · next \(when)"
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
            }
            Spacer()
            if run.status == "waiting" {
                Tag("waiting for you", .warn)
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
