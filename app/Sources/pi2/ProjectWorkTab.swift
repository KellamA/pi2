import SwiftUI

/// One piece of work as the engine's `work` event sends it (docs/projects.md, 3.11): a task for the project, in the list
/// pi² itself keeps for a project with no GitHub repository attached.
struct WorkPiece: Identifiable, Equatable {
    struct Note: Equatable {
        let at: Date
        /// The agent that wrote it; nil for the person.
        let agentId: String?
        let text: String
    }

    let id: Int
    let title: String
    let text: String
    let state: String
    /// The class of model the work needs (docs/issue-classes.md); nil when not classified.
    let modelClass: String?
    /// The agent working on it, and the sub-chat it works in; nil when nobody has it.
    let holderAgentId: String?
    let holderConversation: Int?
    let notes: [Note]
    /// What finishing it said was done.
    let result: String?
    let updatedAt: Date

    init?(_ value: JSONValue?) {
        guard let value, let id = value["id"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        var written = 0.0
        if case .number(let milliseconds)? = value["updatedAt"] { written = milliseconds }
        let taken = value["takenBy"]
        self.id = id
        self.title = title
        text = value["text"]?.stringValue ?? ""
        state = value["state"]?.stringValue ?? "open"
        modelClass = value["class"]?.stringValue
        holderAgentId = taken?["agentId"]?.stringValue
        holderConversation = taken?["conversationId"]?.intValue
        notes = (value["notes"]?.arrayValue ?? []).compactMap { note in
            guard let text = note["text"]?.stringValue else { return nil }
            var at = 0.0
            if case .number(let milliseconds)? = note["at"] { at = milliseconds }
            return WorkPiece.Note(
                at: Date(timeIntervalSince1970: at / 1000),
                agentId: note["by"]?["agentId"]?.stringValue, text: text
            )
        }
        result = value["result"]?.stringValue
        updatedAt = Date(timeIntervalSince1970: written / 1000)
    }
}

/// The work of one project, from the `work` event's `projects` (docs/projects.md, 4.3), grouped by state in the order the
/// state table lists them (3.11), with the empty groups left out.
struct ProjectWork {
    /// The states in the table's order, with the words the tab shows for each.
    static let groups: [(state: String, name: String)] = [
        ("open", "Open"), ("in_progress", "In progress"), ("waiting", "Waiting"),
        ("blocked", "Blocked"), ("done", "Done"), ("dropped", "Dropped"),
    ]

    let items: [WorkPiece]

    init(_ value: JSONValue?) {
        items = (value?.arrayValue ?? []).compactMap(WorkPiece.init)
    }

    /// The groups with something in them, each newest-changed first.
    var grouped: [(state: String, name: String, items: [WorkPiece])] {
        ProjectWork.groups.compactMap { group in
            let inState = items.filter { $0.state == group.state }.sorted { $0.updatedAt > $1.updatedAt }
            return inState.isEmpty ? nil : (group.state, group.name, inState)
        }
    }

    /// The word the tab shows for a state; a state it does not know reads as the engine sent it.
    static func name(of state: String) -> String {
        groups.first { $0.state == state }?.name ?? state
    }
}

/// What the project's limit was when the engine refused to start an agent (docs/projects.md, 8.3), with the opaque id of
/// that reading, for confirming the one start it refused.
struct WorkLimit: Equatable {
    let id: String
    /// "planShare" or "dailySpend".
    let kind: String
    /// What was over, as the engine read it.
    let reason: String

    init?(_ value: JSONValue?) {
        guard let id = value?["id"]?.stringValue, let kind = value?["limit"]?.stringValue,
              let reason = value?["reason"]?.stringValue else { return nil }
        self.id = id
        self.kind = kind
        self.reason = reason
    }

