import EngineKit
import PiModels
import SwiftUI

/// A project's settings and limits, as grouped settings, from its hub's More tab (docs/design/iphone.md, "Every screen
/// and function of the Mac app": another shape). The Mac's board Settings tab on a phone (app/Sources/pi2/
/// ProjectSettingsTab.swift): the project's name and folder, the attached repository, the orchestrator's model and
/// summary size, what the orchestrator may do without asking (the Mac's Agents tab, docs/projects.md 8.1), whether
/// reports wake it, the limits that hold back starts with the plan's window and today's spending beside them, the
/// project's schedules, and archiving and deleting it. Each change is sent as it is made, as the Mac sends it, and the
/// engine's refusal is shown under the control that made it.
struct ProjectSettingsView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String

    init(projectID: String) {
        self.projectID = projectID
    }

    @Environment(AppSession.self) private var session

    var body: some View {
        let source = SettingsSource(session)
        Group {
            if let project = source.project(projectID) {
                ProjectSettingsForm(project: project, source: source)
            } else if source.waiting {
                ProgressView("Waiting for your Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No such project", systemImage: "questionmark.folder",
                    description: Text("Your Mac has no project by this name now. It may have been deleted.")
                )
            }
        }
        .navigationTitle("Project Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The form itself, for a project the engine has sent.
struct ProjectSettingsForm: View {
    let project: ProjectRow
    let source: SettingsSource

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var problems = SettingsProblems()
    @State private var name: String
    @State private var planShare: String
    @State private var dailySpend: String
    @FocusState private var focused: Field?
    @State private var confirming: Confirming?
    @State private var turningOn: ProjectSettingsSwitch?
    @State private var attaching = false
    @State private var editing: ScheduleEditing?

    private enum Field { case name, planShare, dailySpend }
    private enum Confirming: String, Identifiable {
        case archive, delete, detach
        var id: String { rawValue }
    }

    init(project: ProjectRow, source: SettingsSource) {
        self.project = project
        self.source = source
        _name = State(initialValue: project.name)
        _planShare = State(initialValue: project.settings?.limits.planShare.map(String.init) ?? "")
        _dailySpend = State(initialValue: SettingsLimitInput.text(project.settings?.limits.dailySpend))
    }

    private var engine: EngineSession<MessageField> { session.engine }
    private var connected: Bool { source.connected }
    private var orchestrator: AgentProfile? { source.agent(project.orchestratorId) }
    private var book: ScheduleBook { source.book }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if SettingsConnectionLine(connected: connected, connection: session.connection).shows || !source.samples.isEmpty {
                    Section {
                        SettingsConnectionLine(connected: connected, connection: session.connection)
                        #if DEBUG
                        SettingsSamples.note(source)
                        #endif
                    }
                }
                projectSection.id("project")
                repositorySection.id("repository")
                orchestratorSection.id("orchestrator")
                switchesSection.id("switches")
                reportsSection.id("reports")
                ProjectLiveActivitySection(project: project).id("live-activity")
                limitsSection.id("limits")
                schedulesSection.id("schedules")
                lifecycleSection.id("lifecycle")
            }
            #if DEBUG
            .task { await SettingsSamples.scroll(proxy) }
            // Once the Mac is reached: drawn first from the phone's last state, a change would only be refused.
            .task(id: connected) {
                guard connected else { return }
                if SettingsSamples.shouldPress("reports") {
                    send(.wakeOnReports(project: project.id, on: !(project.settings?.wakeOnReports ?? false)), row: "reports")
                }
                if let amount = SettingsSamples.pressArgument("daily-spend") {
                    dailySpend = amount
                    saveDailySpend()
                }
            }
            #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: project) { _, _ in sync() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            switch confirming {
            case .archive: Button("Archive") { send(.archive(project: project.id), row: "lifecycle") }
            case .delete: Button("Delete", role: .destructive) { send(.delete(project: project.id), row: "lifecycle") }
            case .detach: Button("Detach") { send(.detach(project: project.id), row: "repository") }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            switch confirming {
            case .archive: Text("The project leaves the list and nothing new starts in it. Its conversations, agents, rules and notes stay as they are. You can restore it whenever you like.")
            case .delete: Text("Its conversations keep their history, and show in the Archive under the project’s name, but its agents can no longer be started or handed work, and their schedules are held. Its rules, notes and work are kept, shown nowhere. This cannot be undone.")
            case .detach: Text("The project’s work list goes back to the one pi² keeps, as it was left.")
            case nil: EmptyView()
            }
        }
        .confirmationDialog(turningOn.map { "Turn on \($0.title)?" } ?? "", isPresented: Binding(get: { turningOn != nil }, set: { if !$0 { turningOn = nil } }), titleVisibility: .visible) {
            if let each = turningOn {
                Button("Turn On") { send(.withoutAsking(project: project.id, each.name, on: true), row: "switches") }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let each = turningOn { Text(each.confirmMessage) }
        }
        .sheet(isPresented: $attaching) {
            ProjectAttachSheet(projectID: project.id)
                .environment(session)
        }
        .sheet(item: $editing) { editing in
            switch editing {
            case .new:
                ScheduleEditor(original: nil, agents: book.agents(ofProject: project.id), book: book)
                    .environment(session)
            case .schedule(let id):
                if let schedule = book.schedules.first(where: { $0.id == id }) {
                    ScheduleEditor(original: schedule, agents: book.agents(ofProject: project.id), book: book)
                        .environment(session)
                }
            }
        }
    }

    // MARK: Project

    private var projectSection: some View {
        Section {
            HStack {
                TextField("Name", text: $name)
                    .focused($focused, equals: .name)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .accessibilityLabel("Project name")
                if trimmedName != project.name {
                    Button("Rename", action: saveName)
                        .disabled(trimmedName.isEmpty || !connected)
                }
            }
            SettingsProblem(text: problems["name"])
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder").font(.subheadline).foregroundStyle(.secondary)
                if let folder = project.folder {
                    Text(folder)
                        .font(.footnote.monospaced())
                        .lineLimit(8)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("No folder").foregroundStyle(.secondary)
                }
                if project.folderMissing == true {
                    Label("The folder is not there any more.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Project")
        } footer: {
            Text("The folder is where the project’s agents work. It is chosen on the Mac for now: choosing from the folders your Mac offers comes with new projects on the phone.")
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Repository

    private var repositorySection: some View {
        Section {
            if let repository = project.repository {
                LabeledContent("GitHub", value: "\(repository.owner)/\(repository.name)")
                Button("Detach the Repository", role: .destructive) { confirming = .detach }
                    .disabled(!connected)
            } else {
                LabeledContent("GitHub", value: "None")
                Button("Attach a Repository…") { attaching = true }
                    .disabled(project.folder == nil || !connected)
            }
            SettingsProblem(text: problems["repository"])
        } header: {
            Text("Repository")
        } footer: {
            Text(project.folder == nil && project.repository == nil
                ? "A project with no folder cannot attach a repository."
                : "The attached repository’s issues and pull requests are the project’s work list, on the Work tab. Attaching and detaching is yours alone; agents ask.")
        }
    }

    // MARK: Orchestrator

    private var orchestratorSection: some View {
        Section {
            if let orchestrator {
                Picker("Model", selection: Binding(
                    get: { orchestrator.model },
                    set: { ref in if let ref, ref != orchestrator.model { send(.agentModel(orchestrator, ref), row: "orchestrator") } }
                )) {
                    if let current = orchestrator.model {
                        if !source.allModels.contains(where: { $0.ref == current }) {
                            Text(current.modelId).tag(ModelRef?.some(current))
                        }
                    } else {
                        Text("Default for agents").tag(ModelRef?.none)
                    }
                    ForEach(source.modelGroups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.models, id: \.ref) { model in
                                Text(model.listName).tag(ModelRef?.some(model.ref))
                            }
                        }
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(!connected)
                Picker("Summarise at", selection: Binding(
                    get: { orchestrator.compactionTokens },
                    set: { tokens in if tokens != orchestrator.compactionTokens { send(.agentCompaction(orchestrator, tokens), row: "orchestrator") } }
                )) {
                    Text("The default (\(source.compaction?.tokens.map(SettingsCompaction.label) ?? "off"))").tag(Int?.none)
                    Text("Off").tag(Int?.some(0))
                    ForEach(SettingsCompaction.choices(including: orchestrator.compactionTokens), id: \.self) { tokens in
                        Text(SettingsCompaction.label(tokens)).tag(Int?.some(tokens))
                    }
                }
                .settingsPickerStyle(dynamicTypeSize)
                .disabled(!connected)
            } else {
                Text("The Mac has not sent the orchestrator’s agent.").foregroundStyle(.secondary)
            }
            SettingsProblem(text: problems["orchestrator"])
        } header: {
            Text("Orchestrator")
        } footer: {
            Text("The model the orchestrator answers on, and the size at which its conversation’s earlier messages are summarised, so later turns read less. Either changes the orchestrator’s agent, from its next message.")
        }
    }

    // MARK: What the orchestrator may do

    private var switchesSection: some View {
        Section {
            ForEach(ProjectSettingsSwitch.all) { each in
                Toggle(isOn: Binding(
                    get: { project.allows(each.name) },
                    set: { on in
                        if on { turningOn = each } else { send(.withoutAsking(project: project.id, each.name, on: false), row: "switches") }
                    }
                )) {
                    Text(each.title)
                    Text(each.allows)
                }
                .disabled(!connected || project.settings?.withoutAsking == nil)
            }
            SettingsProblem(text: problems["switches"])
        } header: {
            Text("What the orchestrator may do")
        } footer: {
            Text("A switch that is off makes each thing it governs wait for you under Needs you. Allow everything, which ends all asking for an agent, is turned on only on the Mac.")
        }
    }

    // MARK: Reports

    private var reportsSection: some View {
        Section {
            Toggle("Reports wake the orchestrator", isOn: Binding(
                get: { project.settings?.wakeOnReports ?? false },
                set: { on in send(.wakeOnReports(project: project.id, on: on), row: "reports") }
            ))
            .disabled(!connected || project.settings == nil)
            SettingsProblem(text: problems["reports"])
        } footer: {
            Text("A finished piece of work wakes the orchestrator, which reads the report and hands the work on; off, it waits for its next turn. Past a limit, nothing wakes it.")
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        Section {
            limitRow(
                title: "Plan window used", unit: "%", prefix: nil, text: $planShare, field: .planShare,
                accessibility: "Plan window used limit, in percent", isSet: project.settings?.limits.planShare != nil,
                line: planShareLine, row: "planShare", save: savePlanShare
            )
            limitRow(
                title: "Spent today", unit: nil, prefix: "$", text: $dailySpend, field: .dailySpend,
                accessibility: "Spent today limit, in dollars", isSet: project.settings?.limits.dailySpend != nil,
                line: dailySpendLine, row: "dailySpend", save: saveDailySpend
            )
            SettingsRouteRow(title: "Usage and limits", symbol: "chart.bar") { openRoute(.usage) }
        } header: {
            Text("Limits")
        } footer: {
            Text("pi² holds every start in the project to these limits, whatever an agent remembers. It cannot check a command that goes round it: an agent with a shell can run its own git or gh, or change pi²’s files.")
        }
    }

    private func limitRow(
        title: String, unit: String?, prefix: String?, text: Binding<String>, field: Field, accessibility: String, isSet: Bool,
        line: String, row: String, save: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                if let prefix { Text(prefix).foregroundStyle(.secondary) }
                TextField("No limit", text: text)
                    .keyboardType(field == .planShare ? .numberPad : .decimalPad)
                    .focused($focused, equals: field)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .accessibilityLabel(accessibility)
                if let unit { Text(unit).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("Set") {
                    focused = nil
                    save()
                }
                .buttonStyle(.bordered)
                .disabled(!connected)
            }
            if isSet {
                Button("No Limit") {
                    text.wrappedValue = ""
                    focused = nil
                    save()
                }
                .buttonStyle(.borderless)
                .disabled(!connected)
            }
            Text(line)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsProblem(text: problems[row])
        }
        .padding(.vertical, 4)
    }

    /// What the plan limit says now, with the most-used window of the plans the Mac has read.
    private var planShareLine: String {
        guard let value = project.settings?.limits.planShare else {
            return "With a limit, no start while a window of the plan the started agent would run on is this much used. A new project starts at 90%."
        }
        var line = "No start while a window of the plan the started agent would run on is \(value)% used or more."
        if let plan = source.plan {
            if let top = SettingsPlanWindow.mostUsed(plan, at: .now) {
                line += " Now: \(top.line(at: .now))."
            } else {
                line += " No reading of a plan yet, so it holds nothing back until Usage reads one."
            }
        }
        return line
    }

    private var dailySpendLine: String {
        let spent = source.spentToday.map { $0[project.id] ?? 0 }
        guard let value = project.settings?.limits.dailySpend else {
            let now = spent.map { " Today so far: \(SettingsMoney.text($0))." } ?? ""
            return "With a limit, no start once the project’s conversations have cost this much today, sub-chats included. pi²’s own daily budget applies on top.\(now)"
        }
        let start = spent.map { "\(SettingsMoney.text($0)) of \(SettingsMoney.text(value)) spent today, sub-chats included." } ?? "\(SettingsMoney.text(value)) a day, sub-chats included."
        return "\(start) No start once it reaches this; pi²’s own daily budget applies on top."
    }

    // MARK: Schedules

    private var schedulesSection: some View {
        Section {
            let schedules = book.schedules(ofProject: project.id)
            if schedules.isEmpty {
                Text("Have one of the project’s agents start a conversation on its own: every morning, every hour, or once at a set time.")
                    .foregroundStyle(.secondary)
            }
            ForEach(schedules) { schedule in
                ScheduleRow(schedule: schedule, book: book, connected: connected, edit: { editing = .schedule(schedule.id) }) { request in
                    send(request, row: "schedules")
                }
            }
            // Text alone: a disabled button's symbol keeps the tint in a form, and would look as if it could be pressed.
            Button("New Schedule…") { editing = .new }
                .disabled(book.agents(ofProject: project.id).isEmpty || !connected || project.archivedAt != nil)
            SettingsProblem(text: problems["schedules"])
        } header: {
            Text("Schedules")
        } footer: {
            Text("Each run starts a new conversation of the project with its agent, which works with no one watching. Swipe a schedule to run it now or turn it off.")
        }
    }

    // MARK: Archive and delete

    private var lifecycleSection: some View {
        Section {
            if project.archivedAt != nil {
                Button("Restore the Project") { send(.restore(project: project.id), row: "lifecycle") }
                    .disabled(!connected)
            } else {
                Button("Archive the Project") { confirming = .archive }
                    .disabled(!connected)
            }
            Button("Delete the Project…", role: .destructive) { confirming = .delete }
                .disabled(!connected)
            SettingsProblem(text: problems["lifecycle"])
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if project.archivedAt != nil {
                    Text("This project is archived: nothing new starts in it. Restore it to continue.")
                }
                Text("Face ID opened pi²; nothing is asked again. Your Mac tells you of each change from here that widens what agents may do.")
            }
        }
    }

    // MARK: Sending

    private var confirmTitle: String {
        switch confirming {
        case .archive: "Archive “\(project.name)”?"
        case .delete: "Delete “\(project.name)”?"
        case .detach: "Detach \(project.repository.map { "\($0.owner)/\($0.name)" } ?? "the repository")?"
        case nil: ""
        }
    }

    private func send(_ request: SettingsRequest, row: String) {
        request.send(through: engine, row: row, into: $problems)
    }

    /// Keeps the fields with the project, except the one being edited, so a change made elsewhere (an agent's, the Mac's)
    /// does not overwrite what the person is typing.
    private func sync() {
        if focused != .name { name = project.name }
        if focused != .planShare { planShare = project.settings?.limits.planShare.map(String.init) ?? "" }
        if focused != .dailySpend { dailySpend = SettingsLimitInput.text(project.settings?.limits.dailySpend) }
    }

    private func saveName() {
        let given = trimmedName
        guard given != project.name, !given.isEmpty else {
            name = project.name
            problems["name"] = nil
            return
        }
        send(.rename(project: project.id, to: given), row: "name")
    }

    private func savePlanShare() {
        switch SettingsLimitInput.planShare(planShare) {
        case .success(let percent): send(.planShare(project: project.id, percent), row: "planShare")
        case .failure(let refusal): problems["planShare"] = refusal.text
        }
    }

    private func saveDailySpend() {
        switch SettingsLimitInput.dailySpend(dailySpend) {
        case .success(let dollars): send(.dailySpend(project: project.id, dollars), row: "dailySpend")
        case .failure(let refusal): problems["dailySpend"] = refusal.text
        }
    }
}

/// Attaching a GitHub repository: `owner/name`, or left empty for the one the project's folder already points at.
struct ProjectAttachSheet: View {
    let projectID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var problem: String?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("owner/name", text: $repository)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(attach)
                        .accessibilityLabel("Repository, as owner slash name")
                } footer: {
                    Text("The repository’s issues and pull requests become the project’s work list, on the Work tab. Leave it empty to attach the repository the project’s folder already points at (its origin remote).")
                }
                if let problem {
                    Section { SettingsProblem(text: problem) }
                }
            }
            .navigationTitle("Attach a Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Attach", action: attach)
                        .disabled(sending || session.engine.status != .connected)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func attach() {
        sending = true
        Task {
            let given = repository.trimmingCharacters(in: .whitespaces)
            let refused = await SettingsRequest.attach(project: projectID, repository: given.isEmpty ? nil : given).send(through: session.engine)
            sending = false
            if let refused { problem = refused } else { dismiss() }
        }
    }
}
