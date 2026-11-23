import PiModels
import SwiftUI

// What the Work tab reads of the engine's `work` event — `WorkPiece`, `ProjectWork` and `WorkLimit` — is in PiModels
// (Work.swift, #828), shared with the iPhone app; what stays here is the tab's own view state.

extension WorkPiece {
    /// The piece as it will be once the change on its way is made: shown at once, until the engine says how it went
    /// (#599). `WorkPending` is this app's own view state, so the reading that takes it stays here with it.
    func showing(_ pending: WorkPending?) -> WorkPiece {
        guard let pending, let state = pending.state else { return self }
        return showing(state: state, holderAgentId: pending.holderAgentId, letsGo: pending.letsGo)
    }
}

/// A change the person asked for that the engine has not answered yet: the words that say so where it is shown, and
/// the state it takes the piece to, which the page shows at once (#599).
struct WorkPending: Equatable {
    /// "Closing", "Giving to Forge".
    let word: String
    var state: String?
    /// The agent it is given to.
    var holderAgentId: String?
    /// It goes back to nobody.
    var letsGo = false

    /// What an action of the state table (docs/projects.md, 3.11) shows while it is on its way.
    static func of(_ action: String, _ extra: [String: Any]) -> WorkPending {
        switch action {
        case "close": WorkPending(word: "Closing", state: extra["as"] as? String == "dropped" ? "dropped" : "done", letsGo: true)
        case "reopen": WorkPending(word: "Reopening", state: "open", letsGo: true)
        case "release": WorkPending(word: "Releasing", state: "open", letsGo: true)
        case "resume": WorkPending(word: "Resuming", state: "in_progress")
        case "classify": WorkPending(word: "Classifying")
        case "edit": WorkPending(word: "Saving")
        case "note": WorkPending(word: "Adding a note")
        default: WorkPending(word: "Working")
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
/// one for its text, notes and result, and giving one to an agent, which starts it. A project whose work is an attached
/// GitHub repository gets that repository's issues and pull requests instead, from `ProjectWorkGitHub` (#480). Both draw
/// the page with the same parts (`WorkParts.swift`, #599).
struct ProjectWorkTab: View {
    let model: AppModel
    let project: ProjectRow

    /// One row of the list as it is laid out, in one lazy stack: a group's heading, a piece, or the space between groups.
    private enum Entry: Identifiable {
        case heading(id: String, name: String, count: Int, folded: Bool)
        case piece(WorkPiece)
        case gap(String)

        var id: String {
            switch self {
            case .heading(let id, _, _, _): "heading:\(id)"
            case .piece(let piece): "piece:\(piece.id)"
            case .gap(let id): "gap:\(id)"
            }
        }
    }

    @State private var opened: Int?
    @State private var adding = false
    /// The form takes the title's field as it comes, so a new piece starts with typing: the message field beside it has
    /// the keyboard otherwise, and what is typed there would go to the orchestrator.
    @FocusState private var addingTitle: Bool
    @State private var newTitle = ""
    @State private var newText = ""
    @State private var addProblem: String?
    /// Whether the opened piece's title and text are in fields to change, and what they hold.
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var noteText = ""
    /// A note sent and not yet answered for, by the piece it is on.
    @State private var sending: [Int: String] = [:]
    /// Changes the engine has not answered for yet, by piece: shown at once where the piece is.
    @State private var pending: [Int: WorkPending] = [:]
    @State private var problem: String?
    /// A start the project's limit refused, to confirm or leave.
    @State private var heldStart: HeldStart?

    private var engine: EngineClient { model.engine }
    private var work: ProjectWork { ProjectWork(engine.extras["work"]?["projects"]?[project.id]) }
    /// The project's workers, not its orchestrator and none a tool removed: the same list the Agents tab of the board
    /// shows, since work is given to an agent that can take it and is here to do so (#553).
    private var agents: [AgentProfile] { workAgents(engine: engine, project: project) }

    var body: some View {
        VStack(spacing: 0) {
            if project.repository != nil {
                ProjectWorkGitHub(model: model, project: project)
            } else {
                let work = self.work
                if let opened, let piece = work.items.first(where: { $0.id == opened }) {
                    pieceView(piece)
                } else if opened != nil {
                    WorkGone(back: { opened = nil })
                } else {
                    list(work)
                }
            }
            if let held = heldStart {
                HeldStartCard(
                    held: held,
                    start: { assign(held.piece, to: held.agent, confirming: held.limit) },
                    leave: { heldStart = nil }
                )
            } else if let problem {
                // An action that failed while the list shows, or the opened piece: said at the bottom of the tab.
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Theme.bad)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WorkInset.value).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // The engine reads a GitHub repository's issues for the tabs an app says it shows (docs/projects.md, 4.2), so
        // this one says it while it is on screen. Per connection: the last word stands, and a disconnect forgets it. The
        // tab never waits for its answer: it draws what the app already has.
        .onAppear { ProjectTabWatch.shared.shows(project.id, tab: .work, engine: engine) }
        .onDisappear { ProjectTabWatch.shared.hides(project.id, tab: .work, engine: engine) }
        .onChange(of: opened) { _, _ in
            editing = false
            noteText = ""
        }
    }

    // MARK: - The list

    private func list(_ work: ProjectWork) -> some View {
        VStack(spacing: 0) {
            WorkListBar(source: "Kept by pi²", icon: "checklist") {
                // The form puts its own Add Work and Cancel under it, so the accent marks that one action, not a button here.
                if !adding {
                    Button("New Work", action: beginAdding)
                        .buttonStyle(.piPrimary)
                        .controlSize(.small)
                        .help("Add a piece of work to this project's list")
                }
            }
            if adding { newWorkForm }
            if work.items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries(work)) { entry in
                            entryView(entry)
                        }
                    }
                    .padding(.horizontal, WorkInset.value - 8).padding(.vertical, WorkInset.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The groups in the state table's order, each folded by its heading as the person left it in this project
    /// (`ProjectHubs.workFolded`, #599); folded, its heading keeps its count.
    private func entries(_ work: ProjectWork) -> [Entry] {
        var entries: [Entry] = []
        for (state, name, items) in work.grouped {
            let folded = model.hubs.workFolded(project.id, section: state)
            if !entries.isEmpty { entries.append(.gap(state)) }
            entries.append(.heading(id: state, name: name, count: items.count, folded: folded))
            if !folded { entries += items.map(Entry.piece) }
        }
        return entries
    }

    @ViewBuilder
    private func entryView(_ entry: Entry) -> some View {
        switch entry {
        case .heading(let id, let name, let count, let folded):
            WorkGroupHeading(name: name, count: count, folded: folded) {
                model.hubs.setWorkFolded(!folded, section: id, for: project.id)
            }
            .padding(.bottom, 4)
        case .piece(let piece):
            row(piece)
        case .gap:
            Color.clear.frame(height: 14)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $newTitle, prompt: Text("Title of the work"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($addingTitle)
                    .accessibilityLabel("Title of the new work")
                TextField("What needs doing", text: $newText, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...4)
                    .accessibilityLabel("Text of the new work")
                    .sendsOnReturn { addWork() }
            }
            .padding(10)
            .panel(radius: 12, fill: Theme.window, border: Theme.line2)
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
        .padding(WorkInset.value)
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

    private func row(_ piece: WorkPiece) -> some View {
        WorkRow(
            title: piece.title, label: "Work #\(piece.id), \(piece.title)", hint: "Open this piece of work",
            pending: pending[piece.id]?.word, open: { opened = piece.id }
        ) {
            WorkFacts(engine: engine, piece: piece)
        } trailing: {
            // Giving it to an agent is the usual next step only for work nobody has; the rest are on its page.
            if piece.state == "open", piece.holderAgentId == nil, !agents.isEmpty, pending[piece.id] == nil {
                WorkGiveMenu(agents: agents, piece: piece, give: { assign(piece, to: $0) })
            }
        }
    }

    // MARK: - One piece, opened

    private func pieceView(_ listed: WorkPiece) -> some View {
        let piece = listed.showing(pending[listed.id])
        let canChange = pending[listed.id] == nil
        return VStack(spacing: 0) {
            WorkPageTop(number: "#\(piece.id)", title: piece.title, back: {
                opened = nil
                problem = nil
                heldStart = nil
            }) {
                WorkStatusLine(engine: engine, piece: piece, pending: pending[listed.id]?.word)
            }
            // What its state lets the person do stays put above its text, which can be any length (#553).
            WorkActionBar {
                WorkActions(
                    piece: piece, agents: agents, enabled: canChange,
                    act: { action, extra in act(listed, action, extra) },
                    assign: { assign(listed, to: $0) },
                    edit: canChange && !editing ? { beginEditing(listed) } : nil
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if editing {
                        editor(listed)
                    } else if listed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No text.").font(.system(size: 13)).foregroundStyle(Theme.tx3)
                    } else {
                        WorkProse(text: listed.text)
                    }
                    if let result = listed.result {
                        VStack(alignment: .leading, spacing: 8) {
                            WorkSectionHeading(text: "Result")
                            WorkProse(text: result)
                        }
                    }
                    WorkNotes(engine: engine, piece: listed, sending: sending[listed.id])
                }
                .padding(WorkInset.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // While the title and text are being changed, Save is the page's one primary button.
            if !editing {
                WorkNoteField(piece: listed, text: $noteText, enabled: canChange, add: { addNote(listed) })
            }
        }
    }

    /// The title and text in fields of their own, each with one border, to change and save or leave.
    private func editor(_ piece: WorkPiece) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $draftTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1...)
                .padding(8)
                .panel(radius: 8, fill: Theme.window, border: Theme.line2)
                .accessibilityLabel("Title of work #\(piece.id)")
            TextField("Text", text: $draftText, prompt: Text("What needs doing (you can leave this empty)"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(6...)
                .padding(8)
                .panel(radius: 8, fill: Theme.window, border: Theme.line2)
                .accessibilityLabel("Text of work #\(piece.id)")
            HStack(spacing: 8) {
                Button("Save Changes") { save(piece) }
                    .buttonStyle(.piPrimary)
                    .controlSize(.small)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editing = false }
                    .buttonStyle(.piGhost)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Changes

    private func beginEditing(_ piece: WorkPiece) {
        draftTitle = piece.title
        draftText = piece.text
        editing = true
    }

    private func save(_ piece: WorkPiece) {
        // The title is one line wherever it is shown, so a line break typed into it becomes a space.
        let title = draftTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draftTitle = title
        editing = false
        send(piece, WorkPending(word: "Saving"), ["action": "edit", "title": title, "text": draftText],
             failed: { editing = true })
    }

    private func addNote(_ piece: WorkPiece) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pending[piece.id] == nil else { return }
        noteText = ""
        sending[piece.id] = text
        send(piece, WorkPending(word: "Adding a note"), ["action": "note", "text": text],
             then: { sending[piece.id] = nil },
             failed: {
                 sending[piece.id] = nil
                 if noteText.isEmpty { noteText = text }
             })
    }

    /// One action of the state table, as the person pressed its button.
    private func act(_ piece: WorkPiece, _ action: String, _ extra: [String: Any] = [:]) {
        send(piece, WorkPending.of(action, extra), ["action": action].merging(extra) { _, new in new })
    }

    /// Sends one change of a piece, shown at once where the piece is until the engine answers; refused, the piece is
    /// as it was and the engine's words show at the bottom of the tab.
    private func send(
        _ piece: WorkPiece, _ shown: WorkPending, _ params: [String: Any],
        then done: @escaping () -> Void = {}, failed: @escaping () -> Void = {}
    ) {
        guard pending[piece.id] == nil else { return }
        pending[piece.id] = shown
        Task {
            defer { pending[piece.id] = nil }
            do {
                try await engine.call("work.act", ["projectId": project.id, "id": piece.id].merging(params) { _, new in new })
                done()
                problem = nil
            } catch {
                failed()
                problem = error.localizedDescription
            }
        }
    }

    /// Gives the work to an agent, which starts it. Past a limit, the engine refuses with its reading, and the person
    /// confirms that one start (docs/projects.md, 8.3); `confirming` is that confirmation.
    private func assign(_ piece: WorkPiece, to agent: AgentProfile, confirming: WorkLimit? = nil) {
        guard pending[piece.id] == nil else { return }
        pending[piece.id] = WorkPending(word: "Giving to \(agent.name)", state: "in_progress", holderAgentId: agent.id)
        var params: [String: Any] = ["projectId": project.id, "id": piece.id, "action": "assign", "agentId": agent.id]
        if let confirming { params["confirmLimit"] = confirming.id }
        Task {
            defer { pending[piece.id] = nil }
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
}
