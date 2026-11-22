import AppKit
import BrowserKit
import PiModels
import SwiftUI

/// The board's Settings tab (#478): the project's own settings — its name and folder, the attached repository, the
/// orchestrator's model, whether reports wake it, and the limits that hold back starts — each saved as it is changed,
/// with the project's schedules (3.13, #656), and archiving and deleting the project at the bottom, which are the
/// person's alone (docs/projects.md, 3.6 and 8).
/// What the orchestrator may do without asking (8.1) is on the Agents tab (#475).
struct ProjectSettingsTab: View {
    let model: AppModel
    let project: ProjectRow
    private var engine: EngineClient { model.engine }

    /// The engine's answer when a change failed, by the row that made it.
    @State private var problems: [String: String] = [:]
    /// The fields edited as text: the project's name and the two limits. Seeded from the project, and after that kept
    /// with it except while their field has the focus, so a change made elsewhere (an agent's, say) does not overwrite
    /// what the person is typing.
    @State private var drafts = Drafts()
    @FocusState private var focused: Field?
    @State private var attaching = false
    @State private var attachText = ""
    @State private var confirming: Confirming?

    private enum Field { case name, planShare, dailySpend }
    private enum Confirming: String, Identifiable {
        case archive, delete, detach
        var id: String { rawValue }
    }

    private struct Drafts {
        var name = ""
        var planShare = ""
        var dailySpend = ""
    }

    init(model: AppModel, project: ProjectRow) {
        self.model = model
        self.project = project
        _drafts = State(initialValue: Drafts(
            name: project.name,
            planShare: project.settings?.limits.planShare.map(String.init) ?? "",
            dailySpend: project.settings?.limits.dailySpend.map { String(format: "%g", $0) } ?? ""
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                projectSection
                repositorySection
                orchestratorSection
                reportsSection
                limitsSection
                schedulesSection
                bottomSection
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .onChange(of: project) { _, _ in sync() }
        .confirmationDialog(title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            switch confirming {
            case .archive: Button("Archive") { confirming = nil; lifecycle("projects.archive", "lifecycle") }
            case .delete: Button("Delete", role: .destructive) { confirming = nil; lifecycle("projects.delete", "lifecycle") }
            case .detach: Button("Detach") { confirming = nil; detachRepository() }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            switch confirming {
            case .archive: Text("The project leaves the sidebar and nothing new starts in it. Its conversations, agents, rules and notes stay as they are. You can restore it whenever you like.")
            case .delete: Text("Its conversations keep their history, and show in the Archive under the project’s name, but its agents can no longer be started or handed work, and their schedules are held. Its rules, notes and work are kept, shown nowhere. This cannot be undone.")
            case .detach: Text("The project’s work list goes back to the one pi² keeps, as it was left.")
            case nil: EmptyView()
            }
        }
        .sheet(isPresented: $attaching) { attachSheet }
    }

    // MARK: Project

    private var projectSection: some View {
        titled("Project", footer: "The folder is where the project’s agents work. New conversations of its agents start there; those working stay where they are.") {
            HStack(alignment: .center, spacing: 10) {
                Text("Name").rowLabel()
                TextField("Name", text: $drafts.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused, equals: .name)
                    .onSubmit(saveName)
                Button("Rename", action: saveName)
                    .buttonStyle(.piSecondary)
                    .disabled(drafts.name.trimmingCharacters(in: .whitespacesAndNewlines) == project.name || engine.status != .connected)
            }
            if let problem = problems["name"] { Text(problem).problemText() }
            Divider().overlay(Theme.line)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Folder").rowLabel()
                VStack(alignment: .leading, spacing: 2) {
                    if let folder = project.folder {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder)
                        if project.folderMissing == true {
                            Text("The folder is not there any more.").font(.caption).foregroundStyle(Theme.warn)
                        }
                    } else {
                        Text("No folder").font(Theme.mono).foregroundStyle(Theme.tx3)
                    }
                    if let problem = problems["folder"] { Text(problem).problemText() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFolder)
                    .buttonStyle(.piSecondary)
                    .disabled(engine.status != .connected)
            }
        }
    }

    // MARK: Repository

    private var repositorySection: some View {
        titled("Repository", footer: "The attached repository’s issues and pull requests are the project’s work list, on the Work tab. Attaching and detaching is yours alone; agents ask.") {
            HStack(alignment: .center, spacing: 10) {
                Text("GitHub").rowLabel()
                if let repository = project.repository {
                    Text("\(repository.owner)/\(repository.name)")
                        .font(Theme.mono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("The repository whose issues and pull requests are the project’s work list")
                    Button("Detach") { confirming = .detach }
                        .buttonStyle(.piSecondary)
                        .disabled(engine.status != .connected)
                } else {
                    Text("None").foregroundStyle(Theme.tx3).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Attach…") {
                        attachText = ""
                        problems["attach"] = nil
                        attaching = true
                    }
                    .buttonStyle(.piSecondary)
                    .disabled(project.folder == nil || engine.status != .connected)
                    .help(project.folder == nil ? "A project with no folder cannot attach a repository" : "Attach a GitHub repository, whose issues and pull requests become the project’s work list")
                }
            }
            if let problem = problems["repository"] { Text(problem).problemText() }
        }
    }

    private var attachSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attach a GitHub Repository").font(.title3.weight(.semibold))
            Text("The repository’s issues and pull requests become the project’s work list, on the Work tab.")
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("owner/name", text: $attachText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(attach)
                Button("Attach", action: attach)
                    .buttonStyle(.piPrimary)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { attaching = false }
            }
            Text("Leave it empty to attach the repository the project’s folder already points at (its origin remote).")
                .font(.callout)
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = problems["attach"] { Text(problem).problemText() }
        }
        .padding(18)
        .frame(width: 380)
    }

