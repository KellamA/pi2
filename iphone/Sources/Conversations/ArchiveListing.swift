import Foundation
import PiModels

/// What the Archive shows, read as the Mac's Archive reads it (app/Sources/pi2/ArchiveViews.swift, and
/// `ArchivedProjects` in ProjectsSidebar.swift): archived projects, each with Restore; deleted projects, each with its
/// conversations, which are shown nowhere else, each with Restore to a Project…; and the archived conversations of no
/// project, or of one not deleted, newest first as the engine sends them.
struct ArchiveListing: Equatable {
    struct Project: Identifiable, Equatable {
        let id: String
        let name: String
        let color: String?
        /// "demo-project · archived 3 days ago".
        let detail: String
        /// For a deleted project: its top-level conversations, live and archived alike, oldest first.
        var conversations: [Conversation] = []
    }

    struct Conversation: Identifiable, Equatable {
        let id: Int
        let title: String
        let chat: Bool
        let agentName: String?
        let agentColor: String?
        let detail: String

        var row: ConversationsRow {
            ConversationsRow(id: id, title: title, agentName: agentName, agentColor: agentColor, chat: chat, updatedAt: 0)
        }

        var shownTitle: String { row.shownTitle }
    }

    var archivedProjects: [Project]
    var deletedProjects: [Project]
    var conversations: [Conversation]
    /// After how many unused days a conversation is archived on its own; nil for never.
    var autoArchiveDays: Int?

    var isEmpty: Bool { archivedProjects.isEmpty && deletedProjects.isEmpty && conversations.isEmpty }

    static func read(archived: [ArchivedConversation], conversations: [ConversationSummary], projects: [ProjectRow], agents: [AgentProfile],
                     autoArchiveDays: Int?, now: Date = .now) -> ArchiveListing {
        func agent(_ id: String?) -> AgentProfile? { agents.first { $0.id == id } }
        func folderName(_ path: String?) -> String {
            guard let path else { return "No folder" }
            return (path as NSString).lastPathComponent
        }
        let deleted = projects.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) }
        let deletedIDs = Set(deleted.map(\.id))

        let archivedProjects = projects.filter { $0.archivedAt != nil && $0.deletedAt == nil }
            .sorted { ($0.archivedAt ?? 0) > ($1.archivedAt ?? 0) }
            .map { project in
                Project(id: project.id, name: project.name, color: agent(project.orchestratorId)?.color,
                        detail: "\(folderName(project.folder)) · archived \(ConversationsTime.ago(project.archivedAt ?? 0, now: now))")
            }

        let deletedProjects = deleted.map { project in
            var rows: [(id: Int, conversation: Conversation)] = []
            for row in conversations where row.projectId == project.id && row.parent == nil && !row.isChat {
                let subChats = conversations.filter { $0.parent == row.id && !$0.isChat }.count
                let runsAs = agent(row.runsAs ?? row.agentId)
                rows.append((row.id, Conversation(id: row.id, title: row.title, chat: false, agentName: runsAs?.name, agentColor: runsAs?.color,
                                                  detail: detail(agent: runsAs?.name, archivedAt: nil, subChats: subChats, now: now))))
            }
            for row in archived where row.projectId == project.id && row.parent == nil && !row.isChat {
                let runsAs = agent(row.agentId)
                rows.append((row.id, Conversation(id: row.id, title: row.title, chat: false, agentName: runsAs?.name, agentColor: runsAs?.color,
                                                  detail: detail(agent: runsAs?.name, archivedAt: row.archivedAt, subChats: row.subChats, now: now))))
            }
            return Project(id: project.id, name: project.name, color: agent(project.orchestratorId)?.color,
                           detail: "\(folderName(project.folder)) · deleted \(ConversationsTime.ago(project.deletedAt ?? 0, now: now))",
                           conversations: rows.sorted { $0.id < $1.id }.map(\.conversation))
        }

        let plain = archived.filter { row in row.projectId.map { !deletedIDs.contains($0) } ?? true }.map { row in
            let runsAs = row.isChat ? nil : agent(row.agentId)
            var parts: [String] = []
            if row.isChat { parts.append("Chat") } else if let name = runsAs?.name { parts.append(name) }
            if row.parent != nil {
                let parent = (row.parentTitle ?? "").isEmpty ? "New conversation" : row.parentTitle!
                parts.append("sub-chat of “\(parent)”")
            }
            parts.append("archived \(ConversationsTime.ago(row.archivedAt, now: now))")
            if row.subChats > 0 { parts.append(row.subChats == 1 ? "1 sub-chat" : "\(row.subChats) sub-chats") }
            return Conversation(id: row.id, title: row.title, chat: row.isChat, agentName: runsAs?.name, agentColor: runsAs?.color,
                                detail: parts.joined(separator: " · "))
        }
        return ArchiveListing(archivedProjects: archivedProjects, deletedProjects: deletedProjects, conversations: plain, autoArchiveDays: autoArchiveDays)
    }

    /// The archived conversations whose title, agent or "Chat" has every word typed, as the Mac's Archive filters.
    func filtered(_ query: String) -> [Conversation] {
        let words = ConversationsFilter.words(query)
        guard !words.isEmpty else { return conversations }
        return conversations.filter { ConversationsFilter.matches(words, "\($0.title) \($0.chat ? "Chat" : $0.agentName ?? "")") }
    }

    private static func detail(agent: String?, archivedAt: Double?, subChats: Int, now: Date) -> String {
        var parts: [String] = []
        if let agent { parts.append(agent) }
        if let archivedAt { parts.append("archived \(ConversationsTime.ago(archivedAt, now: now))") }
        if subChats > 0 { parts.append(subChats == 1 ? "1 sub-chat" : "\(subChats) sub-chats") }
        return parts.isEmpty ? "Not used yet" : parts.joined(separator: " · ")
    }

    /// The choices for archiving on its own, as the Mac's Archive offers them: never, a week, a month, three months, a
    /// year, and whatever is set if it is not one of them.
    static func autoArchiveChoices(_ set: Int?) -> [Int] {
        var days = [7, 30, 90, 365]
        if let set, set > 0, !days.contains(set) { days = (days + [set]).sorted() }
        return days
    }

    static func autoArchiveLabel(_ days: Int) -> String {
        switch days {
        case 7: "A week"
        case 30: "A month"
        case 90: "Three months"
        case 365: "A year"
        default: "\(days) days"
        }
    }
}
