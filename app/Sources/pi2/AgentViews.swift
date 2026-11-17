import SwiftUI

enum AgentColor {
    static let names = ["violet", "blue", "teal", "green", "yellow", "orange", "pink", "gray"]

    /// Soft pastels with dark lettering, so agents read as characters rather than warning lights.
    static func color(_ name: String?) -> Color {
        let hex: UInt32 = switch name {
        case "blue": 0x9FC5FF
        case "teal": 0x7FD8C4
        case "green": 0xA8E39A
        case "yellow": 0xF5D77A
        case "orange": 0xFFB37A
        case "pink": 0xFFA8C8
        case "gray": 0xC3C5D0
        default: 0xB9A6FF
        }
        return Color(nsColor: Theme.rgb(hex))
    }
}

struct AgentAvatar: View {
    let agent: AgentProfile?
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(AgentColor.color(agent?.color))
            .frame(width: size, height: size)
            .overlay {
                Text(String(agent?.name.prefix(1) ?? "?").uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(nsColor: Theme.rgb(0x15161C)))
            }
            .accessibilityHidden(true)
    }
}

/// The sections of an agent's page, by the short names a development build can open the page at, with
/// `PI2_SHOW=agent:<id>#<name>` (docs/development.md). In the order they appear.
enum AgentSection: String, CaseIterable {
    case profile, model, instructions, files, memory, tools, rules, extras, computer, browser, schedule, delegates
}

#if PI2_DEVELOPMENT
extension AgentSection {
    /// The agent and section `PI2_SHOW` asked for, until the page for that agent first opens and takes it: coming back
    /// to the page later opens it at the top, as usual.
    @MainActor private static var asked: (agent: String, section: AgentSection)? = {
        guard let value = ProcessInfo.processInfo.environment["PI2_SHOW"], value.hasPrefix("agent:"),
              let hash = value.firstIndex(of: "#"),
              let section = AgentSection(rawValue: String(value[value.index(after: hash)...])) else { return nil }
        return (String(value[value.index(value.startIndex, offsetBy: "agent:".count)..<hash]), section)
    }()

    @MainActor static func take(for agentID: String) -> AgentSection? {
        guard let asked, asked.agent == agentID else { return nil }
        self.asked = nil
        return asked.section
    }
}
#endif

/// Edits one agent: what model it runs, what it is told, what it may do, and who it may hand work to.
struct AgentEditor: View {
    @Bindable var model: AppModel
    let agentID: String

