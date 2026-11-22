import SwiftUI

// Schedules (docs/schedules.md; in a project, docs/projects.md 3.13): which agent a schedule runs as, one schedule's
// row, a list of them with its buttons, and the editor. Shared by the old Activity page, a project's Settings tab and a
// template's page, and kept apart from Activity so that they outlive it (#483).

extension EngineClient {
    /// The agent a schedule runs as, by the engine's rule (`scheduleRunsAs`): the project's copy it was carried to while
    /// the preview is on and that copy can still be used, else its own agent.
    func runsAs(_ schedule: Schedule) -> String {
        guard projectsPreview, let id = schedule.projectAgentId, let copy = agent(id), copy.removedAt == nil else { return schedule.agentId }
        if let project = copy.projectId, projects.first(where: { $0.id == project })?.deletedAt != nil { return schedule.agentId }
        return id
    }

    /// A project's schedules: those whose agent, as they run, is one of its agents (3.13).
    func schedules(ofProject id: String) -> [Schedule] {
        schedules.filter { agent(runsAs($0))?.projectId == id }
    }

    /// A template's schedules, with the preview on: those that run as it, so not those carried to a project's copy.
    func schedules(ofTemplate id: String) -> [Schedule] {
        schedules.filter { runsAs($0) == id }
    }
}

/// Schedules with New Schedule…, and on each row Last Run, Run Now, Edit… and Delete. `agents` are those a schedule here
/// may be given, the first chosen for a new one; `shown` is the agent a row and the editor show for a schedule.
struct ScheduleList: View {
    let model: AppModel
    let schedules: [Schedule]
    let agents: [AgentProfile]
    /// What the list says while it is empty.
    let empty: String
    /// Rows in a card of their own each (Activity), or divided within the card they are put in (a tab, a form).
    var cards = false
    /// A heading with New Schedule… beside it, as Activity has; without one, the button comes after the rows.
    var heading: String? = nil
    @State private var editing: Schedule?
    @State private var creating = false
    @State private var problem: String?
    private var engine: EngineClient { model.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading {
                HStack {
                    Text(heading).font(.headline)
                    Spacer()
                    newButton
                }
            }
            if schedules.isEmpty {
                Text(empty).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                if cards {
                    row(schedule).padding(10).panel()
                } else {
                    if index > 0 { Divider().overlay(Theme.line) }
                    row(schedule)
                }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true) }
            if heading == nil {
                HStack {
                    Spacer()
                    newButton
                }
            }
        }
        .sheet(item: $editing) { ScheduleSheet(engine: engine, original: $0, agents: agents) }
        .sheet(isPresented: $creating) { ScheduleSheet(engine: engine, original: nil, agents: agents) }
    }

    private var newButton: some View {
        Button("New Schedule…", systemImage: "plus") { creating = true }
            .disabled(agents.isEmpty || engine.status != .connected)
    }

    private func row(_ schedule: Schedule) -> some View {
        HStack(spacing: 10) {
            AgentAvatar(agent: engine.agent(engine.runsAs(schedule)), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.title)
                Text(ScheduleWords.detail(schedule, engine)).font(.caption).foregroundStyle(.secondary)
            }
            .help(ScheduleWords.origin(schedule, engine))
            Spacer()
            if let last = schedule.lastConversationId, engine.conversations.contains(where: { $0.id == last }) {
                Button("Last Run") { openRun(last) }.buttonStyle(.plain).foregroundStyle(Theme.acc)
                    .help("Open the conversation its last run started")
            }
            Button("Run Now") { act("schedules.runNow", schedule) }
                .disabled(schedule.holdReason != nil || engine.status != .connected)
            Button("Edit…") { editing = schedule }
            Button("Delete", systemImage: "trash", role: .destructive) { act("schedules.delete", schedule) }
                .labelStyle(.iconOnly)
                .help("Delete this schedule")
        }
        .opacity(schedule.enabled && schedule.holdReason == nil ? 1 : 0.6)
    }

    /// A run opens where it lives: in place of its project's board with the preview on, else as a conversation.
    private func openRun(_ id: Int) {
        if let project = engine.conversations.first(where: { $0.id == id })?.projectId, engine.project(project) != nil {
            model.openAgent(id, in: project)
        } else {
            model.selection = .conversation(id)
        }
    }

    private func act(_ method: String, _ schedule: Schedule) {
        Task {
            do {
                _ = try await engine.call(method, ["id": schedule.id])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The words of a schedule's row, the same wherever it is listed.
enum ScheduleWords {
    /// "Forge · Every day at 07:00 · next 22 Nov 2026 at 07:00 · set by Forge".
    @MainActor
    static func detail(_ schedule: Schedule, _ engine: EngineClient) -> String {
        let agent = engine.agent(engine.runsAs(schedule))?.name ?? "Unknown agent"
        // The person approved an agent's schedule once, perhaps long ago; this tells it apart from the ones they made.
        let setBy = schedule.createdBy.map { " · set by \(engine.agent($0.agentId)?.name ?? "a deleted agent")" } ?? ""
        if let reason = schedule.holdReason { return "\(agent) · Held: \(reason)\(setBy)" }
        guard schedule.enabled, let next = schedule.nextRunAt else { return "\(agent) · \(schedule.repeat.summary) · off\(setBy)" }
        let when = Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened)
        return "\(agent) · \(schedule.repeat.summary) · next \(when)\(setBy)"
    }

    /// Where an agent's schedule came from, for the row's tooltip.
    @MainActor
    static func origin(_ schedule: Schedule, _ engine: EngineClient) -> String {
        guard let createdBy = schedule.createdBy else { return "You made this schedule" }
        let agent = engine.agent(createdBy.agentId)?.name ?? "An agent that has since been deleted"
        let title = engine.conversations.first { $0.id == createdBy.conversationId }?.title ?? ""
        return title.isEmpty ? "\(agent) set this schedule, and you approved it" : "\(agent) set this schedule in “\(title)”, and you approved it"
    }
}

struct ScheduleSheet: View {
    let engine: EngineClient
    /// Nil when creating.
    let original: Schedule?
    /// The agents it may be given, the first chosen for a new schedule.
    let agents: [AgentProfile]
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

    /// The agent shown for the schedule being edited: the one it runs as, its project's copy for one carried over.
    private var shownAgent: String? { original.map { engine.runsAs($0) } }

    /// The choices, with the agent the schedule has now even when it is not among them.
    private var choices: [AgentProfile] {
        guard let shown = shownAgent, !agents.contains(where: { $0.id == shown }), let agent = engine.agent(shown) else { return agents }
        return [agent] + agents
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $title, prompt: Text("Morning brief"))
                    Picker("Agent", selection: $agentId) {
                        ForEach(choices) { Text($0.name).tag($0.id) }
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
        agentId = agents.first?.id ?? ""
        guard let original else { return }
        title = original.title
        agentId = shownAgent ?? original.agentId
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
        // A carried schedule shows its project's copy; left as it was, it keeps its own agent, and so the copy (3.13).
        let chosen = original.map { agentId == shownAgent ? $0.agentId : agentId } ?? agentId
        let schedule = Schedule(id: original?.id ?? "", title: title, agentId: chosen, prompt: prompt, repeat: rule, enabled: enabled)
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
