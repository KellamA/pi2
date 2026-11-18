
import SwiftUI

/// Chat mode's settings as the engine last sent them, in its `chat` event (docs/chat.md#settings).
struct ChatSettingsState: Equatable {
    var instructions = ""
    var defaultModel: ModelRef?
    var web = true
    var memory = true

    init(_ value: JSONValue?) {
        instructions = value?["instructions"]?.stringValue ?? ""
        if let provider = value?["defaultModel"]?["provider"]?.stringValue, let modelId = value?["defaultModel"]?["modelId"]?.stringValue {
            defaultModel = ModelRef(provider: provider, modelId: modelId)
        }
        if case .bool(let on)? = value?["web"] { web = on }
        if case .bool(let on)? = value?["memory"] { memory = on }
    }
}

extension EngineClient {
    /// Chat mode's settings: the instructions, the default model, the web and memory switches.
    var chatSettings: ChatSettingsState { ChatSettingsState(extras["chat"]) }
}

/// Settings › Chat: what every chat is told, how a new chat starts, and chat mode's memory (#288). Each change applies at
/// once, from each chat's next message; the instructions when Save is pressed.
struct ChatSettingsView: View {
    let engine: EngineClient

    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        let settings = engine.chatSettings
        Form {
            Section {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 110)
                    .accessibilityLabel("Chat instructions")
                HStack {
                    if let problem {
                        Text(problem).foregroundStyle(Theme.bad).font(.callout)
                    }
                    Spacer()
                    Button("Revert") { draft = settings.instructions }
                        .disabled(draft == settings.instructions)
                    Button("Save") { change(["instructions": draft]) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.instructions)
                }
            } header: {
                Text("Instructions")
            } footer: {
                Text("What chats should know about you and how you want them to answer, such as your name, your work, or to keep answers short. They are sent to the model in every chat, from its next message, and never to your agents.").formFooter()
            }
            .id(SettingsSection.instructions)

            Section {
                ChatModelPicker(engine: engine, selection: settings.defaultModel) { model in
                    change(["defaultModel": model.map { ["provider": $0.provider, "modelId": $0.modelId] } ?? NSNull()])
                }
                Toggle("Start with the web on", isOn: Binding(
                    get: { settings.web },
                    set: { on in change(["web": on]) }
                ))
            } header: {
                Text("New chats")
            } footer: {
                Text("A new chat starts with this model, or with the one you chose last in a chat, and you can change it in any chat. With the web on, a chat searches the web and reads pages when an answer depends on facts it may not have, and names its sources. Each chat has its own Web switch by the message field; this is where a new chat's starts, and changing it here changes no chat already made.").formFooter()
            }
            .id(SettingsSection.newChats)