    // MARK: Orchestrator

    private var orchestratorSection: some View {
        titled("Orchestrator", footer: "The model the orchestrator answers on, and the size at which its conversation’s earlier messages are summarised, so later turns read less. Changing either changes the orchestrator’s agent, from its next message. The context meter in the conversation’s header summarises at once, or starts a fresh conversation.") {
            HStack(alignment: .center, spacing: 10) {
                Text("Model").rowLabel()
                OrchestratorModelMenu(engine: engine, agent: engine.agent(project.orchestratorId))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.line)
            HStack(alignment: .center, spacing: 10) {
                Text("Summarise at").rowLabel()
                OrchestratorSummarySize(engine: engine, agent: engine.agent(project.orchestratorId)) { problems["summaries"] = $0 }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem = problems["summaries"] { Text(problem).problemText() }
        }
    }

    // MARK: Reports

    private var reportsSection: some View {
        titled("Reports", footer: "A finished piece of work wakes the orchestrator, which reads the report and hands the work on; off, it waits for its next turn. A hand-off can ask for its own run to wake it. Past a limit, nothing wakes it.") {
            Toggle("Reports wake the orchestrator", isOn: Binding(
                get: { project.settings?.wakeOnReports ?? false },
                set: { on in setting(["wakeOnReports": on], "reports") }
            ))
            .disabled(engine.status != .connected)
            if let problem = problems["reports"] { Text(problem).problemText() }
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        titled("Limits", footer: "pi² holds every start in the project to these limits, whatever an agent remembers. It cannot check a command that goes round it: an agent with a shell can run its own git or gh, or change pi²’s files.") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan window used").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("No limit", text: $drafts.planShare)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($focused, equals: .planShare)
                        .onSubmit(savePlanShare)
                        .accessibilityLabel("Plan window used, in percent")
                    Text("%").foregroundStyle(Theme.tx3)
                    Button("Set", action: savePlanShare)
                        .disabled(engine.status != .connected)
                    if project.settings?.limits.planShare != nil {
                        Button("No Limit") { drafts.planShare = ""; savePlanShare() }
                            .disabled(engine.status != .connected)
                    }
                }
                if let value = project.settings?.limits.planShare {
                    Text(planShareLine(value)).foregroundStyle(Theme.tx2)
                } else {
                    Text("With a limit, no start while a window of the plan the started agent would run on is this much used. A new project starts at 90%.")
                        .foregroundStyle(Theme.tx2)
                }
                if let problem = problems["planShare"] { Text(problem).problemText() }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                Text("Spent today").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Text("$").foregroundStyle(Theme.tx3)
                    TextField("No limit", text: $drafts.dailySpend)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($focused, equals: .dailySpend)
                        .onSubmit(saveDailySpend)
                        .accessibilityLabel("Spent today limit, in dollars")
                    Button("Set", action: saveDailySpend)
                        .disabled(engine.status != .connected)
                    if project.settings?.limits.dailySpend != nil {
                        Button("No Limit") { drafts.dailySpend = ""; saveDailySpend() }
                            .disabled(engine.status != .connected)
                    }
                }
                if let value = project.settings?.limits.dailySpend {
                    Text("\(Formats.cost(spentToday)) of \(Formats.cost(value)) spent today, sub-chats included. No start once it reaches this; pi²’s own daily budget applies on top.")
                        .foregroundStyle(Theme.tx2)
                } else {
                    Text("With a limit, no start once the project’s conversations have cost this much today, sub-chats included. pi²’s own daily budget applies on top.")
                        .foregroundStyle(Theme.tx2)
                }
                if let problem = problems["dailySpend"] { Text(problem).problemText() }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the plan limit says now, with the most-used window of the plans Usage has read.
    private func planShareLine(_ value: Int) -> String {
        var line = "No start while a window of the plan the started agent would run on is \(value)% used or more. A new project starts at 90%."
        if let used = planWindowUsed {
            line += " Now: \(used)."
        } else {
            line += " No reading of a plan yet, so it holds nothing back until Usage reads one."
        }
        return line
    }

    /// The most-used window of the plans Usage has read, as the limit counts them (a window whose reset has passed
    /// does not count), or nil when none has been read.
    private var planWindowUsed: String? {
        let read = (PlanLimits(engine.extras["limits"])?.providers ?? []).flatMap { provider in
            (provider.windows ?? []).map { (provider: provider, window: $0) }
        }.filter { $0.window.resetsAt == nil || LimitsFormat.date($0.window.resetsAt!) > .now }
        guard let top = read.max(by: { $0.window.usedPercent < $1.window.usedPercent }) else { return nil }
        let when = top.window.resetsAt.map { ", resets \(LimitsFormat.exact(LimitsFormat.date($0)))" } ?? ""
        return "\(top.provider.name)\(top.provider.plan.map { " \($0)" } ?? ""), \(top.window.label): \(Int(top.window.usedPercent.rounded()))% used\(when)"
    }

    /// The project's cost today, as the `usage` event counts it.
    private var spentToday: Double {
        engine.usage?.projects?.first { $0.id == project.id }?.today.cost ?? 0
    }

    // MARK: Schedules

    /// The project's agents a schedule may be given: the orchestrator first, chosen for a new one, then the rest as made.
    private var scheduleAgents: [AgentProfile] {
        engine.allAgents
            .filter { $0.projectId == project.id && $0.removedAt == nil }
            .sorted { ($0.id == project.orchestratorId ? 0 : 1, $0.createdAt) < ($1.id == project.orchestratorId ? 0 : 1, $1.createdAt) }
    }

    private var schedulesSection: some View {
        titled("Schedules", footer: "Each run starts a new conversation of the project with its agent, which works with no one watching, and is listed with the project’s other conversations. A run with the orchestrator is a conversation of its own, beside the one you have with it: it has the orchestrator’s model and instructions, but cannot change the project, read reports or hand work to every agent. An agent that may schedule its own work asks you before each schedule it sets.") {
            ScheduleList(
                model: model,
                schedules: engine.schedules(ofProject: project.id),
                agents: scheduleAgents,
                empty: "Have one of the project’s agents start a conversation on its own: every morning, every hour, or once at a set time."
            )
        }
    }

    // MARK: Archive and delete

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Apart from the form above, which is kept as it is changed: these two are the person’s own, and one of them
            // cannot be undone.
            Divider().overlay(Theme.line).padding(.bottom, 4)
            if project.archivedAt != nil {
                Text("This project is archived: nothing new starts in it. Restore it to continue.")
                    .font(.callout)
                    .foregroundStyle(Theme.tx2)
                Button("Restore the Project") { lifecycle("projects.unarchive", "lifecycle") }
                    .buttonStyle(.piSecondary)
                    .disabled(engine.status != .connected)
            } else {
                Button("Archive the Project") { confirming = .archive }
                    .buttonStyle(.piSecondary)
                    .disabled(engine.status != .connected)
            }
            Button("Delete the Project…") { confirming = .delete }
                .buttonStyle(.piDanger)
                .disabled(engine.status != .connected)
            if let problem = problems["lifecycle"] { Text(problem).problemText() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    // MARK: Asking and saving

    private var title: String? {
        switch confirming {
        case .archive: "Archive “\(project.name)”?"
        case .delete: "Delete “\(project.name)”?"
        case .detach: "Detach \(project.repository.map { "\($0.owner)/\($0.name)" } ?? "the repository")?"
        case nil: nil
        }
    }

    /// Keeps the text fields with the project, except the one being edited.
    private func sync() {
        if focused != .name { drafts.name = project.name }
        if focused != .planShare { drafts.planShare = project.settings?.limits.planShare.map(String.init) ?? "" }
        if focused != .dailySpend { drafts.dailySpend = project.settings?.limits.dailySpend.map { String(format: "%g", $0) } ?? "" }
    }

    private func saveName() {
        let given = drafts.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard given != project.name, !given.isEmpty else {
            drafts.name = project.name
            problems["name"] = nil
            return
        }
        Task {
            do {
                _ = try await engine.call("projects.rename", ["id": project.id, "name": given])
                problems["name"] = nil
            } catch {
                problems["name"] = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        guard let picked = FilePanels.open("project-folder", selecting: .folders, configure: { panel in
            panel.prompt = "Change Folder"
            panel.message = "Choose the folder the project’s agents work in."
        })?.first?.path else { return }
        Task {
            do {
                _ = try await engine.call("projects.set", ["id": project.id, "folder": picked])
                problems["folder"] = nil
            } catch {
                problems["folder"] = error.localizedDescription
            }
        }
    }

    private func attach() {
        Task {
            do {
                var params: [String: Any] = ["projectId": project.id]
                let given = attachText.trimmingCharacters(in: .whitespaces)
                if !given.isEmpty { params["repository"] = given }
                _ = try await engine.call("github.attach", params)
                problems["attach"] = nil
                attaching = false
            } catch {
                problems["attach"] = error.localizedDescription
            }
        }
    }

    private func detachRepository() {
        Task {
            do {
                _ = try await engine.call("github.detach", ["projectId": project.id])
                problems["repository"] = nil
            } catch {
                problems["repository"] = error.localizedDescription
            }
        }
    }

    /// Sends one part of the settings, and keeps the engine's answer for the row that sent it.
    private func setting(_ part: [String: Any], _ key: String) {
        Task {
            do {
                _ = try await engine.call("projects.set", ["id": project.id, "settings": part])
                problems[key] = nil
            } catch {
                problems[key] = error.localizedDescription
            }
        }
    }

    private func savePlanShare() {
        let given = drafts.planShare.trimmingCharacters(in: .whitespaces)
        var value: Any = NSNull()
        if !given.isEmpty {
            guard let percent = Int(given), (1...100).contains(percent) else {
                problems["planShare"] = "Enter a whole number from 1 to 100, or leave it empty for no limit."
                return
            }
            value = percent
        }
        setting(["limits": ["planShare": value]], "planShare")
    }

    private func saveDailySpend() {
        let given = drafts.dailySpend.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        var value: Any = NSNull()
        if !given.isEmpty {
            guard let amount = Double(given), amount > 0 else {
                problems["dailySpend"] = "Enter an amount above zero, or leave it empty for no limit."
                return
            }
            value = amount
        }
        setting(["limits": ["dailySpend": value]], "dailySpend")
    }

    /// One of the person's own requests on the project as a whole: archive, restore or delete it.
    private func lifecycle(_ method: String, _ key: String) {
        Task {
            do {
                _ = try await engine.call(method, ["id": project.id])
                problems[key] = nil
            } catch {
                problems[key] = error.localizedDescription
            }
        }
    }

    // MARK: The form's shape

    /// One titled group of the form: a small heading, the rows in a card, and one line of explanation under it.
    private func titled(_ title: String, footer: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).sectionLabel()
            VStack(alignment: .leading, spacing: 10) { rows() }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            Text(footer)
                .formFooter()
                .font(.callout)
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension Text {
    /// The label of a row in the Settings tab, in a column of its own.
    func rowLabel() -> some View {
        foregroundStyle(Theme.tx2).frame(width: 84, alignment: .leading)
    }

    /// An engine's refusal, under the row that caused it.
    func problemText() -> some View {
        font(.callout).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
    }
}
