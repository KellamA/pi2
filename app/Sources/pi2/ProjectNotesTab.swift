import SwiftUI

/// One note of a project, as the engine's `memory` event sends it (docs/projects.md, 3.8): what an agent of the project
/// keeps for itself, or a note the person wrote by hand.
struct ProjectNote: Identifiable {
    struct CarriedFrom {
        let agentName: String
    }

    let id: String
    let text: String
    let createdAt: Date
    /// The agent that wrote it; nil for the person.
    let agentId: String?
    /// Who is given it: nil, every agent of the project; an agent's id, that agent alone (and the person, who shares it).
    let audience: String?
    /// The agent's note it was copied from, when carried over.
    let carriedFrom: CarriedFrom?

    /// The note as the row that edits in place reads it (KnowledgeViews.swift).
    var memory: MemoryNote {
        MemoryNote(id: id, text: text, createdAt: createdAt, writtenByAgent: agentId != nil)
    }
}

/// A project's notes, from the `memory` event's `projects` (docs/projects.md, 4.3), newest first.
struct ProjectNotes {
    let notes: [ProjectNote]

    init(_ value: JSONValue?) {
        notes = (value?["notes"]?.arrayValue ?? []).compactMap { item -> ProjectNote? in
            guard let id = item["id"]?.stringValue, let text = item["text"]?.stringValue else { return nil }
            var written = 0.0
            if case .number(let milliseconds)? = item["createdAt"] { written = milliseconds }
            var carried: ProjectNote.CarriedFrom?
            if let agentName = item["carriedFrom"]?["agentName"]?.stringValue {
                carried = ProjectNote.CarriedFrom(agentName: agentName)
            }
            return ProjectNote(
                id: id, text: text, createdAt: Date(timeIntervalSince1970: written / 1000),
                agentId: item["agentId"]?.stringValue, audience: item["audience"]?.stringValue, carriedFrom: carried
            )
        }
        // Notes made in the same millisecond, as a batch of them is, keep a settled order rather than taking turns.
        .sorted { left, right in
            left.createdAt == right.createdAt ? left.id > right.id : left.createdAt > right.createdAt
        }
    }
}

/// The board's Notes tab (#477): what the project's agents have noted, to read, correct and remove. A note the person
/// wrote goes to every agent of the project; one an agent wrote for itself alone can be shared with the project here.
struct ProjectNotesTab: View {
    let model: AppModel
    let project: ProjectRow

    /// The one inset the search field, the notes and the add field share, as the conversation's own parts do.
    private let inset: CGFloat = 12
    /// A note is 400 characters at most, which is a dozen lines even in the narrowest board: the row grows to this, so
    /// that all of one is shown.
    private let shownLines = 40

    @State private var query = ""
    @State private var newNote = ""
    @State private var adding = false
    @State private var addProblem: String?
    /// The engine's answer when a change to a note failed, by the note's id: shown under that note's field.
    @State private var problems: [String: String] = [:]

    private var engine: EngineClient { model.engine }

    var body: some View {
        let notes = ProjectNotes(engine.extras["memory"]?["projects"]?[project.id]).notes
        let matching = filtered(notes)
        VStack(spacing: 0) {
            // A project with no notes has nothing to search.
            if !notes.isEmpty { search }
            if notes.isEmpty {
                empty
            } else if matching.isEmpty {
                noMatch
            } else {
                list(matching)
            }
            Divider().overlay(Theme.line)
            addField
        }
        .onChange(of: notes.map(\.id)) { _, ids in
            // A note that has gone takes its problem with it.
            problems = problems.filter { ids.contains($0.key) }
        }
        .onChange(of: notes.isEmpty) { _, gone in
            // The field is gone too, so the search goes with it: a note added later is not filtered by one nobody sees.
            if gone { query = "" }
        }
    }

    /// Filters the list as the person types, over the notes' text.
    private func filtered(_ notes: [ProjectNote]) -> [ProjectNote] {
        let looked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !looked.isEmpty else { return notes }
        return notes.filter { $0.text.localizedCaseInsensitiveContains(looked) }
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tx3)
            TextField("Search notes", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search notes")
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.tx3)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.window.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(.horizontal, inset).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text("Notes").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
            Text("Notes are what this project's agents keep about it as they work: facts, decisions and preferences. They are added by the agents; you can add one below.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatch: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text("No notes match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ notes: [ProjectNote]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(notes) { note in
                    row(note)
                }
            }
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ note: ProjectNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MemoryNoteRow(
                note: note.memory,
                writtenBy: writer(note),
                maxLines: shownLines,
                save: { text in change(note, "memory.edit", ["projectId": project.id, "id": note.id, "text": text]) },
                remove: { change(note, "memory.delete", ["projectId": project.id, "id": note.id]) }
            )
            if let problem = problems[note.id] {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
            if let audience = note.audience {
                HStack(spacing: 6) {
                    Text("Only for \(name(audience, of: note))").font(.caption).foregroundStyle(.secondary)
                    Button("Share with the Project") {
                        change(note, "memory.edit", ["projectId": project.id, "id": note.id, "audience": NSNull()])
                    }
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
                    .help("Share this note with every agent of the project")
                }
            }
        }
        // A note reads as a note that can be edited, not as an input box: the plain field of the message composer
        // beside it, not the bezel a field is drawn with. Settings' notes keep theirs.
        .textFieldStyle(.plain)
    }

    /// The agent's name from the `agents` event, or the one the note kept when it was carried over, or what the app calls
    /// an agent that has gone, as Activity does: never an id, which nobody reads.
    private func name(_ agentId: String, of note: ProjectNote) -> String {
        engine.agent(agentId)?.name ?? note.carriedFrom?.agentName ?? "a deleted agent"
    }

    /// Who wrote it, as the row says it: the agent's name. A note the person wrote is "Added by you" in the row.
    private func writer(_ note: ProjectNote) -> String {
        guard let agentId = note.agentId else { return "" }
        return "Written by \(name(agentId, of: note))"
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Add a note", text: $newNote, prompt: Text("Add a note of your own"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .lineLimit(1...3)
                    .accessibilityLabel("New note")
                    .sendsOnReturn { add() }
                Button("Add") { add() }
                    .buttonStyle(.piPrimary)
                    .disabled(adding || newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(inset)
            .panel(radius: 12, border: Theme.line2)
            if let addProblem {
                Text(addProblem).foregroundStyle(Theme.bad).font(.callout).padding(.horizontal, inset)
            }
        }
        .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, inset)
    }

    /// Sends one change of a note, and keeps the engine's answer for that note's row when it fails.
    private func change(_ note: ProjectNote, _ method: String, _ params: [String: Any]) {
        Task {
            do {
                try await engine.call(method, params)
                problems[note.id] = nil
            } catch {
                problems[note.id] = error.localizedDescription
            }
        }
    }

    private func add() {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        // One note at a time: a second Return or click must not add the same note twice.
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            do {
                try await engine.call("memory.add", ["projectId": project.id, "text": text])
                newNote = ""
                addProblem = nil
            } catch {
                addProblem = error.localizedDescription
            }
            adding = false
        }
    }
}
