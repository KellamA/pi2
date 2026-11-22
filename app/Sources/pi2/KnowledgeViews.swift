import ComposeKit
import PiModels
import SwiftUI

/// One thing an agent, or chat mode, keeps in mind between conversations.
struct MemoryNote: Identifiable, Equatable {
    let id: String
    let text: String
    let createdAt: Date
    /// False for a note the person wrote by hand.
    let writtenByAgent: Bool
}

/// What the engine last said an agent remembers, from the `memory` event it broadcasts. Chat mode's notes come in the
/// same shape, under `chat`, with no `enabled`: their switch is chat mode's `memory` setting (ChatSettings.swift).
struct AgentMemoryState: Equatable {
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

/// A note, editable in place: the change is sent when the person presses Return or leaves the field. Shift-Return or
/// Option-Return starts a new line, as in a message (#198).
struct MemoryNoteRow: View {
    let note: MemoryNote
    /// Says who wrote a note that the person did not: "Written by the agent", or "Written in a chat".
    var writtenBy = "Written by the agent"
    /// The lines the field grows to before it scrolls. Five suits the settings pages; the board's Notes tab shows a note
    /// in full, however long (docs/projects.md, 3.8, lets one be 400 characters), and asks for more.
    var maxLines = 5
    let save: (String) -> Void
    let remove: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(note: MemoryNote, writtenBy: String = "Written by the agent", maxLines: Int = 5, save: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.note = note
        self.writtenBy = writtenBy
        self.maxLines = maxLines
        self.save = save
        self.remove = remove
        _text = State(initialValue: note.text)
    }

    private var origin: String {
        let when = note.createdAt.formatted(date: .abbreviated, time: .shortened)
        return note.writtenByAgent ? "\(writtenBy), \(when)" : "Added by you, \(when)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Note", text: $text, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...maxLines)
                    .focused($focused)
                    .accessibilityLabel("Note")
                    .accessibilityValue(text)
                    .accessibilityHint(origin)
                    .sendsOnReturn { commit() }
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
