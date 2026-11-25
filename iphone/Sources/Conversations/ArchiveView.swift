import EngineKit
import PiModels
import SwiftUI

/// The archive, as the Mac has it, from the projects list (docs/design/iphone.md, "Every screen and function of the Mac
/// app": Archive, as it is). Archived projects with Restore; deleted projects with their conversations, each with Restore
/// to a Project…; the archived conversations, each read on its own screen without restoring it (`.conversation(id)`),
/// restored or deleted; and the setting that archives what has gone unused, which lives here on the Mac too.
struct ArchiveView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var query = ""
    @State private var problem: String?
    @State private var renaming: ConversationsRow?
    @State private var deleting: ConversationsDeletion?
    /// The restore of one conversation of a deleted project: what its dry run answered, until Restore or Cancel.
    @State private var restore: ArchiveRestoreShown?
    @State private var working = false

    init() {}

    private var engine: EngineSession<MessageField> { session.engine }

    private var listing: ArchiveListing {
        #if DEBUG
        if let sample = ConversationsSample.current?.archive { return sample }
        #endif
        return .read(archived: engine.archived, conversations: engine.conversations, projects: engine.projects, agents: engine.allAgents,
                     autoArchiveDays: engine.autoArchiveDays)
    }

    private var isSample: Bool {
        #if DEBUG
        return ConversationsSample.current?.archive != nil
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if !isSample, engine.status != .connected || !engine.hasLoadedLibrary {
                ConversationsWaiting()
            } else {
                list(listing)
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .conversationsEditing(renaming: $renaming, deleting: $deleting, rename: { _, _ in }, delete: delete)
        #if DEBUG
        .task(id: engine.hasLoadedLibrary) {
            guard engine.hasLoadedLibrary || isSample else { return }
            if await ConversationsSample.take("restore", in: session), let first = listing.conversations.first { unarchive(first) }
            if await ConversationsSample.take("restore-project", in: session), let first = listing.deletedProjects.first?.conversations.first { showRestore(first) }
            if await ConversationsSample.take("unarchive-project", in: session), let first = listing.archivedProjects.first { unarchiveProject(first) }
            if await ConversationsSample.take("restore-project-go", in: session), let first = listing.deletedProjects.first?.conversations.first {
                // The dry run's sheet, then its Restore.
                showRestore(first)
                for _ in 0..<50 where restore == nil { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                if let shown = restore { go(shown) }
            }
        }
        #endif
        .sheet(item: $restore) { shown in
            ArchiveRestoreSheet(shown: shown, working: working) { go(shown) } cancel: { restore = nil }
                .interactiveDismissDisabled(working)
        }
    }

    private func list(_ listing: ArchiveListing) -> some View {
        let rows = listing.filtered(query)
        return List {
            if isSample {
                ConversationsSampleNote()
            }
            if let problem {
                ConversationsProblemRow(message: problem) { self.problem = nil }
            }
            if listing.isEmpty {
                ContentUnavailableView(
                    "Nothing archived", systemImage: "archivebox",
                    description: Text("Archive a conversation to clear it out of the list without losing it. It is kept here, search still finds it, and you can restore it at any time.")
                )
                .listRowBackground(Color.clear)
            }
            if !listing.archivedProjects.isEmpty, query.isEmpty {
                Section {
                    ForEach(listing.archivedProjects) { project in
                        archivedProject(project)
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("An archived project keeps its conversations, which stay in the list below as they were.")
                }
            }
            if query.isEmpty {
                ForEach(listing.deletedProjects) { project in
                    deletedProject(project)
                }
            }
            if !listing.conversations.isEmpty {
                Section("Conversations") {
                    if rows.isEmpty {
                        Text("No archived conversation matches “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        archivedConversation(row)
                    }
                }
            }
            if query.isEmpty {
                automatic(listing.autoArchiveDays)
            }
        }
        .searchable(text: $query, prompt: "Filter by title, agent or “chat”")
    }

    private func archivedProject(_ project: ArchiveListing.Project) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                projectLabel(project)
                restoreProjectButton(project)
            }
            VStack(alignment: .leading, spacing: 8) {
                projectLabel(project)
                restoreProjectButton(project)
            }
        }
    }

    private func projectLabel(_ project: ArchiveListing.Project) -> some View {
        ConversationsRowStack {
            AgentMark(name: project.name, color: project.color)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(project.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func restoreProjectButton(_ project: ArchiveListing.Project) -> some View {
        Button("Restore") { unarchiveProject(project) }
            .buttonStyle(.bordered)
            .accessibilityLabel("Restore \(project.name)")
    }

    private func unarchiveProject(_ project: ArchiveListing.Project) {
        Task { problem = await ConversationsRequests.unarchiveProject(engine, project: project.id).map { "\(project.name) was not restored: \($0)" } }
    }

    private func deletedProject(_ project: ArchiveListing.Project) -> some View {
        Section {
            projectLabel(project)
            ForEach(project.conversations) { conversation in
                Button { openRoute(.conversation(conversation.id)) } label: {
                    ArchiveConversationLabel(conversation: conversation)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) { deleteButton(conversation) }
                .swipeActions(edge: .leading) {
                    Button("Restore to a Project…", systemImage: "arrow.uturn.backward") { showRestore(conversation) }
                        .tint(Color.pi2Accent)
                }
                .contextMenu {
                    Button("Open", systemImage: "arrow.up.forward.app") { openRoute(.conversation(conversation.id)) }
                    Button("Restore to a Project…", systemImage: "arrow.uturn.backward") { showRestore(conversation) }
                        .disabled(working || restore != nil)
                    deleteButton(conversation)
                }
            }
        } header: {
            Text("Deleted project")
        } footer: {
            Text("A deleted project is shown nowhere else. Restore one of its conversations into the project of its folder, or delete it; the project itself stays deleted.")
        }
    }

    private func archivedConversation(_ conversation: ArchiveListing.Conversation) -> some View {
        Button { openRoute(.conversation(conversation.id)) } label: {
            ArchiveConversationLabel(conversation: conversation)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) { deleteButton(conversation) }
        .swipeActions(edge: .leading) { restoreButton(conversation) }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { openRoute(.conversation(conversation.id)) }
            restoreButton(conversation)
            deleteButton(conversation)
        }
        .accessibilityHint("Opens it to read without restoring it")
    }

    private func restoreButton(_ conversation: ArchiveListing.Conversation) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") { unarchive(conversation) }
            .tint(Color.pi2Accent)
    }

    private func unarchive(_ conversation: ArchiveListing.Conversation) {
        Task {
            problem = await ConversationsRequests.unarchive(engine, conversation: conversation.id).map { "“\(conversation.shownTitle)” was not restored: \($0)" }
        }
    }

    private func deleteButton(_ conversation: ArchiveListing.Conversation) -> some View {
        Button("Delete…", systemImage: "trash", role: .destructive) {
            deleting = ConversationsDeletion(id: conversation.id, title: conversation.shownTitle, chat: conversation.chat)
        }
    }

    /// The setting that archives what has gone unused. It lives here because this is where its results turn up.
    private func automatic(_ days: Int?) -> some View {
        Section {
            Picker("Archive conversations not used for", selection: Binding(
                get: { days ?? 0 },
                set: { chosen in
                    Task {
                        problem = await ConversationsRequests.setAutoArchive(engine, days: chosen == 0 ? nil : chosen)
                            .map { "The setting was not changed: \($0)" }
                    }
                }
            )) {
                Text("Never").tag(0)
                ForEach(ArchiveListing.autoArchiveChoices(days), id: \.self) { choice in
                    Text(ArchiveListing.autoArchiveLabel(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Archive on its own")
        } footer: {
            Text("A conversation that is working or waiting for you is left where it is. Archiving never deletes anything.")
        }
    }

    private func delete(_ deletion: ConversationsDeletion) {
        Task {
            problem = await ConversationsRequests.delete(engine, conversation: deletion.id).map { "“\(deletion.title)” was not deleted: \($0)" }
        }
    }

    /// Asks the engine what restoring this conversation of a deleted project would do, and shows it.
    private func showRestore(_ conversation: ArchiveListing.Conversation) {
        guard !working, restore == nil else { return }
        problem = nil
        working = true
        Task {
            defer { working = false }
            switch await ConversationsRequests.restorePlan(engine, conversation: conversation.id) {
            case .success(let report):
                restore = ArchiveRestoreShown(conversation: conversation.id, title: conversation.shownTitle, report: report)
            case .failure(let failure):
                problem = "“\(conversation.shownTitle)” cannot be restored now: \(failure.message)"
            }
        }
    }

    /// Restores on the plan the person was shown; if it changed meanwhile, shows the new one.
    private func go(_ shown: ArchiveRestoreShown) {
        guard !working, restore?.id == shown.id, let plan = shown.report.plan else { return }
        working = true
        Task {
            defer { working = false }
            switch await ConversationsRequests.restore(engine, conversation: shown.conversation, plan: plan) {
            case .restored:
                restore = nil
                openRoute(.conversation(shown.conversation))
            case .changed(let report):
                restore = ArchiveRestoreShown(conversation: shown.conversation, title: shown.title, report: report, changed: true)
            case .failed(let message):
                restore = nil
                problem = "“\(shown.title)” was not restored: \(message)"
            }
        }
    }
}

/// An archived conversation's mark, title and line.
private struct ArchiveConversationLabel: View {
    let conversation: ArchiveListing.Conversation
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ConversationsRowStack {
            ConversationsMark(chat: conversation.chat, name: conversation.agentName, color: conversation.agentColor)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.shownTitle)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(conversation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(conversation.shownTitle), \(conversation.detail)")
        .accessibilityAddTraits(.isButton)
    }
}
