import EngineKit
import PiModels
import SwiftUI

/// Conversations other than an orchestrator's: a project's (its agents' and their sub-chats), or, with no project, those
/// outside projects, chats among them (docs/design/iphone.md, "An agent's conversation" and "Every screen and function
/// of the Mac app"). Each opens with `openRoute(.conversation(id))`, the conversation's own screen (#687), where it is read
/// and written to.
///
/// A row swiped or held offers what the Mac's sidebar and chat mode offer: Archive, Rename, Delete, and for a chat Pin.
/// With no project there is New Chat.
struct ConversationsView: View {
    /// The project whose conversations it lists, as `ProjectRow.id`; nil for those outside projects.
    let projectID: String?

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.placement) private var placement
    @State private var query = ""
    @State private var problem: String?
    @State private var making = false
    @State private var renaming: ConversationsRow?
    @State private var deleting: ConversationsDeletion?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }

    private var engine: EngineSession<MessageField> { session.engine }

    /// What the list shows: the engine's conversations, read as the Mac reads them; in a debug build, a sample when
    /// `PI2_CONVERSATIONS_SAMPLE` asks for one.
    private var listing: ConversationsListing {
        #if DEBUG
        if let sample = ConversationsSample.current?.listing(project: projectID) { return sample }
        #endif
        if let projectID { return .project(projectID, conversations: engine.conversations, agents: engine.allAgents) }
        return .outside(conversations: engine.conversations, agents: engine.allAgents)
    }

    private var isSample: Bool {
        #if DEBUG
        return ConversationsSample.current?.listing(project: projectID) != nil
        #else
        return false
        #endif
    }

    private var title: String {
        projectID == nil ? "Chats" : "Other conversations"
    }

    var body: some View {
        Group {
            if !isSample, engine.status != .connected || !engine.hasLoadedLibrary {
                ConversationsWaiting()
            } else if let projectID, !isSample, engine.conversationsProject(projectID) == nil {
                ContentUnavailableView(
                    "No such project", systemImage: "questionmark.folder",
                    description: Text("Your Mac has no project by this name now. It may have been deleted.")
                )
            } else if placement == .inline {
                inline(listing)
            } else {
                list(listing)
            }
        }
        .navigationTitle(placement == .screen ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .conversationsEditing(renaming: $renaming, deleting: $deleting, rename: rename, delete: delete)
        #if DEBUG
        .task(id: engine.hasLoadedLibrary) {
            guard engine.hasLoadedLibrary else { return }
            if await ConversationsSample.take("archive"), let row = listing.sections.first?.rows.first { archive(row) }
            if await ConversationsSample.take("new-chat") { newChat() }
        }
        #endif
        .toolbar {
            if placement == .screen, projectID == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chat", systemImage: "square.and.pencil", action: newChat)
                        .disabled(making)
                }
            }
        }
    }

    private func list(_ listing: ConversationsListing) -> some View {
        let shown = listing.filtered(query)
        return List {
            if isSample {
                ConversationsSampleNote()
            }
            if let problem {
                ConversationsProblemRow(message: problem) { self.problem = nil }
            }
            if listing.isEmpty {
                empty
                    .listRowBackground(Color.clear)
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
            ForEach(shown.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        Button { openRoute(.conversation(row.id)) } label: {
                            ConversationsRowView(row: row, time: ConversationsTime.short(row.updatedAt))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) { archiveButton(row) }
                        .swipeActions(edge: .leading) { if row.chat { pinButton(row) } }
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") { openRoute(.conversation(row.id)) }
                            if row.chat { pinButton(row) }
                            Button("Rename…", systemImage: "pencil") { renaming = row }
                            archiveButton(row)
                            Button("Delete…", systemImage: "trash", role: .destructive) {
                                deleting = ConversationsDeletion(id: row.id, title: row.shownTitle, chat: row.chat)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: projectID == nil ? "Filter by title, agent or “chat”" : "Filter by title or agent")
        .animation(.default, value: listing)
    }

    /// Inside another screen: the rows alone, without a title or scrolling of its own.
    private func inline(_ listing: ConversationsListing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem {
                ConversationsProblemRow(message: problem) { self.problem = nil }
            }
            if listing.isEmpty { empty }
            ForEach(listing.sections) { section in
                Text(section.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.rows) { row in
                    Button { openRoute(.conversation(row.id)) } label: {
                        ConversationsRowView(row: row, time: ConversationsTime.short(row.updatedAt))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if projectID == nil {
            ContentUnavailableView {
                Label("No chats", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("A chat is with pi²'s own assistant, outside any project. Conversations with agents outside projects are listed here too.")
            } actions: {
                Button("New Chat", action: newChat)
                    .buttonStyle(.borderedProminent)
                    .disabled(making)
            }
        } else {
            ContentUnavailableView(
                "No other conversations", systemImage: "bubble.left.and.bubble.right",
                description: Text("The orchestrator's conversation is the project's Chat tab. Conversations with its other agents, and the sub-chats they hand work to, are listed here.")
            )
        }
    }

    private func archiveButton(_ row: ConversationsRow) -> some View {
        Button("Archive", systemImage: "archivebox") { archive(row) }
            .tint(.indigo)
    }

    private func archive(_ row: ConversationsRow) {
        Task { problem = await ConversationsRequests.archive(engine, conversation: row.id).map { "“\(row.shownTitle)” was not archived: \($0)" } }
    }

    private func pinButton(_ row: ConversationsRow) -> some View {
        Button(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin") {
            Task {
                problem = await ConversationsRequests.pin(engine, conversation: row.id, pinned: !row.pinned)
                    .map { "“\(row.shownTitle)” was not \(row.pinned ? "unpinned" : "pinned"): \($0)" }
            }
        }
        .tint(.orange)
    }

    private func rename(_ row: ConversationsRow, _ title: String) {
        Task {
            problem = await ConversationsRequests.rename(engine, conversation: row.id, title: title).map { "“\(row.shownTitle)” was not renamed: \($0)" }
        }
    }

    private func delete(_ deletion: ConversationsDeletion) {
        Task {
            problem = await ConversationsRequests.delete(engine, conversation: deletion.id).map { "“\(deletion.title)” was not deleted: \($0)" }
        }
    }

    private func newChat() {
        making = true
        Task {
            defer { making = false }
            switch await ConversationsRequests.newChat(engine) {
            case .success(let id):
                problem = nil
                openRoute(.conversation(id))
            case .failure(let failure):
                problem = "No chat was made: \(failure.message)"
            }
        }
    }
}
