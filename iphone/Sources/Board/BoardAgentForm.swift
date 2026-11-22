
import PiModels
import SwiftUI

/// The sections of an agent's page, for a debug build's `PI2_BOARD_SCROLL` to bring one up for a picture.
enum BoardAgentSection: String, CaseIterable {
    case profile, model, instructions, files, memory, tools, everything, builtins, commands, variables, extras, mac, schedule, delegates, template, actions
}

/// An agent's settings as grouped sections, in the Mac's order and words. The form is edited as a draft and saved with
/// Save, as on the Mac; memory, allowed commands and Allow everything apply at once, as they do there. What stays on the
/// Mac (docs/design/iphone.md, "What stays on the Mac, and why") is shown and says so: the folder and the reference
/// files are chosen in the Mac's panels, the variables' values are secrets, computer use and the browser act on the
/// Mac's screen, and Allow everything is turned on only there.
struct BoardAgentForm: View {
    let saved: AgentProfile
    let data: BoardData

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AgentProfile
    /// The saved agent the draft was last brought up to date with: what the person's edits are measured from.
    @State private var base: AgentProfile
    @State private var turnsText: String
    @State private var saving = false
    @State private var saveProblem: String?
    @State private var everythingProblem: String?
    @State private var memoryProblem: String?
    @State private var commandProblem: String?
    @State private var actionProblem: String?
    @State private var newCommand = ""
    @State private var newCommandFolder: String?
    @State private var confirmingDelete = false
    @State private var updating = false

    init(saved: AgentProfile, data: BoardData) {
        self.saved = saved
        self.data = data
        _draft = State(initialValue: saved)
        _base = State(initialValue: saved)
        _turnsText = State(initialValue: saved.maxTurns.map(String.init) ?? "")
    }

