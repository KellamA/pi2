import SwiftUI

/// One note of a project, as the engine's `memory` event sends it (docs/projects.md, 3.8): what an agent of the project
/// keeps for itself, or a note the person wrote by hand.
struct ProjectNote: Identifiable, Equatable {
    struct CarriedFrom: Equatable {
        let agentId: String
        let agentName: String
        let id: String
    }

    let id: String
    let text: String
    let createdAt: Date
    /// The conversation that wrote it; nil for a note the person wrote, or one carried over.
    let conversation: Int?
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
struct ProjectNotes: Equatable {
    var notes: [ProjectNote] = []

    init() {}

    init(_ value: JSONValue?) {
        notes = (value?["notes"]?.arrayValue ?? []).compactMap { item -> ProjectNote? in
            guard let id = item["id"]?.stringValue, let text = item["text"]?.stringValue else { return nil }
            var written = 0.0
            if case .number(let milliseconds)? = item["createdAt"] { written = milliseconds }
            var carried: ProjectNote.CarriedFrom?
            if let from = item["carriedFrom"],
               let agentId = from["agentId"]?.stringValue,
               let agentName = from["agentName"]?.stringValue,
               let id = from["id"]?.stringValue {
                carried = ProjectNote.CarriedFrom(agentId: agentId, agentName: agentName, id: id)
            }
            return ProjectNote(
                id: id, text: text, createdAt: Date(timeIntervalSince1970: written / 1000),
                conversation: item["conversation"]?.intValue, agentId: item["agentId"]?.stringValue,
                audience: item["audience"]?.stringValue, carriedFrom: carried
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

/// The board's Notes tab (#477): what the project's agents have noted, to read, correct and remove. A note the person
/// wrote goes to every agent of the project; one an agent wrote for itself alone can be shared with the project here.
struct ProjectNotesTab: View {
    let model: AppModel
    let project: ProjectRow

    @State private var query = ""
    @State private var newNote = ""
    @State private var addProblem: String?
    /// The engine's answer when a change to a note failed, by the note's id: shown under that note's field.
    @State private var problems: [String: String] = [:]

    private var engine: EngineClient { model.engine }

    var body: some View {
        let notes = ProjectNotes(engine.extras["memory"]?["projects"]?[project.id]).notes
        VStack(spacing: 0) {
            search
            if notes.isEmpty {
                empty
            } else if filtered(notes).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(Theme.tx3)
                    Text("No notes match “\(query)”.").font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(filtered(notes)) { note in
                            row(note)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().overlay(Theme.line)
            addField
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
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.window.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(.horizontal, 12).padding(.vertical, 8)
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

    @ViewBuilder
    private func row(_ note: ProjectNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MemoryNoteRow(
                note: note.memory,
                writtenBy: writer(note),
                save: { text in change(note, "memory.edit", ["projectId": project.id, "id": note.id, "text": text]) },
                remove: { change(note, "memory.delete", ["projectId": project.id, "id": note.id]) }
            )
            if let problem = problems[note.id] {
                Text(problem).foregroundStyle(Theme.bad).font(.callout)
            }
            if let audience = note.audience {
                HStack(spacing: 6) {
                    Text("Only for \(name(audience, of: note))").font(.caption).foregroundStyle(Theme.tx2)
                    Button("Share with the Project") {
                        change(note, "memory.edit", ["projectId": project.id, "id": note.id, "audience": NSNull()])
                    }
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
                    .help("Share this note with every agent of the project")
                }
            }
        }
    }

    /// The agent's name from the `agents` event, or the one the note kept when it was carried over, or the id itself.
    private func name(_ agentId: String, of note: ProjectNote) -> String {
        engine.agent(agentId)?.name ?? note.carriedFrom?.agentName ?? agentId
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
                    .labelsHidden()
                    .lineLimit(1...3)
                    .accessibilityLabel("New note")
                    .sendsOnReturn { add() }
                Button("Add") { add() }
                    .buttonStyle(.piPrimary)
                    .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .panel(radius: 12, border: Theme.line2)
            if let addProblem {
                Text(addProblem).foregroundStyle(Theme.bad).font(.callout).padding(.horizontal, 14)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
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
        guard !text.isEmpty else { return }
        Task {
            do {
                try await engine.call("memory.add", ["projectId": project.id, "text": text])
                newNote = ""
                addProblem = nil
            } catch {
                addProblem = error.localizedDescription
            }
        }
    }
}
