import EngineKit
import PiModels
import SwiftUI

/// One piece of work, or one issue of an attached repository (docs/design/iphone.md, "The Work tab"): its title and
/// where it stands, **Give to an agent** while nobody has it, its text, what finishing it said, its notes with a field
/// for another, and the state table's other actions, as the Mac's opened piece has them. A change shows at once, and
/// goes back with the engine's words if it is refused.
struct WorkItemScreen: View {
    let project: ProjectRow
    let listing: WorkListing
    let agents: [AgentProfile]
    let itemID: Int
    /// Debug builds only: a start the project's limit held, to draw its question; and what sample this shows.
    var initialHeld: WorkHeldStart?
    var sample: String?

    @Environment(AppSession.self) private var session
    @Environment(\.placement) private var placement
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var desk = WorkDesk()
    @State private var giving = false
    @State private var editing = false
    @State private var noteText = ""
    @State private var filling = false

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let problem = desk.problem {
                    WorkProblemBar(words: problem) { desk.problem = nil }
                }
            }
            .workHeldStart(desk: desk, engine: session.engine, project: project.id)
            .onAppear { WorkWatch.shows(project.id, engine: session.engine) }
            .onDisappear { WorkWatch.hides(project.id, engine: session.engine) }
            .modifier(WorkScreenChrome(placement: placement, title: "\(listing.noun == "issue" ? "Issue" : "Work") #\(itemID)") {
                EmptyView()
            })
            .task(id: itemID) {
                if let initialHeld, desk.held == nil { desk.held = initialHeld }
                await fill()
                #if DEBUG
                await debugAct()
                #endif
            }
    }

    @ViewBuilder
    private var content: some View {
        if let listed = listing.item(itemID) {
            page(listed)
        } else if listing.firstRead || filling {
            ProgressView(listing.onGitHub ? "Reading it from GitHub…" : "Reading the work list from your Mac…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Not in the list", systemImage: "checklist")
            } description: {
                Text(listing.onGitHub ? "Issue #\(itemID) is no longer in the list." : "This piece of work is no longer in the list.")
            } actions: {
                if placement == .screen {
                    Button("All Work") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func page(_ listed: WorkItem) -> some View {
        let change = desk.pending[listed.id]
        let item = listed.showing(change)
        let canChange = change == nil && !listing.troubled
        return List {
            if let sample {
                Text("Sample data (\(sample)), drawn by a debug build: not from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Section {
                top(item, pending: change?.word)
                if item.givable, !agents.isEmpty {
                    Button {
                        giving = true
                    } label: {
                        Label("Give to an Agent", systemImage: "person.crop.circle.badge.plus")
                            .labelStyle(.titleAndIcon)
                            .fontWeight(.semibold)
                            // The accent is light in dark mode: the background's colour on it reads in both.
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canChange)
                    .accessibilityHint("Chooses the agent that starts working on it.")
                }
                if item.held, let conversation = item.holderConversation {
                    Button {
                        openRoute(.conversation(conversation))
                    } label: {
                        Label("Open Its Conversation", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityHint("Opens sub-chat \(conversation), where \(holderName(item)) works on it.")
                }
            }
            if let trouble = listing.troubleWords() {
                Section {
                    Label(trouble, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.multicolor)
                }
            }
            ForEach(listing.unknown) { write in
                Section {
                    WorkUnknownCard(write: write, busy: desk.settling.contains(write.intent)) { happened in
                        Task { await desk.settle(session.engine, project: project.id, write: write, happened: happened) }
                    }
                }
            }
            Section("Text") {
                if listed.partial {
                    Label("Reading its text and comments from GitHub…", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                } else if listed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No text.").foregroundStyle(.secondary)
                } else {
                    WorkProse(text: listed.text)
                }
            }
            if let result = listed.result {
                Section(listing.onGitHub ? "What finishing it said was done" : "Result") {
                    WorkProse(text: result)
                }
            }
            if !listed.partial {
                notes(listed, canChange: canChange)
            }
            actions(item, listed: listed, canChange: canChange)
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $giving) {
            WorkGiveSheet(item: listed, noun: listing.noun, agents: agents, holding: holding) { agent in
                Task { await desk.assign(session.engine, project: project.id, item: listed, to: agent) }
            }
        }
        .sheet(isPresented: $editing) {
            WorkComposer(mode: .edit(listed), noun: listing.noun, destination: "The title is one line; the text can be any length.") { title, text in
                let taken = await desk.act(session.engine, project: project.id, item: listed, "edit", ["title": title, "text": text])
                return taken ? nil : (desk.problem ?? "It was not saved.")
            }
        }
    }

    /// Its number and title, and one line of where it stands: its state, who has it and where, what class of model it
    /// needs, and when it last changed, with the change on its way before them.
    private func top(_ item: WorkItem, pending: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("#\(item.id)  ").foregroundStyle(.secondary).monospacedDigit() + Text(item.title).foregroundStyle(.primary))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let pending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(pending)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            WorkFlow(spacing: 8) {
                WorkTag(state: item.state)
                WorkHolder(agent: session.engine.agent(item.holderAgentId), agentId: item.holderAgentId)
                if item.held, let conversation = item.holderConversation {
                    Text(branchWords(conversation))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            WorkFlow(spacing: 8) {
                Text(classWords(item.modelClass))
                if !typeSize.isAccessibilitySize { Text("·").accessibilityHidden(true) }
                Text("changed ") + Text(WorkTime.ago(item.updatedAt))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Its notes (on GitHub, comments), in the order they were added, then one on its way, faded, then the field for
    /// another.
    private func notes(_ item: WorkItem, canChange: Bool) -> some View {
        Section {
            ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                WorkNoteRow(note: note, agent: session.engine.agent(note.agentId))
            }
            if let sending = desk.sending[item.id] {
                WorkNoteRow(note: WorkItem.Note(at: .now, agentId: nil, text: sending), agent: nil, sending: true)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a \(listing.noteWord)", text: $noteText,
                          prompt: Text("Add a \(listing.noteWord) to this \(listing.noun)"), axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityLabel("New \(listing.noteWord) on \(listing.noun) #\(item.id)")
                    .submitLabel(.send)
                Button("Add") { addNote(item) }
                    .buttonStyle(.bordered)
                    .disabled(!canChange || noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(!canChange)
        } header: {
            Text(item.notes.isEmpty ? (listing.onGitHub ? "Comments" : "Notes") : "\(listing.onGitHub ? "Comments" : "Notes") · \(item.notes.count)")
        }
    }

    /// The state table's actions from where it is (docs/projects.md, 3.11), each with the table's word, as the Mac's
    /// bar has them; Give to an Agent is at the top. On GitHub they are all made there.
    @ViewBuilder
    private func actions(_ item: WorkItem, listed: WorkItem, canChange: Bool) -> some View {
        Section {
            if item.held {
                actionButton("Release", systemImage: "arrow.uturn.backward",
                             hint: "Lets go of it: it goes back to open, with nobody on it.") { act(listed, "release") }
            }
            if ["waiting", "blocked"].contains(item.state) {
                actionButton("Resume", systemImage: "play",
                             hint: "Carries on with it: it goes back to in progress.") { act(listed, "resume") }
            }
            Menu {
                Picker("Class", selection: Binding(get: { item.modelClass ?? "" }, set: { chosen in
                    act(listed, "classify", ["class": chosen.isEmpty ? (NSNull() as Any) : (chosen as Any)])
                })) {
                    Text("Local model").tag("local")
                    Text("Cloud model").tag("cloud")
                    Text("Not classified").tag("")
                }
            } label: {
                Label("Classify", systemImage: "cpu")
            }
            .accessibilityHint("Says what class of model it needs.")
            if !listed.partial {
                actionButton("Edit", systemImage: "pencil", hint: "Changes its title and text.") { editing = true }
            }
            if item.held || item.state == "open" {
                Menu {
                    Button("Close as Done", systemImage: "checkmark.circle") { act(listed, "close", ["as": "done"]) }
                    Button("Close as Dropped", systemImage: "xmark.circle") { act(listed, "close", ["as": "dropped"]) }
                } label: {
                    Label("Close", systemImage: "checkmark.circle")
                }
                .accessibilityHint(listing.onGitHub ? "Closes the issue on GitHub: done, or dropped as not worth doing."
                    : "Closes it: done, or dropped as not worth doing.")
            }
            if item.closed {
                actionButton("Reopen", systemImage: "arrow.counterclockwise",
                             hint: listing.onGitHub ? "Opens the issue again on GitHub." : "Opens it again: its result is cleared.") {
                    act(listed, "reopen")
                }
            }
            if let address = listed.url, let url = URL(string: address) {
                Link(destination: url) {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.square")
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            if listing.onGitHub { Text("Each is made on GitHub, as you, and undone there.") }
        }
        .disabled(!canChange)
    }

    private func actionButton(_ title: String, systemImage: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityHint(hint)
    }

    // MARK: - Words

    private func holderName(_ item: WorkItem) -> String {
        session.engine.agent(item.holderAgentId)?.name ?? item.holderAgentId ?? "its agent"
    }

    /// "in sub-chat 17, on fix-the-thing": where it is worked on, with the branch its sub-chat works on when the Mac
    /// knows it.
    private func branchWords(_ conversation: Int) -> String {
        var words = "in sub-chat \(conversation)"
        if let branch = session.engine.branches[conversation]?.branch { words += ", on \(branch)" }
        return words
    }

    private func classWords(_ modelClass: String?) -> String {
        switch modelClass {
        case "local": "needs a local model"
        case "cloud": "needs a cloud model"
        default: "not classified"
        }
    }

    private var holding: [String: [WorkItem]] {
        Dictionary(grouping: listing.items.filter { $0.held && $0.holderAgentId != nil }) { $0.holderAgentId ?? "" }
    }

    // MARK: - Changes

    private func act(_ item: WorkItem, _ action: String, _ extra: [String: Any] = [:]) {
        Task { await desk.act(session.engine, project: project.id, item: item, action, extra) }
    }

    private func addNote(_ item: WorkItem) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        noteText = ""
        Task {
            // Refused, the words come back to the field, so nothing typed is lost.
            if await desk.note(session.engine, project: project.id, item: item, text: text) != nil, noteText.isEmpty {
                noteText = text
            }
        }
    }

    /// Reads an issue whole when the list holds less of it than this screen shows, or the list was read over a minute
    /// ago, as the Mac does as one opens (`github.show`). What the list knows shows meanwhile.
    private func fill() async {
        guard listing.onGitHub, !filling else { return }
        let listed = listing.item(itemID)
        let fresh = listing.readAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        if listed?.partial == false && fresh { return }
        filling = true
        defer { filling = false }
        if let refused = await WorkRequests.show(session.engine, project: project.id, number: itemID) {
            desk.problem = "pi² could not read it whole from GitHub: \(refused)"
        }
    }

    #if DEBUG
    /// What `PI2_WORK_ACT` asks of a piece once it shows (`WorkDebugAct`).
    private func debugAct() async {
        try? await Task.sleep(for: .seconds(1))
        guard let item = listing.item(itemID) else { return }
        if WorkDebugAct.take("give") {
            if let name = WorkDebugAct.argument("give"), let agent = agents.first(where: { $0.name == name }) {
                await desk.assign(session.engine, project: project.id, item: item, to: agent)
            } else {
                giving = true
            }
        }
        if WorkDebugAct.take("edit") { editing = true }
        if WorkDebugAct.take("note"), let text = WorkDebugAct.argument("note") {
            noteText = text
            addNote(item)
        }
        if WorkDebugAct.take("close") { act(item, "close", ["as": "done"]) }
    }
    #endif
}

/// One note on a piece: who wrote it, with their mark when it is an agent, and when; then its words. One the person has
/// just sent shows faded, as on its way.
struct WorkNoteRow: View {
    let note: WorkItem.Note
    let agent: AgentProfile?
    var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkFlow(spacing: 6) {
                if let agentId = note.agentId {
                    WorkHolder(agent: agent, agentId: agentId)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                } else {
                    Text("You").fontWeight(.semibold).foregroundStyle(.primary)
                }
                if sending {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("sending")
                    }
                } else {
                    WorkAgo(date: note.at)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            WorkProse(text: note.text)
        }
        .padding(.vertical, 2)
        .opacity(sending ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A piece's text, a result or a note: its Markdown's inline marks (bold, code, links) drawn, its line breaks kept.
struct WorkProse: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