    private var isTemplate: Bool { saved.projectId == nil }
    private var project: ProjectRow? { saved.projectId.flatMap(data.project) }
    private var isOrchestrator: Bool { project?.orchestratorId == saved.id }
    private var changed: Bool { draft.asSaved != saved.asSaved }
    private var canSave: Bool {
        changed && !saving && data.connected && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { scroller in
            Form {
                if let sample = data.sample { BoardSampleNote(what: sample) }
                profile.id(BoardAgentSection.profile)
                modelSection.id(BoardAgentSection.model)
                Section("Instructions") {
                    TextField("Instructions", text: $draft.instructions, prompt: Text("What it is told at the start of each conversation"), axis: .vertical)
                        .lineLimit(4...24)
                        .accessibilityLabel("Instructions")
                }
                .id(BoardAgentSection.instructions)
                files.id(BoardAgentSection.files)
                memory.id(BoardAgentSection.memory)
                tools.id(BoardAgentSection.tools)
                BoardAllowEverything(agent: saved, data: data, problem: $everythingProblem)
                    .id(BoardAgentSection.everything)
                if !data.builtInTools.isEmpty { builtIns.id(BoardAgentSection.builtins) }
                commands.id(BoardAgentSection.commands)
                variables.id(BoardAgentSection.variables)
                extras.id(BoardAgentSection.extras)
                onTheMac.id(BoardAgentSection.mac)
                schedule.id(BoardAgentSection.schedule)
                delegates.id(BoardAgentSection.delegates)
                if saved.template != nil { template.id(BoardAgentSection.template) }
                actions.id(BoardAgentSection.actions)
            }
            #if DEBUG
            .task { await BoardDebugAct.agent(self, scroller) }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
                    .accessibilityHint(changed ? "Saves your changes to \(saved.name)" : "Nothing has changed yet")
            }
            if changed {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Revert Changes", systemImage: "arrow.uturn.backward") { load() }
                }
            }
        }
        .onChange(of: saved) { old, latest in follow(old, latest) }
        .confirmationDialog("Delete \(saved.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Its conversations stay, and keep the setup they already have. Your Mac is told of the change.")
        }
        .sheet(isPresented: $updating) {
            BoardTemplateUpdate(agent: saved, template: saved.template.flatMap { data.agent($0.id) })
        }
    }

    // MARK: - Keeping up with the Mac

    private func load() {
        draft = saved
        base = saved
        turnsText = saved.maxTurns.map(String.init) ?? ""
        saveProblem = nil
    }

    /// Follows a change saved elsewhere (on the Mac, by an agent's tool, or this page's own Save), keeping the person's
    /// edits on top of it, as the Mac's page does.
    private func follow(_ old: AgentProfile, _ latest: AgentProfile) {
        let edited = BoardAgentDraft.edited(draft, from: base)
        if edited.isEmpty { return load() }
        draft = BoardAgentDraft.rebase(draft, from: base, onto: latest)
        base = latest
        if !edited.contains("maxTurns") { turnsText = latest.maxTurns.map(String.init) ?? "" }
    }

    private func save() {
        let edited = BoardAgentDraft.edited(draft, from: base)
        let draft = draft
        let engine = session.engine
        saving = true
        Task {
            saveProblem = await BoardRequests.save(engine, draft: draft, edited: edited).map { "Not saved: \($0)" }
            saving = false
        }
    }

    // MARK: - The sections

    private var profile: some View {
        Section {
            HStack(spacing: 12) {
                AgentMark(agent: draft, size: 44)
                VStack(spacing: 6) {
                    TextField("Name", text: $draft.name)
                        .font(.headline)
                    Divider()
                    TextField("What it is for", text: $draft.description, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            Picker("Colour", selection: $draft.color) {
                // The mark beside the name shows the colour chosen; a menu draws its rows in one colour.
                ForEach(AgentColor.names, id: \.self) { Text($0.capitalized).tag($0) }
            }
            if saved.allowEverything == true {
                Label("Allow everything is on: \(saved.name) asks you about nothing. Turn it off below, under Allow everything.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text(isTemplate ? "Template" : isOrchestrator ? "Orchestrator of \(project?.name ?? "its project")" : "Agent of \(project?.name ?? "its project")")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let saveProblem { BoardProblem(saveProblem) }
                Text(isTemplate
                    ? "What it can do applies from the next message. Model, instructions and folder apply to new conversations. A change made from this phone is told to your Mac."
                    : "What it can do, its model and its thinking apply from the next message. Instructions apply to new conversations. A change made from this phone is told to your Mac.")
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        let chosen = data.allModels.first { $0.ref == draft.model }
        Section {
            Picker("Model", selection: $draft.model) {
                Text(data.appDefaultName).tag(ModelRef?.none)
                if let ref = draft.model, chosen == nil || chosen?.hidden == true {
                    Text(data.fullModelName(ref)).tag(ModelRef?.some(ref))
                }
                ForEach(data.modelGroups, id: \.provider) { group in
                    Section(group.name) {
                        ForEach(group.models, id: \.ref) { model in
                            Text(model.listName).tag(ModelRef?.some(model.ref))
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            if let levels = chosen?.thinkingLevels, !levels.isEmpty {
                Picker("Thinking", selection: $draft.thinkingLevel) {
                    Text("Default").tag(String?.none)
                    ForEach(levels, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            if draft.model == nil {
                Text("With App default, it starts each new conversation on the default model for agents, chosen in Settings, and follows it when it changes.")
            }
        }
    }

    private var files: some View {
        Section {
            let files = draft.files ?? []
            if files.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 4) {
                    Label((file.path as NSString).lastPathComponent, systemImage: "doc.text")
                    Text((file.path as NSString).deletingLastPathComponent)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.head)
                    TextField("What it is for", text: Binding(
                        get: { file.note },
                        set: { note in
                            guard let index = draft.files?.firstIndex(where: { $0.path == file.path }) else { return }
                            draft.files?[index].note = note
                        }
                    ), prompt: Text("What it is for (optional)"))
                    .font(.subheadline)
                }
                .accessibilityElement(children: .contain)
            }
            .onDelete { offsets in
                var list = draft.files ?? []
                list.remove(atOffsets: offsets)
                draft.files = list
            }
        } header: {
            Text("Reference files")
        } footer: {
            Text("The agent sees this list in every conversation and opens a file when it needs it. Files and folders are added on your Mac, from its panels; here a note can be changed, and a file taken off the list with a swipe.")
        }
    }

    private var memory: some View {
        let enabled = data.memoryEnabled(saved.id)
        return Section {
            Toggle("Remember things between conversations", isOn: Binding(get: { enabled }, set: { on in
                let engine = session.engine
                let id = saved.id
                boardSend($memoryProblem) { await BoardRequests.setMemory(engine, agent: id, on: on).map { "Memory was not turned \(on ? "on" : "off"): \($0)" } }
            }))
            .disabled(!data.connected)
        } header: {
            Text("Memory")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let memoryProblem { BoardProblem(memoryProblem) }
                Text(memoryFooter(enabled))
            }
        }
    }

    private func memoryFooter(_ enabled: Bool) -> String {
        var text: String
        if let project {
            text = enabled
                ? "The agent is given \(project.name)’s notes in every conversation, and may add to them as it works. "
                : "Off: the agent is not given \(project.name)’s notes and cannot add to them. "
        } else {
            text = "This is what a project’s copy of this template starts with. "
            text += enabled ? "With it on, chats may read this template’s notes when a question calls for it. " : "Off: chats do not read this template’s notes. "
        }
        return text + "Changes here apply at once, without Save."
    }

    private var tools: some View {
        Section {
            Picker("Tool access", selection: $draft.access) {
                ForEach(AccessLevel.all, id: \.id) { Text($0.title).tag($0.id) }
            }
            LabeledContent("Folder") {
                Text(draft.cwd ?? "pi²’s scratch folder, unless chosen per conversation")
                    .font(draft.cwd == nil ? .body : .callout.monospaced())
                    .lineLimit(3).truncationMode(.head)
                    .multilineTextAlignment(.trailing)
            }
            Toggle(isOn: Binding(get: { draft.worktree ?? false }, set: { draft.worktree = $0 })) {
                Text("Give each conversation its own worktree")
                Text("Each new conversation works on a branch of its own in a separate checkout of the folder’s git repository.")
            }
            .disabled(draft.cwd == nil && draft.worktree != true)
            TextField(text: Binding(get: { draft.setup ?? "" }, set: { draft.setup = $0 }), prompt: Text("None, for example npm ci")) {
                Text("Set-up command")
            }
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(draft.cwd == nil && (draft.setup ?? "").isEmpty)
            .accessibilityLabel("Set-up command for each new worktree")
            LabeledContent("Turn limit per run") {
                TextField("Turn limit per run", text: $turnsText, prompt: Text("No limit"))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: turnsText) { _, value in
                        draft.maxTurns = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1 ? $0 : nil }
                    }
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("\(AccessLevel.all.first { $0.id == draft.access }?.detail ?? ""). The folder is chosen on your Mac, from its panels.")
        }
    }

    private var builtIns: some View {
        Section {
            ForEach(data.builtInTools) { tool in
                Toggle(isOn: Binding(
                    get: { tool.offByDefault == true ? (draft.toolsOn ?? []).contains(tool.key) : !(draft.toolsOff ?? []).contains(tool.key) },
                    set: { on in
                        // Kept in the engine's order, as it stores them, so a saved list compares equal to the draft.
                        let keys = data.builtInTools.map(\.key)
                        if tool.offByDefault == true {
                            let given = Set((draft.toolsOn ?? []).filter { $0 != tool.key } + (on ? [tool.key] : []))
                            draft.toolsOn = keys.filter(given.contains)
                        } else {
                            let off = Set((draft.toolsOff ?? []).filter { $0 != tool.key } + (on ? [] : [tool.key]))
                            draft.toolsOff = keys.filter(off.contains)
                        }
                    }
                )) {
                    Text(tool.title)
                    Text(unavailable(tool).map { "\(tool.detail) \($0)" } ?? tool.detail)
                }
            }
        } header: {
            Text("Built-in tools")
        } footer: {
            Text("Each tool’s description is read again on every turn, so leaving out what the agent never uses makes every turn a little cheaper.")
        }
    }

    /// Why the tool is not offered with the agent's settings as they are, if it is not (the Mac's words).
    private func unavailable(_ tool: BuiltInTool) -> String? {
        switch tool.needs {
        case "files" where draft.access == "none": "Not offered with tool access off."
        case "changes" where draft.access != "ask" && draft.access != "full": "Offered only with Ask first or Full access."
        case "browser" where draft.browser?.enabled != true: "Offered only while the browser is on."
        default: nil
        }
    }

    // MARK: - Allowed commands

    /// The folders a new allowed command can be given: the agent's own, its project's, and those its commands already
    /// have. Any other is chosen on the Mac, from its panels.
    private var commandFolders: [String] {
        var folders: [String] = []
        for folder in [saved.cwd, project?.folder].compactMap({ $0 }) + (saved.commandRules ?? []).map(\.folder) where !folders.contains(folder) {
            folders.append(folder)
        }
        return folders
    }

    private var commands: some View {
        let rules = (saved.commandRules ?? []).sorted { ($0.folder, $0.command) < ($1.folder, $1.command) }
        let folders = commandFolders
        let folder = newCommandFolder ?? folders.first
        return Section {
            if rules.isEmpty {
                Text("None yet. Choose “Always Allow …” on a command’s approval, or add one here.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.command).font(.body.monospaced())
                    Text("in \((rule.folder as NSString).lastPathComponent)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .swipeActions {
                    Button("Remove", role: .destructive) { removeCommand(rule) }
                }
                .accessibilityAction(named: "Remove") { removeCommand(rule) }
            }
            TextField("Command to allow", text: $newCommand, prompt: Text("npm test"))
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { addCommand(in: folder) }
                .accessibilityLabel("First words of the command to allow")
            if folders.count > 1 {
                Picker("In", selection: Binding(get: { folder ?? "" }, set: { newCommandFolder = $0 })) {
                    ForEach(folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                }
            } else if let folder {
                LabeledContent("In", value: (folder as NSString).lastPathComponent)
            }
            Button("Allow Command") { addCommand(in: folder) }
                .disabled(newCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder == nil || !data.connected)
        } header: {
            Text("Allowed commands")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let commandProblem { BoardProblem(commandProblem) }
                if folders.isEmpty { Text("This agent has no folder: choose one for a command on your Mac.") }
                Text("An allowed command lets this agent run commands that start with the same words without asking, in the chosen folder: “git status” also covers “git status -sb”, but not “git push”. \(draft.access == "ask" ? "" : "Allowed commands only matter while tool access is “Ask first”. ")Changes here apply at once, without Save, and adding one is told to your Mac.")
            }
        }
    }

    private func addCommand(in folder: String?) {
        let words = newCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let folder else { return }
        let engine = session.engine
        let id = saved.id
        Task {
            if let problem = await BoardRequests.allowCommand(engine, agent: id, folder: folder, command: words) {
                commandProblem = "“\(words)” was not allowed: \(problem)"
            } else {
                commandProblem = nil
                newCommand = ""
            }
        }
    }

    private func removeCommand(_ rule: CommandRule) {
        let engine = session.engine
        let id = saved.id
        boardSend($commandProblem) { await BoardRequests.removeCommand(engine, agent: id, rule: rule).map { "“\(rule.command)” was not removed: \($0)" } }
    }

    // MARK: - What stays on the Mac

    private var variables: some View {
        Section {
            let variables = saved.variables ?? []
            if variables.isEmpty { Text("None.").foregroundStyle(.secondary) }
            ForEach(variables) { variable in
                LabeledContent {
                    Text(variable.set ? "value set" : "no value").foregroundStyle(variable.set ? Color.secondary : .orange)
                } label: {
                    Label(variable.name, systemImage: "key").font(.body.monospaced())
                }
            }
        } header: {
            Text("Variables for its commands")
        } footer: {
            Text("Every command this agent runs can read these values. They are set, replaced and removed on your Mac, where they are kept in its Keychain: a phone never receives or sends a secret.")
        }
    }

    private var extras: some View {
        Section {
            Toggle("Write scripts that call its tools", isOn: Binding(get: { draft.codeMode ?? false }, set: { draft.codeMode = $0 }))
            if data.mcpServers.isEmpty {
                Text("No MCP servers are connected. They are added on your Mac.").foregroundStyle(.secondary)
            }
            ForEach(data.mcpServers) { server in
                Toggle(isOn: Binding(
                    get: { draft.mcpServers?.contains(server.id) ?? false },
                    set: { on in
                        var list = (draft.mcpServers ?? []).filter { $0 != server.id }
                        if on { list.append(server.id) }
                        draft.mcpServers = list
                    }
                )) {
                    Text(server.name)
                    Text(server.status == "connected" ? "\(server.tools.count) tools" : "not connected")
                }
            }
        } header: {
            Text("Extra tools")
        } footer: {
            Text("Scripts let the model chain many tool calls in one step. MCP servers add tools from other apps and services.")
        }
    }

    private var onTheMac: some View {
        let computer = saved.computer ?? ComputerSettings()
        let browser = saved.browser ?? BrowserSettings()
        return Section {
            LabeledContent("Computer use") {
                Text(computer.enabled
                    ? "On\(computer.apps.isEmpty ? "" : ": \(computer.apps.joined(separator: ", "))")\(computer.ask ? ", asks first" : ", without asking")"
                    : "Off")
                .multilineTextAlignment(.trailing)
            }
            LabeledContent("Browser") {
                Text(browser.enabled ? (browser.ask ? "On, asks first" : "On, without asking") : "Off")
            }
        } header: {
            Text("On the Mac")
        } footer: {
            Text("Computer use and pi²’s browser act on your Mac’s screen, with the permissions it gave pi², so they are changed only there.")
        }
    }

    @ViewBuilder
    private var schedule: some View {
        Section {
            Toggle("Can schedule its own work", isOn: Binding(
                get: { draft.schedule?.enabled ?? false },
                set: { draft.schedule = ScheduleSettings(enabled: $0) }
            ))
            if isTemplate {
                BoardLinkRow(route: .schedules) { Text("Schedules") }
            }
        } header: {
            Text("Schedules")
        } footer: {
            Text(draft.schedule?.enabled == true
                ? "When you ask it to do something later or regularly, the agent can set a schedule for itself. You approve each one before it is set."
                : "Off: the agent cannot set schedules. You can still schedule it yourself.")
        }
    }

    private var delegates: some View {
        Section {
            let others = data.delegateCandidates(saved)
            if others.isEmpty { Text("There are no other agents yet.").foregroundStyle(.secondary) }
            ForEach(others) { other in
                Toggle(isOn: Binding(
                    get: { draft.delegates.contains(other.id) },
                    set: { on in
                        draft.delegates.removeAll { $0 == other.id }
                        if on { draft.delegates.append(other.id) }
                    }
                )) {
                    HStack(spacing: 8) {
                        AgentMark(agent: other, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(other.name)
                            if !other.description.isEmpty {
                                Text(other.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                .accessibilityLabel(other.name)
            }
        } header: {
            Text("Can hand work to")
        } footer: {
            Text("The other agent runs with its own model, instructions and tools, and reports back. Each handoff opens a sub-chat.")
        }
    }

    @ViewBuilder
    private var template: some View {
        Section {
            if data.templateChanged(saved) {
                Button("Update from Template…") { updating = true }
                    .disabled(!data.connected)
            } else if data.templateGone(saved) {
                Text("The template this agent was made from has been deleted, so it cannot be updated from it.")
                    .foregroundStyle(.secondary)
            } else if let mark = saved.template, let template = data.agent(mark.id) {
                LabeledContent("Made from", value: template.name)
            }
        } header: {
            Text("Template")
        } footer: {
            if data.templateChanged(saved) {
                Text("The template this agent was made from has changed since. See what would change, and bring it up to date.")
            }
        }
    }

    private var actions: some View {
        Section {
            if !isOrchestrator {
                Button("New Conversation", systemImage: "plus.bubble") { newConversation() }
                    .disabled(changed || saved.removedAt != nil || project?.archivedAt != nil || !data.connected)
            }
            Button("Duplicate", systemImage: "doc.on.doc") { duplicate() }
                .disabled(changed || !data.connected)
            Button("Delete \(isTemplate ? "Template" : "Agent")…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .disabled(data.templates.count <= 1 || !data.connected)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let actionProblem { BoardProblem(actionProblem) }
                if changed { Text("Save or revert your changes before starting a conversation or duplicating.") }
            }
        }
    }

    private func newConversation() {
        let engine = session.engine
        let agent = saved
        Task {
            switch await BoardRequests.newConversation(engine, agent: agent.id) {
            case .success(let id): actionProblem = nil; openRoute(.conversation(id))
            case .failure(let failure): actionProblem = "No conversation was started: \(failure.message)"
            }
        }
    }

    private func duplicate() {
        let engine = session.engine
        let agent = saved
        Task {
            switch await BoardRequests.duplicate(engine, agent: agent.id) {
            case .success(let id): actionProblem = nil; openRoute(.agent(id, project: agent.projectId))
            case .failure(let failure): actionProblem = "\(agent.name) was not duplicated: \(failure.message)"
            }
        }
    }

    private func delete() {
        let engine = session.engine
        let agent = saved
        Task {
            if let problem = await BoardRequests.delete(engine, agent: agent.id) {
                actionProblem = "\(agent.name) was not deleted: \(problem)"
            } else {
                dismiss()
            }
        }
    }

    #if DEBUG
    /// For `BoardDebugAct`: what a tap would do.
    func debugSave(_ description: String) {
        draft.description = description
        Task { @MainActor in
            // Once the change has been drawn, as a person's Save would follow their typing.
            try? await Task.sleep(for: .milliseconds(300))
            save()
        }
    }

    func debugEverythingOff() {
        let engine = session.engine
        let id = saved.id
        boardSend($everythingProblem) { await BoardRequests.allowEverythingOff(engine, agent: id).map { "Allow everything is still on: \($0)" } }
    }
    #endif
}

/// Allow everything on an agent's page: turned off from the phone at once, and on only at the Mac (docs/iphone.md, 4.2,
/// question 5), which the switch says rather than offering what the engine would refuse.
struct BoardAllowEverything: View {
    let agent: AgentProfile
    let data: BoardData
    @Binding var problem: String?

    @Environment(AppSession.self) private var session

    var body: some View {
        let on = agent.allowEverything == true
        Section {
            Toggle(isOn: Binding(get: { on }, set: { want in if !want { turnOff() } })) {
                Text("Allow everything")
                Text(on ? "Asks you about nothing, and may use any app." : "Off. It can be turned on only on your Mac.")
            }
            .tint(.red)
            // Off, there is nothing a phone may do with it: turning it on is the Mac's alone.
            .disabled(!on || !data.connected)
            .accessibilityHint(on ? "Turns Allow everything off for \(agent.name)" : "Turning it on is done only on the Mac")
            if on {
                Label("\(agent.name) does anything without asking you, in every conversation, scheduled runs included.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Allow everything")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem { BoardProblem(problem) }
                Text(on
                    ? "Turning it off applies from each conversation’s next message: the agent asks again as its other settings say."
                    : "It ends all asking for an agent, so it is turned on only at the Mac: a phone taken from your hand while pi² is open could otherwise give it in one tap.")
            }
        }
    }

    private func turnOff() {
        let engine = session.engine
        let id = agent.id
        boardSend($problem) { await BoardRequests.allowEverythingOff(engine, agent: id).map { "Allow everything is still on: \($0)" } }
    }
}

/// What Update from Template would change in a copy, setting by setting (docs/projects.md, 3.3), as the Mac's sheet
/// shows it: asked of the engine first, changing nothing; Update applies it.
struct BoardTemplateUpdate: View {
    let agent: AgentProfile
    let template: AgentProfile?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [BoardTemplateChange]?
    @State private var problem: String?
    @State private var applying = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let problem {
                        BoardProblem(problem)
                    } else if let changes {
                        if changes.isEmpty {
                            Text("Everything this agent takes from the template already matches it.").foregroundStyle(.secondary)
                        }
                        ForEach(changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(BoardTemplateChange.title(change.setting)).font(.headline)
                                Text("Now: \(BoardTemplateChange.words(change.setting, change.now))").foregroundStyle(.secondary)
                                Text("From the template: \(BoardTemplateChange.words(change.setting, change.template))")
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        ProgressView("Reading what has changed…")
                    }
                } header: {
                    Text("What would change")
                } footer: {
                    Text("Its name, folder, who it can hand work to, allowed commands, variables and Allow everything are this project's own, and never come from the template.")
                }
            }
            .navigationTitle("Update from “\(template?.name ?? "its template")”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") { apply() }
                        .disabled((changes?.isEmpty ?? true) || applying)
                }
            }
            .task { await read() }
        }
    }

    private func read() async {
        switch await BoardRequests.templateChanges(session.engine, agent: agent.id) {
        case .success(let list): changes = list; problem = nil
        case .failure(let failure): problem = "What would change could not be read: \(failure.message)"
        }
    }

    private func apply() {
        applying = true
        let engine = session.engine
        let id = agent.id
        Task {
            if let failure = await BoardRequests.updateFromTemplate(engine, agent: id) {
                problem = "Not updated: \(failure)"
                applying = false
            } else {
                dismiss()
            }
        }
    }
}

extension BoardTemplateChange {
    /// What the setting is called on an agent's page (the Mac's `UpdateFromTemplateSheet.title`).
    static func title(_ setting: String) -> String {
        switch setting {
        case "description": "Description"
        case "color": "Colour"
        case "model": "Model"
        case "thinkingLevel": "Thinking"
        case "instructions": "Instructions"
        case "access": "Tool access"
        case "worktree": "Give each conversation its own worktree"
        case "setup": "Set-up command"
        case "maxTurns": "Turn limit per run"
        case "codeMode": "Write scripts that call its tools"
        case "mcpServers": "Extra tools (MCP servers)"
        case "files": "Reference files"
        case "computer": "Computer use"
        case "browser": "Browser"
        case "schedule": "Can schedule its own work"
        case "toolsOff": "Built-in tools left out"
        case "toolsOn": "Built-in tools off by default, turned on"
        case "compactionTokens": "Summary size"
        case "memory": "Memory"
        default: setting
        }
    }

    /// A setting's value as the person reads it (the Mac's `UpdateFromTemplateSheet.words`), whole however long.
    static func words(_ setting: String, _ value: JSONValue) -> String {
        switch value {
        case .null:
            switch setting {
            case "model": return "App default"
            case "thinkingLevel": return "Default"
            case "maxTurns": return "No limit"
            case "compactionTokens": return "Default for all agents"
            default: return "None"
            }
        case .bool(let on):
            return on ? "On" : "Off"
        case .number(let number):
            return setting == "compactionTokens" ? "\(Int(number)) tokens" : number.rounded() == number ? String(Int(number)) : String(number)
        case .string(let text):
            switch setting {
            case "access": return AccessLevel.all.first { $0.id == text }?.title ?? text
            case "color", "thinkingLevel": return text.capitalized
            default: return text.isEmpty ? "Empty" : text
            }
        case .array(let items):
            let names = items.compactMap { $0.stringValue ?? $0["path"]?.stringValue }
            return names.isEmpty ? "None" : names.joined(separator: ", ")
        case .object(let fields):
            switch setting {
            case "model":
                return "\(fields["provider"]?.stringValue ?? "") · \(fields["modelId"]?.stringValue ?? "")"
            case "computer", "browser", "schedule":
                let on = fields["enabled"] == .bool(true)
                var text = on ? "On" : "Off"
                if on, setting == "computer", let apps = fields["apps"]?.arrayValue, !apps.isEmpty {
                    text += " · \(apps.compactMap(\.stringValue).joined(separator: ", "))"
                }
                if on, setting != "schedule", fields["ask"] == .bool(false) { text += ", without asking" }
                return text
            default:
                return fields.keys.sorted().compactMap { key in fields[key].map { "\(key): \(words(key, $0))" } }.joined(separator: ", ")
            }
        }
    }
}