    /// The limit as the person reads its name.
    var name: String {
        switch kind {
        case "dailySpend": "daily spending limit"
        case "planShare": "plan share limit"
        default: "limit"
        }
    }
}

/// An assignment the project's limit refused: held until the person confirms that one start or leaves it (8.3).
struct HeldStart: Equatable {
    let piece: WorkPiece
    let agent: AgentProfile
    let limit: WorkLimit
}

/// The board's Work tab (#479): the project's work, kept by pi² itself — grouped by state, a new piece of work, opening
/// one for its text, notes and result, and giving one to an agent, which starts it. A project whose work is a GitHub
/// repository's issues and pull requests gets one line saying so, until the view for them lands (#480).
struct ProjectWorkTab: View {
    let model: AppModel
    let project: ProjectRow

    @State private var opened: Int?
    @State private var adding = false
    /// The form takes the title's field as it comes, so a new piece starts with typing: the message field beside it has
    /// the keyboard otherwise, and what is typed there would go to the orchestrator.
    @FocusState private var addingTitle: Bool
    @State private var newTitle = ""
    @State private var newText = ""
    @State private var addProblem: String?
    /// The piece's title and text as the person is editing them, with the piece as last seeded.
    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var draftBase: WorkPiece?
    @State private var noteText = ""
    @State private var problem: String?
    /// A start the project's limit refused, to confirm or leave.
    @State private var heldStart: HeldStart?

