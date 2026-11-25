
import PiModels
import SwiftUI

/// The Notes page (the Mac's Notes tab, app/Sources/pi2/ProjectNotesTab.swift): what the project's agents keep about it
/// as they work, to read, search, correct and delete, and a note of the person's own to add. A note one agent wrote for
/// itself alone can be shared with the whole project.
struct BoardNotesPage: View {
    let project: ProjectRow
    let data: BoardData

    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var newNote = ""
    @State private var adding = false
    @State private var addProblem: String?
    /// The engine's words when a change to a note failed, by the note's id.
    @State private var problems: [String: String] = [:]
    @State private var editing: BoardNote?

    var body: some View {
        let notes = data.notes(project.id)
        let looked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = looked.isEmpty ? notes : notes.filter { $0.text.localizedCaseInsensitiveContains(looked) }
        List {
            if let sample = data.sample { BoardSampleNote(what: sample) }
            if notes.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No notes yet.", systemImage: "note.text").font(.headline)
                        Text("Notes are what this project's agents keep about it as they work: facts, decisions and preferences. They are added by the agents; you can add one below.")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
            } else if matching.isEmpty {
                Section {
                    Text("No notes match “\(looked)”.").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(matching) { note in row(note) }
                } header: {
                    Text(looked.isEmpty ? "\(notes.count) note\(notes.count == 1 ? "" : "s")" : "\(matching.count) of \(notes.count)")
                }
            }
            Section {
                TextField("New note", text: $newNote, prompt: Text("Add a note of your own"), axis: .vertical)
                    .lineLimit(1...5)
                Button("Add Note") { add() }
                    .disabled(adding || newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !data.connected)
            } header: {
                Text("Add a note")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let addProblem { BoardProblem(addProblem) }
                    Text("A note you write is given to every agent of the project that has memory on.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search notes")
        .sheet(item: $editing) { note in
            BoardNoteEditor(note: note) { text in
                await BoardRequests.editNote(session.engine, project: project.id, note: note.id, text: text)
            }
        }
        .onChange(of: notes.map(\.id)) { _, ids in
            // A note that has gone takes its problem with it.
            problems = problems.filter { ids.contains($0.key) }
        }
        #if DEBUG
        .task { await BoardDebugAct.notes(self, notes: notes) }
        #endif
    }

    private func row(_ note: BoardNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                editing = note
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.text).foregroundStyle(.primary)
                    Text(data.origin(note)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.text)
            .accessibilityHint("\(data.origin(note)). Opens it to correct.")
            if let audience = note.audience {
                ViewThatFits(in: .horizontal) {
                    HStack { onlyFor(audience, note) }
                    VStack(alignment: .leading, spacing: 4) { onlyFor(audience, note) }
                }
            }
            if let problem = problems[note.id] { BoardProblem(problem) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { delete(note) }
        }
        .contextMenu {
            Button("Correct…", systemImage: "pencil") { editing = note }
            if note.audience != nil {
                Button("Share with the Project", systemImage: "person.2") { share(note) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(note) }
        }
        .accessibilityAction(named: "Delete") { delete(note) }
    }

    @ViewBuilder
    private func onlyFor(_ audience: String, _ note: BoardNote) -> some View {
        BoardTag("Only for \(data.writer(audience, of: note))")
        Button("Share with the Project") { share(note) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!data.connected)
            .accessibilityHint("Gives this note to every agent of the project")
    }

    private func send(_ note: BoardNote, _ request: @escaping @MainActor () async -> String?, failed: String) {
        Task {
            problems[note.id] = await request().map { "\(failed): \($0)" }
        }
    }

    func share(_ note: BoardNote) {
        let engine = session.engine
        send(note, { await BoardRequests.shareNote(engine, project: project.id, note: note.id) }, failed: "Not shared")
    }

    func delete(_ note: BoardNote) {
        let engine = session.engine
        send(note, { await BoardRequests.deleteNote(engine, project: project.id, note: note.id) }, failed: "Not deleted")
    }

    private func add() {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        // One note at a time: a second tap must not add the same note twice.
        guard !text.isEmpty, !adding else { return }
        adding = true
        let engine = session.engine
        Task {
            if let problem = await BoardRequests.addNote(engine, project: project.id, text: text) {
                addProblem = "The note was not added: \(problem)"
            } else {
                addProblem = nil
                newNote = ""
            }
            adding = false
        }
    }

    #if DEBUG
    /// For `BoardDebugAct`: what a tap would do.
    func debugAdd(_ text: String) { newNote = text; add() }
    func debugEdit(_ note: BoardNote) { editing = note }
    func debugSave(_ note: BoardNote, text: String) {
        let engine = session.engine
        send(note, { await BoardRequests.editNote(engine, project: project.id, note: note.id, text: text) }, failed: "Not saved")
    }
    #endif
}

/// A note corrected in a sheet; the engine's words show there when it refuses.
struct BoardNoteEditor: View {
    let note: BoardNote
    let send: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var sending = false
    @State private var problem: String?

    init(note: BoardNote, send: @escaping (String) async -> String?) {
        self.note = note
        self.send = send
        _text = State(initialValue: note.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note", text: $text, axis: .vertical).lineLimit(3...16)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem { BoardProblem(problem) }
                        Text("A note is 400 characters at most.")
                    }
                }
            }
            .navigationTitle("Correct Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let tidy = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard tidy != note.text else { return dismiss() }
                        sending = true
                        Task {
                            problem = await send(tidy).map { "Not saved: \($0)" }
                            sending = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
