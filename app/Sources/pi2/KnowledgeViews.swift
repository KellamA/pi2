import SwiftUI

/// One thing an agent keeps in mind between conversations.
private struct MemoryNote: Identifiable, Equatable {
    let id: String
    let text: String
    let createdAt: Date
    /// False for a note the person wrote by hand.
    let writtenByAgent: Bool
}

/// What the engine last said an agent remembers, from the `memory` event it broadcasts.
private struct AgentMemoryState: Equatable {
    var enabled = false
    var notes: [MemoryNote] = []

    init() {}

    init(_ value: JSONValue?) {
        if case .bool(let on)? = value?["enabled"] { enabled = on }
        let list = value?["notes"]?.arrayValue ?? []
        // Newest first.
        notes = list.compactMap { item -> MemoryNote? in
            guard let id = item["id"]?.stringValue, let text = item["text"]?.stringValue else { return nil }
            var written = 0.0
            if case .number(let milliseconds)? = item["createdAt"] { written = milliseconds }
            var byAgent = false
            if case .number? = item["conversation"] { byAgent = true }
            return MemoryNote(id: id, text: text, createdAt: Date(timeIntervalSince1970: written / 1000), writtenByAgent: byAgent)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

/// What an agent remembers between conversations, shown and edited in its settings. Changes apply at once: they are
/// not part of the form's Save, because the agent may add notes itself at any time.
struct AgentMemorySection: View {
    let engine: EngineClient
    let agentID: String

    @State private var newNote = ""
    @State private var problem: String?

    private var memory: AgentMemoryState { AgentMemoryState(engine.extras["memory"]?["agents"]?[agentID]) }

    var body: some View {
        let memory = memory
        Section {
            Toggle("Remember things between conversations", isOn: Binding(
                get: { memory.enabled },
                set: { on in change("memory.setEnabled", ["agentId": agentID, "enabled": on]) }
            ))
            if memory.enabled || !memory.notes.isEmpty {
                ForEach(memory.notes) { note in
                    MemoryNoteRow(
                        note: note,
                        save: { text in change("memory.edit", ["agentId": agentID, "id": note.id, "text": text]) },
                        remove: { change("memory.delete", ["agentId": agentID, "id": note.id]) }
                    )
                }
                if memory.enabled && memory.notes.isEmpty {
                    Text("No notes yet. The agent adds them as you talk, or you can add one here.").foregroundStyle(.secondary)
                }
            }
            if memory.enabled {
                HStack(spacing: 8) {
                    TextField("Add a note", text: $newNote, prompt: Text("Add a note by hand"))
                        .labelsHidden()
                        .accessibilityLabel("New note")
                        .onSubmit { add() }
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
            Text(footer(memory)).formFooter()
        }
    }

    private func footer(_ memory: AgentMemoryState) -> String {
        var text = memory.enabled
            ? "The agent can keep short notes that carry over from one conversation to the next, such as your preferences and decisions. "
            : "Off: this agent starts every conversation knowing nothing from earlier ones. "
        text += "Every note is sent to the model in every conversation with this agent, so do not keep anything secret here. "
        if !memory.enabled, !memory.notes.isEmpty { text += "Its notes are kept but not sent while this is off. " }
        text += "Changes here apply at once, without Save."
        return text
    }

    private func add() {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await engine.call("memory.add", ["agentId": agentID, "text": text])
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

/// A note, editable in place: the change is sent when the person presses Return or leaves the field.
private struct MemoryNoteRow: View {
    let note: MemoryNote
    let save: (String) -> Void
    let remove: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(note: MemoryNote, save: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.note = note
        self.save = save
        self.remove = remove
        _text = State(initialValue: note.text)
    }

    private var origin: String {
        let when = note.createdAt.formatted(date: .abbreviated, time: .shortened)
        return note.writtenByAgent ? "Written by the agent, \(when)" : "Added by you, \(when)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Note", text: $text, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...5)
                    .focused($focused)
                    .accessibilityLabel("Note")
                    .accessibilityValue(text)
                    .accessibilityHint(origin)
                    .onSubmit { commit() }
                Text(origin).font(.caption).foregroundStyle(.secondary)
            }
            Button("Delete note", systemImage: "trash") { remove() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete this note")
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: note.text) { _, latest in
            // Follow what the engine says, unless the person is in the middle of typing.
            if !focused { text = latest }
        }
    }

    private func commit() {
        let tidy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if tidy.isEmpty {
            text = note.text
        } else if tidy != note.text {
            save(tidy)
        }
    }
}