    private var engine: EngineClient { model.engine }
    private var work: ProjectWork { ProjectWork(engine.extras["work"]?["projects"]?[project.id]) }
    private var piece: WorkPiece? { opened.flatMap { id in work.items.first { $0.id == id } } }
    /// The project's other agents, not its orchestrator and none a tool removed: the same list the Agents tab of the
    /// board shows, since work is given to an agent that can take it and is here to do so (#553).
    private var agents: [AgentProfile] {
        engine.allAgents
            .filter { $0.projectId == project.id && $0.id != project.orchestratorId && $0.removedAt == nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    private var edited: Bool {
        guard let base = draftBase else { return false }
        return draftTitle != base.title || draftText != base.text
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.repository != nil {
                repositoryNote
            } else if let piece {
                pieceView(piece)
            } else if opened != nil {
                gone
            } else {
                list
            }
            if let held = heldStart {
                heldCard(held)
            } else if let problem {
                // An action that failed while the list shows, or the opened piece: said at the bottom of the tab.
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Theme.bad)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // The engine reads a GitHub repository's issues for the tabs an app says it shows (docs/projects.md, 4.2), so
        // this one says it while it is on screen. Per connection: the last word stands, and a disconnect forgets it.
        .onAppear { ProjectTabWatch.shared.shows(project.id, tab: .work, engine: engine) }
        .onDisappear { ProjectTabWatch.shared.hides(project.id, tab: .work, engine: engine) }
        .onChange(of: opened) { _, latest in seedDrafts(latest.flatMap { id in work.items.first { $0.id == id } }) }
        .onChange(of: piece) { _, latest in
            // Follow what the engine says, unless the person is in the middle of editing.
            if !edited { seedDrafts(latest) } else { draftBase = latest }
        }
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            bar
            if adding { newWorkForm }
            if work.items.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(work.grouped, id: \.state) { group in
                            groupView(group)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 4)
            // The form puts its own Add Work and Cancel under it, so the accent marks that one action, not a button here.
            if !adding {
                Button("New Work", action: beginAdding)
                    .buttonStyle(.piPrimary)
                    .controlSize(.small)
                    .help("Add a piece of work to this project's list")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func beginAdding() {
        newTitle = ""
        newText = ""
        addProblem = nil
        adding = true
        // The field exists only once the form is in place, so it is focused on the turn after, as the composer beside it
        // is what has the keyboard until then.
        DispatchQueue.main.async { addingTitle = true }
    }

    private var newWorkForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $newTitle, prompt: Text("Title of the work"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .focused($addingTitle)
                .accessibilityLabel("Title of the new work")
            TextField("What needs doing", text: $newText, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .accessibilityLabel("Text of the new work")
                .sendsOnReturn { addWork() }
            HStack(spacing: 8) {
                Button("Add Work", action: addWork)
                    .buttonStyle(.piPrimary)
                    .controlSize(.small)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { adding = false }
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
                if let addProblem {
                    Text(addProblem).font(.callout).foregroundStyle(Theme.bad).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .panel(radius: 12, border: Theme.line2)
        .padding(.horizontal, 12).padding(.top, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func addWork() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do {
                try await engine.call("work.create", ["projectId": project.id, "title": title, "text": newText])
                adding = false
                addProblem = nil
            } catch {
                addProblem = error.localizedDescription
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text("No work yet").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
            Text("A piece of work is a task for this project, kept in a list pi² itself holds. Give one to an agent and it starts working on it; the orchestrator adds work here too.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !adding {
                Button("New Work", action: beginAdding)
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupView(_ group: (state: String, name: String, items: [WorkPiece])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
                Text(String(group.items.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tx3)
                    .monospacedDigit()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.card2, in: .rect(cornerRadius: 4))
            }
            ForEach(group.items) { piece in
                row(piece)
            }
        }
    }

    private func row(_ piece: WorkPiece) -> some View {
        HStack(spacing: 10) {
            Button { opened = piece.id } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(piece.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.tx)
                            .lineLimit(1)
                        Text("#\(piece.id)").font(Theme.mono).foregroundStyle(Theme.tx3)
                    }
                    whoHas(piece)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Work #\(piece.id), \(piece.title)")
            .accessibilityHint("Open this piece of work")
            // A menu inside the row's button is not a control of its own, so it sits beside it in the row.
            if piece.state == "open", !agents.isEmpty {
                giveMenu(piece)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    /// "Atlas · sub-chat 17 · 5 min ago", or "Nobody · 5 min ago": who has it and when it last changed.
    private func whoHas(_ piece: WorkPiece) -> some View {
        HStack(spacing: 5) {
            if let agentId = piece.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 12)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if let chat = piece.holderConversation {
                    Text("· sub-chat \(chat)").foregroundStyle(Theme.tx3)
                }
            } else {
                Text("Nobody").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(LimitsFormat.ago(piece.updatedAt, now: context.date)).foregroundStyle(Theme.tx3)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }

    /// The menu of the project's agents, on a row and in the opened piece. Giving work to one starts it: the engine
    /// claims the piece and starts a sub-chat of the orchestrator's conversation in one step.
    private func giveMenu(_ piece: WorkPiece) -> some View {
        Menu {
            ForEach(agents) { agent in
                Button { assign(piece, to: agent) } label: {
                    // The agent's own face, as the row and the status line show it, so the person can pick the worker
                    // they mean rather than read a name (#553).
                    HStack(spacing: 6) {
                        AgentAvatar(agent: agent, size: 16)
                        Text(agent.name)
                    }
                }
            }
        } label: {
            Text("Give to")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Give this work to an agent, which starts it working on it")
        .accessibilityLabel("Give work #\(piece.id) to an agent")
    }

    // MARK: - One piece, opened

    private func pieceView(_ piece: WorkPiece) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    opened = nil
                    problem = nil
                    heldStart = nil
                } label: {
                    Label("All Work", systemImage: "chevron.left")
                }
                .buttonStyle(.piGhost)
                .controlSize(.small)
                .help("Back to the project's work")
                Spacer(minLength: 4)
                Text("#\(piece.id)").font(Theme.mono).foregroundStyle(Theme.tx3)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            // Where the piece is and what its state lets the person do, above the scrolling text rather than at the end
            // of it: a piece's text can be any length, and these belong to the piece, so they stay to hand while its
            // text and notes are read (#553).
            VStack(alignment: .leading, spacing: 10) {
                status(piece)
                actions(piece)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Title", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1...)
                        .accessibilityLabel("Title of work #\(piece.id)")
                    TextField("Text", text: $draftText, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(2...)
                        .accessibilityLabel("Text of work #\(piece.id)")
                    if edited {
                        HStack(spacing: 8) {
                            Button("Save Changes") { save(piece) }
                                .buttonStyle(.piPrimary)
                                .controlSize(.small)
                            Button("Revert") { seedDrafts(piece) }
                                .buttonStyle(.piGhost)
                                .controlSize(.small)
                        }
                    }
                    notes(piece)
                    if let result = piece.result {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
                            Text(result)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.tx)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .panel(radius: 8, border: Theme.line)
                    }
                    noteField(piece)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Where it is, who holds it, where it is worked on, and what class of model it needs. The state is said here too: a
    /// waiting or blocked piece has a holder who is not working on it.
    private func status(_ piece: WorkPiece) -> some View {
        HStack(spacing: 6) {
            Text(ProjectWork.name(of: piece.state)).fontWeight(.medium).foregroundStyle(Theme.tx2)
            Text("·").foregroundStyle(Theme.tx3)
            if let agentId = piece.holderAgentId {
                AgentAvatar(agent: engine.agent(agentId), size: 12)
                Text(engine.agent(agentId)?.name ?? agentId).foregroundStyle(Theme.tx2)
                if let chat = piece.holderConversation {
                    Text("· sub-chat \(chat)").foregroundStyle(Theme.tx3)
                }
            } else {
                Text("Nobody has this yet").foregroundStyle(Theme.tx3)
            }
            Text("·").foregroundStyle(Theme.tx3)
            switch piece.modelClass {
            case "local": Text("needs a local model").foregroundStyle(Theme.tx3)
            case "cloud": Text("needs a cloud model").foregroundStyle(Theme.tx3)
            default: Text("not classified").foregroundStyle(Theme.tx3)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }

    /// The actions the state table allows the person from this piece's state (docs/projects.md, 3.11), each with the
    /// table's own word for it.
    @ViewBuilder
    private func actions(_ piece: WorkPiece) -> some View {
        let held = ["in_progress", "waiting", "blocked"].contains(piece.state)
        HStack(spacing: 8) {
            if piece.state == "open", !agents.isEmpty {
                giveMenu(piece)
            }
            if held {
                Button("Release") { act(piece, "release") }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Let go of this work: it goes back to open, with nobody on it")
            }
            if ["waiting", "blocked"].contains(piece.state) {
                Button("Resume") { act(piece, "resume") }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Carry on with this work: it goes back to in progress")
            }
            Menu {
                Button("Local model") { act(piece, "classify", ["class": "local"]) }
                Button("Cloud model") { act(piece, "classify", ["class": "cloud"]) }
                Button("Not classified") { act(piece, "classify", ["class": NSNull()]) }
            } label: {
                Text("Classify")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Say what class of model this work needs")
            .accessibilityLabel("Classify work #\(piece.id)")
            // Closing work is the final action, so it sits apart from the ones taken while the work carries on.
            Spacer(minLength: 8)
            if held || piece.state == "open" {
                Menu {
                    Button("Close as Done") { act(piece, "close", ["as": "done"]) }
                    Button("Close as Dropped") { act(piece, "close", ["as": "dropped"]) }
                } label: {
                    Text("Close")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Close this work: done, or dropped as not worth doing")
                .accessibilityLabel("Close work #\(piece.id)")
            }
            if ["done", "dropped"].contains(piece.state) {
                Button("Reopen") { act(piece, "reopen") }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                    .help("Open this work again: its result is cleared")
            }
        }
    }

    /// The piece's notes, in the order they were added, each with who wrote it and when.
    private func notes(_ piece: WorkPiece) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !piece.notes.isEmpty {
                Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx3)
            }
            ForEach(Array(piece.notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tx)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    noteLine(note)
                }
            }
        }
    }

    private func noteLine(_ note: WorkPiece.Note) -> some View {
        let who = note.agentId.map { engine.agent($0)?.name ?? $0 } ?? "You"
        // The time is kept current as the row's is, since the page stays open while a note ages.
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            Text("\(who) · \(LimitsFormat.ago(note.at, now: context.date))")
                .font(.caption)
                .foregroundStyle(Theme.tx3)
        }
    }

    private func noteField(_ piece: WorkPiece) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Add a note", text: $noteText, prompt: Text("Add a note to this work"), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...3)
                .accessibilityLabel("New note on work #\(piece.id)")
                .sendsOnReturn { addNote(piece) }
            Button("Add") { addNote(piece) }
                .buttonStyle(.piPrimary)
                .controlSize(.small)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel(radius: 12, border: Theme.line2)
    }

    // MARK: - Changes

    /// Brings the person's edits in step with the engine's piece. A piece just opened always seeds them, since what
    /// was typed on the last one is not this one's editing.
    private func seedDrafts(_ latest: WorkPiece?) {
        draftBase = latest
        draftTitle = latest?.title ?? ""
        draftText = latest?.text ?? ""
    }

    private func save(_ piece: WorkPiece) {
        // The title is one line wherever it is shown, so a line break typed into it becomes a space.
        let title = draftTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = title
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": piece.id, "action": "edit", "title": title, "text": draftText])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func addNote(_ piece: WorkPiece) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": piece.id, "action": "note", "text": text])
                noteText = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// One action of the state table, as the person pressed its button.
    private func act(_ piece: WorkPiece, _ action: String, _ extra: [String: Any] = [:]) {
        Task {
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": piece.id, "action": action].merging(extra) { _, new in new })
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Gives the work to an agent, which starts it. Past a limit, the engine refuses with its reading, and the person
    /// confirms that one start (docs/projects.md, 8.3); `confirming` is that confirmation.
    private func assign(_ piece: WorkPiece, to agent: AgentProfile, confirming: WorkLimit? = nil) {
        var params: [String: Any] = ["projectId": project.id, "id": piece.id, "action": "assign", "agentId": agent.id]
        if let confirming { params["confirmLimit"] = confirming.id }
        Task {
            do {
                try await engine.call("work.act", params)
                heldStart = nil
                problem = nil
            } catch let error as EngineError {
                // The refusal of a start past a limit carries the reading (8.3); anything else is just shown.
                if let limit = WorkLimit(error.data?["limit"]) {
                    heldStart = HeldStart(piece: piece, agent: agent, limit: limit)
                } else {
                    problem = error.localizedDescription
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: - The limit's confirmation

    /// Says which limit the start goes past and what that means, with the way to start it anyway.
    private func heldCard(_ held: HeldStart) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("Past the project's \(held.limit.name)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.tx)
            }
            Text("Starting \(held.agent.name) on “\(held.piece.title)” goes past it: \(held.limit.reason). Work already running carries on. Start it anyway?")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tx2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Start Anyway") {
                    assign(held.piece, to: held.agent, confirming: held.limit)
                }
                .buttonStyle(.piPrimary)
                .controlSize(.small)
                Button("Leave It") { heldStart = nil }
                    .buttonStyle(.piSecondary)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .panel(radius: 12, border: Theme.warn.opacity(0.55))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: - A project whose work is a GitHub repository

    /// One line, until the view of a repository's issues and pull requests lands (#480).
    private var repositoryNote: some View {
        let name = [project.repository?.owner, project.repository?.name].compactMap { $0 }.joined(separator: "/")
        return VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text("Work on GitHub").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.tx)
            Text("This project's work is the issues and pull requests of its GitHub repository\(name.isEmpty ? "" : " (\(name))"). That view comes later in the projects preview; the agents still see it through their work tool.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tx2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 380)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A piece that was open but is no longer in the list.
    private var gone: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Theme.tx3)
            Text("This piece of work is no longer in the list.").font(.system(size: 12.5)).foregroundStyle(Theme.tx2)
            Button("All Work") { opened = nil }
                .buttonStyle(.piSecondary)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
