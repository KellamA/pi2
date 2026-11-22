import SwiftUI

/// The Archive: conversations put out of the sidebar but kept. Each can be read, found by search, restored or deleted.
/// With the Projects preview on, the conversations of deleted projects are listed under their project at the top,
/// each with Restore to a Project… (docs/projects.md, 3.6); the preview off leaves the page as it was.
struct ArchiveView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    /// The restore of one conversation of a deleted project: what its dry run answered, on screen until Restore or Cancel.
    @State private var restore: RestoreShown?
    @State private var working = false
    @State private var error: String?
    private var engine: EngineClient { model.engine }
    private var showsDeletedProjects: Bool { engine.projectsPreview && !engine.projectStore.deletedProjects.isEmpty }

    /// What the filter leaves: every word typed has to be in the title or the agent's name.
    private var rows: [ArchivedConversation] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard !words.isEmpty else { return plain }
        return plain.filter { row in
            let text = "\(row.title) \(row.isChat ? "Chat" : engine.agent(row.agentId)?.name ?? "")"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The Archive's own list: conversations of no project, or of one that was not deleted. A deleted project's are
    /// listed under the project at the top, so they are not shown twice.
    private var plain: [ArchivedConversation] {
        engine.projectsPreview && engine.projectStore.loaded
            ? engine.archived.filter { deletedProject(of: $0.projectId) == nil }
            : engine.archived
    }

    /// The deleted project a conversation belongs to, with the preview on (docs/projects.md, 3.6).
    private func deletedProject(of id: String?) -> ProjectInfo? {
        guard engine.projectsPreview, let id else { return nil }
        return engine.projectStore.deletedProjects.first { $0.id == id }
    }

    var body: some View {
        // With the preview on, a conversation opened here reads in place of the list (OpenConversation.swift, #644).
        if let reading = model.archiveConversation {
            ArchiveReader(model: model, conversation: reading)
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchivedProjects(model: model)
                DeletedProjects(model: model, restore: showRestore, restoreDisabled: working || restore != nil)
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.bad)
                }
                if plain.isEmpty && !showsDeletedProjects {
                    ContentUnavailableView(
                        "Nothing archived",
                        systemImage: "archivebox",
                        description: Text("Archive a conversation to clear it out of the sidebar without losing it. It is kept here, search still finds it, and you can restore it at any time.")
                    )
                    .padding(.top, 40)
                } else if !plain.isEmpty {
                    list
                }
                automatic
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .navigationTitle("Archive")
        .navigationSubtitle(showsDeletedProjects ? "Includes deleted projects" : engine.archived.isEmpty ? "Empty" : engine.archived.count == 1 ? "1 conversation" : "\(engine.archived.count) conversations")
        .sheet(item: $restore) { shown in
            RestoreSheet(shown: shown, working: working) { go(shown) } cancel: { restore = nil }
                .interactiveDismissDisabled(working)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plain.count > 6 || !query.isEmpty {
                TextField("Filter", text: $query, prompt: Text("Filter by title or agent, or “chat”"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter archived conversations")
                    .padding(.bottom, 4)
            }
            if rows.isEmpty {
                Text("No archived conversation matches “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                ArchiveRow(model: model, row: row)
            }
        }
    }

    /// Asks the engine what restoring this conversation of a deleted project would do, and shows it (docs/projects.md, 3.6).
    private func showRestore(_ id: Int, _ title: String) {
        guard !working, restore == nil else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                let found = try CarryOverReport(try await engine.call("projects.restoreConversation", ["id": id, "dryRun": true]))
                guard found.plan != nil else { throw EngineError(message: "This conversation is not of a deleted project.") }
                restore = RestoreShown(conversation: id, title: title, report: found)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Restores on the plan the person was shown. If it changed meanwhile, the engine refuses and sends the new report.
    private func go(_ shown: RestoreShown) {
        guard !working, restore?.id == shown.id, let plan = shown.report.plan else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await engine.call("projects.restoreConversation", ["id": shown.conversation, "plan": plan])
                restore = nil
                let project = try? CarryOverReport(result).projectId
                openInProject(shown.conversation, project: project)
            } catch let refusal as EngineError {
                if let data = refusal.data, let changed = try? CarryOverReport(.object(data)) {
                    restore = RestoreShown(conversation: shown.conversation, title: shown.title, report: changed, changed: true)
                } else {
                    restore = nil
                    error = refusal.localizedDescription
                }
            } catch {
                restore = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// The restore's reply names the actual destination, including when the project was just made.
    private func openInProject(_ id: Int, project: String?) {
        if let project, engine.projectsPreview {
            model.openAgent(id, in: project)
        } else {
            model.openConversation(id)
        }
    }

    /// The setting that archives what has gone unused. It lives here because this is where its results turn up.
    private var automatic: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archive on its own").font(.headline)
            HStack {
                Text("Archive conversations not used for")
                Picker("Archive conversations not used for", selection: Binding(
                    get: { engine.autoArchiveDays ?? 0 },
                    set: { days in engine.perform("settings.setAutoArchive", ["days": days == 0 ? NSNull() : days as Any]) }
                )) {
                    Text("Never").tag(0)
                    ForEach(choices, id: \.self) { days in
                        Text(Self.label(days)).tag(days)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .panel()
            Text("A conversation that is working or waiting for you is left where it is. Archiving never deletes anything.")
                .formFooter()
        }
    }

    /// The usual choices, plus whatever is set if it is not one of them.
    private var choices: [Int] {
        var days = [7, 30, 90, 365]
        if let set = engine.autoArchiveDays, !days.contains(set) { days = (days + [set]).sorted() }
        return days
    }

    private static func label(_ days: Int) -> String {
        switch days {
        case 7: "A week"
        case 30: "A month"
        case 90: "Three months"
        case 365: "A year"
        default: "\(days) days"
        }
    }
}

struct ArchiveRow: View {
    @Bindable var model: AppModel
    let row: ArchivedConversation
    private var engine: EngineClient { model.engine }

    private var title: String { row.title.isEmpty ? (row.isChat ? "New chat" : "New conversation") : row.title }

    private var detail: String {
        var parts: [String] = []
        if row.isChat {
            parts.append("Chat")
        } else if let agent = engine.agent(row.agentId)?.name {
            parts.append(agent)
        }
        if row.parent != nil {
            let parent = (row.parentTitle ?? "").isEmpty ? "New conversation" : row.parentTitle!
            parts.append("sub-chat of “\(parent)”")
        }
        parts.append("archived \(Self.ago(row.archivedAt))")
        if row.subChats > 0 { parts.append(row.subChats == 1 ? "1 sub-chat" : "\(row.subChats) sub-chats") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            if row.isChat {
                // A chat has no agent: the mark chat mode's switch uses, in place of an empty avatar.
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tx2)
                    .frame(width: 22, height: 22)
                    .background(Theme.card, in: .circle)
                    .accessibilityLabel("Chat")
            } else {
                AgentAvatar(agent: engine.agent(row.agentId), size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open") { model.openConversation(row.id) }
                .help("Read it without restoring it")
            Button("Restore") { engine.perform("conversation.unarchive", ["id": row.id]) }
                .help(row.isChat ? "Put it back in chat mode's list, where it can be continued" : "Put it back in the sidebar, where it can be continued")
            Button("Delete", systemImage: "trash") { model.delete(id: row.id, title: row.title) }
                .labelStyle(.iconOnly)
                .help("Delete “\(title)”")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .panel()
        .contextMenu(previewAs: title, String(row.id)) {
            Button("Open") { model.openConversation(row.id) }
            Button("Restore") { engine.perform("conversation.unarchive", ["id": row.id]) }
            Button("Delete", role: .destructive) { model.delete(id: row.id, title: row.title) }
        }
    }

    /// "today", "yesterday", "5 days ago", then the date.
    static func ago(_ milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: .now)).day ?? 0
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2...30: return "\(days) days ago"
        default: return "on \(date.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

/// Deleted projects, at the top of the Archive while the preview is on: each with its conversations, which are shown
/// nowhere else, and each with Restore to a Project… (docs/projects.md, 3.6). The project itself stays deleted.
struct DeletedProjects: View {
    let model: AppModel
    /// Opens the sheet for restoring one conversation: its id and title.
    let restore: (Int, String) -> Void
    let restoreDisabled: Bool
    private var engine: EngineClient { model.engine }

    var body: some View {
        let projects = engine.projectStore.deletedProjects
        if engine.projectsPreview, !projects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deleted projects").font(.headline)
                ForEach(projects) { project in
                    DeletedProject(model: model, project: project, restore: restore, restoreDisabled: restoreDisabled)
                }
                Text("A deleted project is shown nowhere else. Restore one of its conversations into the project of its folder, or delete it; the project itself stays deleted.")
                    .formFooter()
            }
        }
    }
}

/// One deleted project: its row and each of its conversations under it, live and archived alike. Sub-chats come with
/// the conversation they belong to, and a sub-chat archived on its own is reached by opening its conversation.
private struct DeletedProject: View {
    let model: AppModel
    let project: ProjectInfo
    let restore: (Int, String) -> Void
    let restoreDisabled: Bool
    private var engine: EngineClient { model.engine }

    /// Its top-level conversations: from the sidebar's list and the Archive's own, oldest first.
    private var conversations: [DeletedConversationRow] {
        var found: [DeletedConversationRow] = []
        for row in engine.conversations where row.projectId == project.id && row.parent == nil && !row.isChat {
            let subChats = engine.conversations.filter { $0.parent == row.id && !$0.isChat }.count
            found.append(DeletedConversationRow(id: row.id, title: row.title, agentId: row.runsAs ?? row.agentId, subChats: subChats))
        }
        for row in engine.archived where row.projectId == project.id && row.parent == nil && !row.isChat {
            found.append(DeletedConversationRow(id: row.id, title: row.title, agentId: row.agentId, subChats: row.subChats, archivedAt: row.archivedAt))
        }
        return found.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProjectMark(name: project.name, color: engine.agent(project.orchestratorId)?.color, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).lineLimit(1)
                    Text("\(project.folder.map(engine.folderName) ?? "No folder") · deleted \(ArchiveRow.ago(project.deletedAt ?? 0))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(conversations) { conversation in
                HStack(spacing: 10) {
                    AgentAvatar(agent: engine.agent(conversation.agentId), size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title).lineLimit(1)
                        Text(detail(conversation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Open") { model.openConversation(conversation.id) }
                        .help("Read it without restoring it")
                    Button("Restore to a Project…") { restore(conversation.id, conversation.title) }
                        .disabled(restoreDisabled)
                        .help("Put it back into the project of its folder, with its sub-chats")
                    Button("Delete", systemImage: "trash") { model.delete(id: conversation.id, title: conversation.title) }
                        .labelStyle(.iconOnly)
                        .help("Delete “\(conversation.title)”")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.card, in: .rect(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .panel()
    }

    private func detail(_ conversation: DeletedConversationRow) -> String {
        var parts: [String] = []
        if let agent = engine.agent(conversation.agentId)?.name { parts.append(agent) }
        if let archivedAt = conversation.archivedAt { parts.append("archived \(ArchiveRow.ago(archivedAt))") }
        if conversation.subChats > 0 { parts.append(conversation.subChats == 1 ? "1 sub-chat" : "\(conversation.subChats) sub-chats") }
        return parts.isEmpty ? "Not used yet" : parts.joined(separator: " · ")
    }
}

/// One conversation of a deleted project, as the Archive lists it under the project.
private struct DeletedConversationRow: Identifiable {
    let id: Int
    /// The agent it runs as, for its avatar and its line.
    let agentId: String?
    let subChats: Int
    /// Set when the conversation is in the Archive's own list as well; nil while it is live.
    var archivedAt: Double? = nil
    var title: String { stored.isEmpty ? "New conversation" : stored }
    private let stored: String

    init(id: Int, title: String, agentId: String?, subChats: Int, archivedAt: Double? = nil) {
        self.id = id
        self.stored = title
        self.agentId = agentId
        self.subChats = subChats
        self.archivedAt = archivedAt
    }
}

/// What restoring one conversation would do, on screen until the person restores it or cancels (docs/projects.md, 3.6).
struct RestoreShown: Identifiable {
    let conversation: Int
    let title: String
    let report: CarryOverReport
    var changed = false
    var id: String { "\(conversation):\(report.plan ?? "")" }
}

/// The sheet of a restore: where the conversation goes, which agent it runs as, and what is copied, before anything
/// is done (docs/projects.md, 3.6). The project itself is the carrying-over report's one project.
private struct RestoreSheet: View {
    let shown: RestoreShown
    let working: Bool
    let go: () -> Void
    let cancel: () -> Void
    private var report: CarryOverReport { shown.report }
    private var project: CarryOverReport.Project? { report.projects.first }

    /// Every copy that takes something a duplicate made by hand would not (9.5), as the carrying-over sheet lists them.
    private var secretCopies: [CarryOverReport.Project.Copy] {
        (project?.copies ?? []).filter { $0.existing == nil && ($0.allowEverything || !$0.variables.isEmpty) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Restore to a Project?").font(.title2.weight(.semibold))
                if shown.changed {
                    Text("What the restore would do has changed since you looked. This is what it would do now.")
                        .foregroundStyle(Theme.warn)
                }
                Text(intro).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !secretCopies.isEmpty { secrets }
                    if let project {
                        ProjectPlanView(project: project)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Restore", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
    }

    private var intro: String {
        let name = project?.name ?? "a project"
        var line = "“\(shown.title)” is restored into \(name), the project of its folder, with its sub-chats."
        if report.restoresProject == true { line += " That project is archived and will be restored too." }
        if let copy = project?.copies.first(where: { $0.template == report.rootAgent }) {
            line += copy.existing == nil
                ? " It runs as a new copy of its agent, \(copy.name)."
                : " It runs as the project’s copy of its agent, \(copy.name)."
        }
        line += " Its folder, worktree and conversation-specific permissions do not change."
        return line
    }

    /// The copies that take Allow everything or variables' values, by name, before anything is done (9.5).
    private var secrets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("These copies take more than a duplicate would", systemImage: "exclamationmark.shield").font(.headline).foregroundStyle(Theme.bad)
            ForEach(secretCopies, id: \.template) { copy in
                Text("\(copy.name): \(CarryOverSheet.takes(copy))").fixedSize(horizontal: false, vertical: true)
            }
            Text("Each takes them from the agent it is a copy of, so the conversation goes on as before.").formFooter()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}
