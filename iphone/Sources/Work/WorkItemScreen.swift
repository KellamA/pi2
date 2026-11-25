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
    /// The engine's words when it would not read the issue whole for the phone (`github.show`).
    @State private var unread: String?

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
                #if DEBUG
                await debugAct()
                #endif
            }
            // Only on the channel: while the app shows the store's last state, the Mac is not there to read it.
            .task(id: "\(itemID)|\(live)") { await fill() }
    }

    /// The client is on the channel to the Mac, not on the store's last state.
    private var live: Bool {
        if case .connected = session.connection { true } else { false }
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
                if let unread {
                    Text("Issue #\(itemID) is not in the list read from GitHub. \(Self.unreadWords(unread))")
                } else {
                    Text(listing.onGitHub ? "Issue #\(itemID) is no longer in the list." : "This piece of work is no longer in the list.")
                }
            } actions: {
                if placement == .screen {
                    Button("All Work") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func page(_ listed: WorkPiece) -> some View {
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
                if listed.partial, let unread {
                    Label(Self.unreadWords(unread), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if listed.partial {
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
    private func top(_ item: WorkPiece, pending: String?) -> some View {
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
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            // A line of its own: a branch is named after the piece's title, and beside the tag it wrapped in a narrow
            // column (seen against a copy, where the Mac makes a worktree for the piece given).
            if item.held, let conversation = item.holderConversation {
                Text(Self.whereWorked(conversation: conversation, branch: session.engine.branches[conversation]?.branch))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
    private func notes(_ item: WorkPiece, canChange: Bool) -> some View {
        Section {
            ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                WorkNoteRow(at: note.at, agentId: note.agentId, text: note.text, agent: session.engine.agent(note.agentId))
            }
            if let sending = desk.sending[item.id] {
                WorkNoteRow(at: .now, agentId: nil, text: sending, agent: nil, sending: true)
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
    private func actions(_ item: WorkPiece, listed: WorkPiece, canChange: Bool) -> some View {
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

    private func holderName(_ item: WorkPiece) -> String {
        session.engine.agent(item.holderAgentId)?.name ?? item.holderAgentId ?? "its agent"
    }

    /// "In sub-chat 17, on fix-the-thing": where it is worked on, with the branch its sub-chat works on when the Mac
    /// knows it.
    static func whereWorked(conversation: Int, branch: String?) -> String {
        var words = "In sub-chat \(conversation)"
        if let branch { words += ", on \(branch)" }
        return words
    }

    private func classWords(_ modelClass: String?) -> String {
        switch modelClass {
        case "local": "needs a local model"
        case "cloud": "needs a cloud model"
        default: "not classified"
        }
    }

    private var holding: [String: [WorkPiece]] {
        Dictionary(grouping: listing.items.filter { $0.held && $0.holderAgentId != nil }) { $0.holderAgentId ?? "" }
    }

    // MARK: - Changes

    private func act(_ item: WorkPiece, _ action: String, _ extra: [String: Any] = [:]) {
        Task { await desk.act(session.engine, project: project.id, item: item, action, extra) }
    }

    private func addNote(_ item: WorkPiece) {
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

    /// Reads an issue whole when the list holds less of it than this screen shows (`github.show`), once the client is on
    /// the channel. What the list knows shows meanwhile; if the Mac will not read it, the screen says so where the text
    /// would be.
    private func fill() async {
        guard Self.wantsWholeRead(listing, itemID: itemID, live: live), !filling, unread == nil else { return }
        filling = true
        defer { filling = false }
        unread = await WorkRequests.show(session.engine, project: project.id, number: itemID)
    }

    /// Whether the screen asks the Mac to read an issue whole: on the channel, for one the list holds only briefly (a
    /// closed one) or not at all. The Mac also reads one again that is whole but was read over a minute ago; the phone
    /// does not, since the engine takes `github.show` from the Mac alone (iphone.md 4.2 does not name it), and the
    /// listing it already has is read again by Pull to Refresh and while the tab shows.
    static func wantsWholeRead(_ listing: WorkListing, itemID: Int, live: Bool) -> Bool {
        guard listing.onGitHub, live, !listing.firstRead else { return false }
        return listing.item(itemID)?.partial ?? true
    }

    /// What the screen says where an issue's text would be when the Mac would not read it whole for the phone, with
    /// the engine's words.
    static func unreadWords(_ refusal: String) -> String {
        "Its text and comments were not read for this iPhone. Your Mac answered: “\(refusal.trimmingCharacters(in: .whitespacesAndNewlines))” Open it on GitHub, or on your Mac, to read them."
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
        if WorkDebugAct.take("give-anyway"), let name = WorkDebugAct.argument("give-anyway"),
           let agent = agents.first(where: { $0.name == name }) {
            await desk.assign(session.engine, project: project.id, item: item, to: agent)
            // What Start Anyway does, on the start the project's limit held.
            if let held = desk.held { await desk.assign(session.engine, project: project.id, item: held.item, to: held.agent, confirming: held.limit) }
        }
        if WorkDebugAct.take("edit") { editing = true }
        if WorkDebugAct.take("note"), let text = WorkDebugAct.argument("note") {
            noteText = text
            addNote(item)
        }
        if WorkDebugAct.take("close") { act(item, "close", ["as": WorkDebugAct.argument("close") == "dropped" ? "dropped" : "done"]) }
        for action in ["release", "resume", "reopen"] where WorkDebugAct.take(action) { act(item, action) }
        if WorkDebugAct.take("classify"), let chosen = WorkDebugAct.argument("classify") {
            act(item, "classify", ["class": chosen == "none" ? (NSNull() as Any) : (chosen as Any)])
        }
    }
    #endif
}

/// One note on a piece: who wrote it, with their mark when it is an agent, and when; then its words. One the person has
/// just sent shows faded, as on its way.
struct WorkNoteRow: View {
    let at: Date
    /// The agent that wrote the note; nil for the person.
    let agentId: String?
    let text: String
    let agent: AgentProfile?
    var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkFlow(spacing: 6) {
                if let agentId {
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
                    WorkAgo(date: at)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            WorkProse(text: text)
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