    @State private var draft: AgentProfile?
    @State private var turnsText = ""
    @State private var error: String?
    @State private var confirmingDelete = false
    private var engine: EngineClient { model.engine }
    private var saved: AgentProfile? { engine.agent(agentID) }
    private var changed: Bool {
        guard let draft else { return false }
        // Compared as they would be stored, so a setting the engine fills in or tidies on Save is not a change.
        // That also leaves out rules, which are kept as soon as they are added or removed, not with the rest of the form.
        return draft.asSaved != saved?.asSaved
    }

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                ScrollViewReader { proxy in
                    form(draft)
                        #if PI2_DEVELOPMENT
                        .task { await scroll(to: AgentSection.take(for: agentID), with: proxy) }
                        #endif
                }
            } else {
                ContentUnavailableView("Agent not found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .background(Theme.window)
        .navigationTitle(saved?.name ?? "Agent")
        .navigationSubtitle("Agent")
        .toolbar {
            ToolbarItem {
                Button("New Conversation", systemImage: "plus.bubble") { model.newConversation(agentId: agentID) }
                    .labelStyle(.titleAndIcon)
                    .help("Start a conversation with this agent")
                    .disabled(changed)
            }
        }
        .onAppear(perform: load)
        .onChange(of: saved) { _, _ in
            // Follow changes made elsewhere, but never overwrite edits in progress.
            if !changed || draft == nil { load() }
        }
        .confirmationDialog("Delete \(saved?.name ?? "this agent")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                engine.perform("agents.delete", ["id": agentID])
                model.selection = nil
            }
        } message: {
            Text("Its conversations stay, and keep the setup they already have.")
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    private func load() {
        draft = saved
        turnsText = saved?.maxTurns.map(String.init) ?? ""
    }

    #if PI2_DEVELOPMENT
    /// Brings the section `PI2_SHOW` asked for to the top of the page. Parts of the page fill in after it first appears
    /// (models, memory, MCP servers), which moves the sections below them, so it scrolls again while the page settles.
    private func scroll(to section: AgentSection?, with proxy: ScrollViewProxy) async {
        guard let section else { return }
        for delay in [100, 400, 1000, 2000] {
            try? await Task.sleep(for: .milliseconds(delay))
            proxy.scrollTo(section, anchor: .top)
        }
    }
    #endif

    @ViewBuilder
    private func form(_ draft: Binding<AgentProfile>) -> some View {
        let agent = draft.wrappedValue
        let chosenModel = engine.allModels.first { $0.ref == agent.model }
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AgentAvatar(agent: agent, size: 40)
                        VStack {
                            TextField("Name", text: draft.name)
                            TextField("What it is for", text: draft.description)
                        }
                    }
                    if model.duplicatedAgentID == agentID {
                        Text("Duplicated settings, not memory notes, conversations, schedules or worktrees. No other agent can hand work to this copy yet. To allow one, open that agent’s settings and turn this copy on under Can hand work to.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Colour", selection: draft.color) {
                        ForEach(AgentColor.names, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                .id(AgentSection.profile)

                Section("Model") {
                    Picker(selection: draft.model) {
                        Text("App default").tag(ModelRef?.none)
                        if let ref = agent.model, chosenModel == nil {
                            Text("\(ref.modelId) (not connected)").tag(ModelRef?.some(ref))
                        } else if let chosenModel, chosenModel.hidden == true {
                            // Hidden in Settings after this agent chose it: it keeps working, so it stays selectable here.
                            Text("\(chosenModel.providerName) · \(chosenModel.name) (hidden)").tag(ModelRef?.some(chosenModel.ref))
                        }
                        ForEach(engine.modelGroups, id: \.provider) { group in
                            Section(group.name) {
                                ForEach(group.models, id: \.ref) { item in
                                    Text(item.listName).tag(ModelRef?.some(item.ref))
                                }
                            }
                        }
                    } label: {
                        Text("Model")
                    } currentValueLabel: {
                        // The menu groups models under their provider; closed, the provider has to be named.
                        if let chosenModel {
                            Text("\(chosenModel.providerName) · \(chosenModel.name)\(chosenModel.hidden == true ? " (hidden)" : "")")
                        } else if let ref = agent.model {
                            Text("\(ref.modelId) (not connected)")
                        } else {
                            Text("App default")
                        }
                    }
                    if let levels = chosenModel?.thinkingLevels, !levels.isEmpty {
                        Picker("Thinking", selection: draft.thinkingLevel) {
                            Text("Default").tag(String?.none)
                            ForEach(levels, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                        }
                    }
                }
                .id(AgentSection.model)

                Section("Instructions") {
                    TextEditor(text: draft.instructions)
                        .font(.body)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Instructions")
                }
                .id(AgentSection.instructions)

                Section {
                    let files = agent.files ?? []
                    ForEach(files) { file in
                        HStack(spacing: 8) {
                            Image(systemName: Self.isFolder(file.path) ? "folder" : "doc.text")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((file.path as NSString).lastPathComponent).lineLimit(1)
                                Text(((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            .frame(width: 190, alignment: .leading)
                            .help(file.path)
                            TextField("What it is for", text: Binding(
                                get: { file.note },
                                set: { note in
                                    guard let index = draft.wrappedValue.files?.firstIndex(where: { $0.path == file.path }) else { return }
                                    draft.wrappedValue.files?[index].note = note
                                }
                            ), prompt: Text("What it is for (optional)"))
                            .labelsHidden()
                            Button("Remove", systemImage: "minus.circle") { draft.wrappedValue.files?.removeAll { $0.path == file.path } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Remove \((file.path as NSString).lastPathComponent)")
                        }
                    }
                    Button("Add Files or Folders…") {
                        var list = draft.wrappedValue.files ?? []
                        for path in EngineClient.pickReferenceFiles() where !list.contains(where: { $0.path == path }) {
                            list.append(ReferenceFile(path: path, note: ""))
                        }
                        draft.wrappedValue.files = list
                    }
                } header: {
                    Text("Reference files")
                } footer: {
                    Text("The agent sees this list in every conversation and opens a file when it needs it, so files cost nothing until they are read. They are read from disk each time, so your edits are picked up. The agent can only read them, even with tools off.").formFooter()
                }
                .id(AgentSection.files)

                AgentMemorySection(engine: engine, agentID: agentID)
                    .id(AgentSection.memory)

                Section {
                    Picker("Tool access", selection: draft.access) {
                        ForEach(AccessLevel.all, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    LabeledContent("Folder") {
                        HStack {
                            Text(agent.cwd ?? "pi²’s scratch folder, unless chosen per conversation").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Button("Choose…") {
                                if let folder = EngineClient.pickFolder() { draft.wrappedValue.cwd = folder }
                            }
                            if agent.cwd != nil { Button("Clear") { draft.wrappedValue.cwd = nil; draft.wrappedValue.worktree = false } }
                        }
                    }
                    Toggle(isOn: Binding(get: { agent.worktree ?? false }, set: { draft.wrappedValue.worktree = $0 })) {
                        Text("Give each conversation its own worktree")
                        Text("Each new conversation works on a branch of its own in a separate checkout of the folder’s git repository, so several can change it at once.")
                    }
                    .disabled(agent.cwd == nil && agent.worktree != true)
                    TextField(text: Binding(get: { agent.setup ?? "" }, set: { draft.wrappedValue.setup = $0 }), prompt: Text("None, for example npm ci")) {
                        Text("Set-up command")
                        Text("Runs once in the top folder of each new worktree for this agent, right after pi² makes it; the first answer waits for it.")
                    }
                    .disabled(agent.cwd == nil && (agent.setup ?? "").isEmpty)
                    TextField("Turn limit per run", text: $turnsText, prompt: Text("No limit"))
                        .onChange(of: turnsText) { _, value in
                            draft.wrappedValue.maxTurns = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1 ? $0 : nil }
                        }
                } header: {
                    Text("Tools")
                } footer: {
                    Text(AccessLevel.all.first { $0.id == agent.access }?.detail ?? "").formFooter()
                }
                .id(AgentSection.tools)

                CommandRulesSection(engine: engine, agentID: agentID, folder: agent.cwd, access: agent.access)
                    .id(AgentSection.rules)

                Section {
                    Toggle("Write scripts that call its tools", isOn: Binding(get: { agent.codeMode ?? false }, set: { draft.wrappedValue.codeMode = $0 }))
                    if engine.mcpServers.isEmpty {
                        Text("No MCP servers are connected. Add them in Settings › Tools.").foregroundStyle(.secondary)
                    }
                    ForEach(engine.mcpServers) { server in
                        Toggle(isOn: Binding(
                            get: { agent.mcpServers?.contains(server.id) ?? false },
                            set: { on in
                                var list = (draft.wrappedValue.mcpServers ?? []).filter { $0 != server.id }
                                if on { list.append(server.id) }
                                draft.wrappedValue.mcpServers = list
                            }
                        )) {
                            HStack {
                                Text(server.name)
                                Text(server.status == "connected" ? "\(server.tools.count) tools" : "not connected").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Extra tools")
                } footer: {
                    Text("Scripts let the model chain many tool calls in one step. MCP servers add tools from other apps and services.").formFooter()
                }
                .id(AgentSection.extras)

                ComputerUseSection(settings: Binding(
                    get: { agent.computer ?? ComputerSettings() },
                    set: { draft.wrappedValue.computer = $0 }
                ))
                .id(AgentSection.computer)

                BrowserSection(settings: Binding(
                    get: { agent.browser ?? BrowserSettings() },
                    set: { draft.wrappedValue.browser = $0 }
                ))
                .id(AgentSection.browser)

                Section {
                    Toggle("Can schedule its own work", isOn: Binding(
                        get: { agent.schedule?.enabled ?? false },
                        set: { draft.wrappedValue.schedule = ScheduleSettings(enabled: $0) }
                    ))
                } header: {
                    Text("Schedules")
                } footer: {
                    Text(agent.schedule?.enabled == true
                        ? "When you ask it to do something later or regularly, such as every morning or in two hours, the agent can set a schedule for itself. You approve each one before it is set. Each run then starts a new conversation with this agent, with its tools and access, and works with no one watching. It can run at most every 15 minutes, and the agent can have 20 at most. The agent can list its schedules and cancel the ones it set, but not yours. They show in Activity, marked “set by \(agent.name)”. In a sub-chat, where it works on a task another agent handed it, it cannot schedule."
                        : "Off: the agent cannot set schedules. You can still schedule it yourself in Activity.").formFooter()
                }
                .id(AgentSection.schedule)

                Section {
                    let others = engine.agents.filter { $0.id != agentID }
                    if others.isEmpty { Text("There are no other agents yet.").foregroundStyle(.secondary) }
                    ForEach(others) { other in
                        Toggle(isOn: Binding(
                            get: { agent.delegates.contains(other.id) },
                            set: { on in
                                draft.wrappedValue.delegates.removeAll { $0 == other.id }
                                if on { draft.wrappedValue.delegates.append(other.id) }
                            }
                        )) {
                            HStack {
                                AgentAvatar(agent: other, size: 18)
                                Text(other.name)
                                Text(other.description).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Can hand work to")
                } footer: {
                    Text("The other agent runs with its own model, instructions and tools, and reports back. Each handoff opens a sub-chat; this agent can archive the ones that are finished, never one that is working or waiting for you, and you can restore them from the Archive. It can also give a sub-chat a git worktree of its own; unless this agent has full access, or the other agent gives each conversation a worktree anyway, you are asked first.").formFooter()
                }
                .id(AgentSection.delegates)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Button("Delete Agent…") { confirmingDelete = true }
                    .buttonStyle(.piDanger)
                    .disabled(engine.agents.count <= 1)
                Button("Duplicate", systemImage: "doc.on.doc") { model.duplicateAgent(agentID) }
                    .buttonStyle(.piSecondary)
                    .disabled(changed)
                    .help(changed ? "Save or revert your changes before duplicating" : "Duplicate this agent’s saved settings")
                if let error { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Text("What it can do applies from the next message. Model, instructions and folder apply to new conversations.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                Button("Revert") { load(); error = nil }
                    .buttonStyle(.piSecondary)
                    .disabled(!changed)
                Button("Save") { save() }
                    .buttonStyle(.piPrimary)
                    .keyboardShortcut("s")
                    .disabled(!changed || agent.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private func save() {
        guard let draft else { return }
        Task {
            do {
                try await engine.call("agents.save", ["agent": draft.payload])
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The commands an agent may run without asking, folder by folder: listed, removed and added here. Changes apply at
/// once, without Save, because a rule can also be made from an approval at any time. The engine checks every rule.
struct CommandRulesSection: View {
    let engine: EngineClient
    let agentID: String
    /// The agent's own folder, offered for a new rule until another is chosen.
    let folder: String?
    let access: String

    @State private var command = ""
    @State private var chosenFolder: String?
    @State private var problem: String?

    private var rules: [CommandRule] {
        (engine.agent(agentID)?.commandRules ?? []).sorted { ($0.folder, $0.command) < ($1.folder, $1.command) }
    }
    private var newFolder: String? { chosenFolder ?? folder }

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("None yet. Choose “Always Allow …” on a command’s approval, or add one here.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.command).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                        Text("in \(engine.folderName(rule.folder))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .help(rule.folder)
                    Spacer(minLength: 8)
                    Button("Remove", systemImage: "minus.circle") { remove(rule) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove the rule for \(rule.command): the agent asks again before running it")
                }
            }
            HStack(spacing: 8) {
                TextField("Command", text: $command, prompt: Text("npm test"))
                    .labelsHidden()
                    .font(Theme.mono)
                    .accessibilityLabel("Words a command starts with, for a new rule")
                    .onSubmit { add() }
                Button(newFolder.map { "in \(engine.folderName($0))" } ?? "Choose Folder…") {
                    if let picked = EngineClient.pickFolder() { chosenFolder = picked }
                }
                .lineLimit(1)
                .help(newFolder.map { "The rule is for \($0). Click to choose another folder." } ?? "Choose the folder the rule is for")
                Button("Add") { add() }
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newFolder == nil)
            }
            if let problem {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
        } header: {
            Text("Commands it may run without asking")
        } footer: {
            Text(footer).formFooter()
        }
    }

    private var footer: String {
        var text = "A rule covers commands that start with its words, in that folder only: “git status” also covers “git status -sb”, but not “git push”. "
        text += "In a git repository, that folder also means the same folder of every worktree pi² makes from it, and a rule made in one of those worktrees is kept for the main checkout. "
        text += "It allows any options after its words, so make one only for a command you would let the agent run that way. "
        text += "Anything more complicated still asks, and rules that would allow anything, such as bash or rm on their own, cannot be made. "
        if access != "ask" { text += "Rules only matter while tool access is “Ask first”. " }
        text += "Changes here apply at once, without Save."
        return text
    }

    private func add() {
        let words = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let folder = newFolder else { return }
        Task {
            do {
                try await engine.call("rules.add", ["agentId": agentID, "folder": folder, "command": words])
                command = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func remove(_ rule: CommandRule) {
        Task {
            do {
                try await engine.call("rules.remove", ["agentId": agentID, "folder": rule.folder, "words": rule.words])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
