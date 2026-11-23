import EngineKit
import PiModels
import SwiftUI

/// What the schedule sheet holds while the person edits it, and the schedule it saves, made as the Mac's sheet makes it
/// (app/Sources/pi2/ScheduleViews.swift, `ScheduleSheet`).
struct ScheduleDraft: Equatable {
    var title = ""
    var agentID = ""
    var prompt = ""
    /// "daily", "weekly", "interval" or "once".
    var kind = "daily"
    /// The time of day of a daily or weekly schedule.
    var time: Date
    /// The moment of a schedule that runs once.
    var date: Date
    /// 0 is Sunday, as the engine counts.
    var weekday = 1
    var minutes = "60"
    var enabled = true

    /// The agent shown for the schedule being edited: the one it runs as, its project's copy for one carried over.
    let shownAgent: String?
    let original: Schedule?

    /// A new schedule, given to the first of `agents`, or one being edited.
    init(original: Schedule?, shownAgent: String?, firstAgent: String?, calendar: Calendar = .current, now: Date = .now) {
        self.original = original
        self.shownAgent = shownAgent
        time = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
        date = now.addingTimeInterval(3600)
        agentID = firstAgent ?? ""
        guard let original else { return }
        title = original.title
        agentID = shownAgent ?? original.agentId
        prompt = original.prompt
        kind = original.repeat.kind
        enabled = original.enabled
        weekday = original.repeat.weekday ?? 1
        minutes = String(original.repeat.minutes ?? 60)
        if let at = original.repeat.at { date = Date(timeIntervalSince1970: at / 1000) }
        if let hour = original.repeat.hour, let minute = original.repeat.minute {
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? time
        }
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agentID.isEmpty
    }

    /// The schedule to save, or why it cannot be.
    func schedule(calendar: Calendar = .current) -> Result<Schedule, SettingsLimitInput.Refusal> {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        var rule = Repeat(kind: kind)
        switch kind {
        case "once":
            rule.at = (date.timeIntervalSince1970 * 1000).rounded()
        case "interval":
            guard let every = Int(minutes.trimmingCharacters(in: .whitespaces)), every >= 1 else {
                return .failure(.init(text: "Enter the number of minutes between runs."))
            }
            rule.minutes = every
        default:
            rule.hour = clock.hour
            rule.minute = clock.minute
            if kind == "weekly" { rule.weekday = weekday }
        }
        // A carried schedule shows its project's copy; left as it was, it keeps its own agent, and so the copy (3.13).
        let chosen = original.map { agentID == shownAgent ? $0.agentId : agentID } ?? agentID
        return .success(Schedule(id: original?.id ?? "", title: title, agentId: chosen, prompt: prompt, repeat: rule, enabled: enabled))
    }
}

/// The sheet that makes a schedule or edits one: its name, its agent, what it should do, and when.
struct ScheduleEditor: View {
    /// Nil for a new schedule.
    let original: Schedule?
    /// The agents it may be given, the first chosen for a new one.
    let agents: [AgentProfile]
    let book: ScheduleBook

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: ScheduleDraft
    @State private var problem: String?
    @State private var saving = false

    init(original: Schedule?, agents: [AgentProfile], book: ScheduleBook) {
        self.original = original
        self.agents = agents
        self.book = book
        let shown = original.map { book.runsAs($0) }
        _draft = State(initialValue: ScheduleDraft(original: original, shownAgent: shown, firstAgent: agents.first?.id))
    }

    /// The choices, with the agent the schedule has now even when it is not among them.
    private var choices: [AgentProfile] {
        guard let shown = draft.shownAgent, !agents.contains(where: { $0.id == shown }), let agent = book.agent(shown) else { return agents }
        return [agent] + agents
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.title, prompt: Text("Morning brief"))
                    Picker("Agent", selection: $draft.agentID) {
                        ForEach(choices) { agent in
                            Text(agentLabel(agent)).tag(agent.id)
                        }
                    }
                    .settingsPickerStyle(dynamicTypeSize)
                }
                Section {
                    TextField("What should it do?", text: $draft.prompt, prompt: Text("Read what finished overnight and say what needs me first."), axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityLabel("What it should do")
                } header: {
                    Text("What should it do?")
                }
                Section {
                    Picker("Repeat", selection: $draft.kind) {
                        Text("Every day").tag("daily")
                        Text("Every week").tag("weekly")
                        Text("Every few minutes").tag("interval")
                        Text("Once").tag("once")
                    }
                    .settingsPickerStyle(dynamicTypeSize)
                    switch draft.kind {
                    case "once":
                        DatePicker("At", selection: $draft.date, in: Date.now...)
                    case "interval":
                        LabeledContent("Every") {
                            HStack {
                                TextField("Minutes", text: $draft.minutes)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel("Every how many minutes")
                                Text("minutes").foregroundStyle(.secondary)
                            }
                        }
                    case "weekly":
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                        }
                        .settingsPickerStyle(dynamicTypeSize)
                        DatePicker("At", selection: $draft.time, displayedComponents: .hourAndMinute)
                    default:
                        DatePicker("At", selection: $draft.time, displayedComponents: .hourAndMinute)
                    }
                    Toggle("On", isOn: $draft.enabled)
                } header: {
                    Text("When")
                } footer: {
                    Text("Each run starts a new conversation with the agent, which works with no one watching. Runs missed while the Mac’s engine was off happen once when it starts. Your Mac tells you of a schedule saved from here.")
                }
                if let problem {
                    Section { SettingsProblem(text: problem) }
                }
            }
            .navigationTitle(original == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? "Add" : "Save", action: save)
                        .disabled(!draft.canSave || saving || session.engine.status != .connected)
                }
            }
        }
    }

    /// "Forge · Demo project", so that two projects' agents of the same name are told apart.
    private func agentLabel(_ agent: AgentProfile) -> String {
        guard let project = agent.projectId.flatMap({ id in book.projects.first { $0.id == id } }) else { return "\(agent.name) · template" }
        return "\(agent.name) · \(project.name)"
    }

    private func save() {
        switch draft.schedule() {
        case .failure(let refusal):
            problem = refusal.text
        case .success(let schedule):
            saving = true
            Task {
                let refused = await SettingsRequest.saveSchedule(schedule, isNew: original == nil).send(through: session.engine)
                saving = false
                if let refused { problem = refused } else { dismiss() }
            }
        }
    }
}