            ChatMemorySection(engine: engine, enabled: settings.memory, setEnabled: { on in change(["memory": on]) })
                .id(SettingsSection.memory)
            AgentNotesSection(engine: engine, enabled: settings.memory)
                .id(SettingsSection.agentNotes)
        }
        .formStyle(.grouped)
        .settingsPage(.chat)
        .onAppear { draft = settings.instructions }
        .onChange(of: settings.instructions) { old, latest in
            // Follow the engine, unless the person has changed the text since it last said.
            if draft == old || draft.trimmingCharacters(in: .whitespacesAndNewlines) == latest { draft = latest }
        }
    }

    private func change(_ params: [String: Any]) {
        Task {
            do {
                try await engine.call("chat.set", params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The model a new chat starts with: one of the person's models, or the one chosen last in a chat.
private struct ChatModelPicker: View {
    let engine: EngineClient
    let selection: ModelRef?
    let choose: (ModelRef?) -> Void

    var body: some View {
        let chosen = engine.allModels.first { $0.ref == selection }
        Picker(selection: Binding(get: { selection }, set: { choose($0) })) {
            Text("The model used last").tag(ModelRef?.none)
            if let selection, chosen == nil {
                Text("\(selection.modelId) (not connected)").tag(ModelRef?.some(selection))
            } else if let chosen, chosen.hidden == true {
                Text("\(chosen.providerName) · \(chosen.name) (hidden)").tag(ModelRef?.some(chosen.ref))
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
            if let chosen {
                Text("\(chosen.providerName) · \(chosen.name)\(chosen.hidden == true ? " (hidden)" : "")")
            } else if let selection {
                Text("\(selection.modelId) (not connected)")
            } else {
                Text("The model used last")
            }
        }
    }
}

/// Chat mode's own notes: what chats remember across chats, kept apart from every agent's. Changes apply at once.
private struct ChatMemorySection: View {
    let engine: EngineClient
    let enabled: Bool
    let setEnabled: (Bool) -> Void

    @State private var newNote = ""
    @State private var problem: String?

    var body: some View {
        let notes = AgentMemoryState(engine.extras["memory"]?["chat"]).notes
        Section {
            Toggle("Remember things between chats", isOn: Binding(get: { enabled }, set: { setEnabled($0) }))
            if enabled || !notes.isEmpty {
                ForEach(notes) { note in
                    MemoryNoteRow(
                        note: note,
                        writtenBy: "Written in a chat",
                        save: { text in change("memory.edit", ["chat": true, "id": note.id, "text": text]) },
                        remove: { change("memory.delete", ["chat": true, "id": note.id]) }
                    )
                }
                if enabled && notes.isEmpty {
                    Text("No notes yet. Chats add them as you talk, or you can add one here.").foregroundStyle(.secondary)
                }
            }
            if enabled {
                HStack(spacing: 8) {
                    // Return adds the note, Shift-Return or Option-Return starts a new line in it, as in a message (#198).
                    TextField("Add a note", text: $newNote, prompt: Text("Add a note by hand"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...5)
                        .accessibilityLabel("New note")
                        .sendsOnReturn { add() }
                    Button("Add") { add() }
                        .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let problem {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
        } header: {
            Text("Memory")
        } footer: {
            Text(footer(notes: notes)).formFooter()
        }
    }

    private func footer(notes: [MemoryNote]) -> String {
        var text = enabled
            ? "Chats keep short notes of lasting things you tell them, such as your preferences, and are given them in every chat after. These are chat mode's own: your agents never see them. "
            : "Off: chats remember nothing between chats, and read none of your agents' notes. "
        text += "Every note is sent to the model in every chat, so do not keep anything secret here. "
        if !enabled, !notes.isEmpty { text += "The notes are kept but not sent while this is off. " }
        text += "Changes here apply at once."
        return text
    }

    private func add() {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await engine.call("memory.add", ["chat": true, "text": text])
                newNote = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func change(_ method: String, _ params: [String: Any]) {
        Task {
            do {
                try await engine.call(method, params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The notes of the agents that have memory on: what a chat can read when a question calls for it, and never change.
/// Shown read-only here; each agent's own settings is where they are edited.
private struct AgentNotesSection: View {
    let engine: EngineClient
    let enabled: Bool
    /// The agents whose notes the person folded away; each is open to begin with, so that what a chat can read shows.
    @State private var folded: Set<String> = []

    var body: some View {
        // The engine's order of agents, as the sidebar has them; only those with memory on and a note, as a chat reads them.
        let agents = engine.agents.compactMap { agent -> (AgentProfile, [MemoryNote])? in
            let memory = AgentMemoryState(engine.extras["memory"]?["agents"]?[agent.id])
            return memory.enabled && !memory.notes.isEmpty ? (agent, memory.notes) : nil
        }
        Section {
            if agents.isEmpty {
                Text("None of your agents keeps notes. An agent does once Remember things between conversations is on in its settings.").foregroundStyle(.secondary)
            }
            ForEach(agents, id: \.0.id) { agent, notes in
                DisclosureGroup(isExpanded: Binding(
                    get: { !folded.contains(agent.id) },
                    set: { open in if open { folded.remove(agent.id) } else { folded.insert(agent.id) } }
                )) {
                    ForEach(notes) { note in
                        Text(note.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHint("\(agent.name)'s note, read-only here")
                    }
                } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, size: 18)
                        Text(agent.name)
                        Spacer()
                        Text(notes.count == 1 ? "1 note" : "\(notes.count) notes").foregroundStyle(.secondary)
                        Image(systemName: "lock").foregroundStyle(.secondary).help("Read-only here")
                    }
                }
            }
        } header: {
            Text("Agents' notes")
        } footer: {
            Text(enabled
                ? "A chat can read these when a question calls for it, but cannot change or remove them. They are read-only here: change them in each agent's settings, under Memory. It never works the other way: no agent sees what chats remember."
                : "With memory off, chats do not read these. They are read-only here: change them in each agent's settings, under Memory.").formFooter()
        }
    }
}
