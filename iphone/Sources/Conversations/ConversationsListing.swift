import EngineKit
import Foundation
import PiModels

// What the conversations' lists read of the engine's state (docs/design/iphone.md, "Every screen and function of the Mac
// app": conversations outside projects, sub-chats, chat mode and the Archive): the same readings the Mac's sidebar, chat
// mode and Archive make (app/Sources/pi2/Projects.swift, ChatMode.swift, ArchiveViews.swift), from `session.engine`.
// Nothing here is kept: each is read again as the engine's events change it. Each reading takes the engine's arrays, so
// that a test can give it the engine's own types directly.

/// One conversation as a list shows it: its title, whose it is, and how it stands.
struct ConversationsRow: Identifiable, Equatable {
    let id: Int
    /// The title the engine gave it; empty for one not named yet.
    let title: String
    /// The agent it runs as, by name and colour; nil for a chat, or an agent the engine does not list.
    let agentName: String?
    let agentColor: String?
    let chat: Bool
    let pinned: Bool
    /// Its agent is answering now.
    let busy: Bool
    /// Milliseconds since 1970.
    let updatedAt: Double
    /// For a sub-chat: the title of the conversation that opened it.
    var subChatOf: String? = nil

    /// The title, or what the Mac calls one not named yet.
    var shownTitle: String { title.isEmpty ? (chat ? "New chat" : "New conversation") : title }

    /// Who it is with, and how it stands, as the line under its title says it.
    var detail: String {
        var parts: [String] = []
        if chat { parts.append("Chat") } else if let agentName { parts.append(agentName) }
        if let subChatOf { parts.append("sub-chat of “\(subChatOf)”") }
        if busy { parts.append("working") }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the row, as one sentence.
    var spokenLabel: String {
        [shownTitle, detail.isEmpty ? nil : detail, pinned ? "pinned" : nil].compactMap(\.self).joined(separator: ", ")
    }

    init(id: Int, title: String, agentName: String?, agentColor: String?, chat: Bool = false, pinned: Bool = false, busy: Bool = false,
         updatedAt: Double, subChatOf: String? = nil) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.agentColor = agentColor
        self.chat = chat
        self.pinned = pinned
        self.busy = busy
        self.updatedAt = updatedAt
        self.subChatOf = subChatOf
    }

    init(_ conversation: ConversationSummary, agents: [AgentProfile], parent: ConversationSummary? = nil) {
        let agent = agents.first { $0.id == (conversation.runsAs ?? conversation.agentId) } ?? agents.first { $0.id == conversation.agentId }
        id = conversation.id
        title = conversation.title
        chat = conversation.isChat
        agentName = chat ? nil : agent?.name
        agentColor = chat ? nil : agent?.color
        pinned = conversation.isPinned
        busy = conversation.busy
        updatedAt = conversation.updatedAt
        if conversation.parent != nil {
            let title = parent?.title ?? ""
            subChatOf = title.isEmpty ? (parent?.isChat == true ? "New chat" : "New conversation") : title
        }
    }
}

/// A list of conversations in sections, as one of the screens draws it.
struct ConversationsListing: Equatable {
    struct Section: Identifiable, Equatable {
        /// "agents", "subChats", "earlier", "chats", "outside".
        let id: String
        let title: String
        let rows: [ConversationsRow]
    }

    var sections: [Section]

    var isEmpty: Bool { sections.allSatisfy(\.rows.isEmpty) }
    var count: Int { sections.reduce(0) { $0 + $1.rows.count } }

    /// A project's conversations other than the one with its orchestrator now: its agents' (newest first, as the Mac's
    /// sidebar lists a project's other conversations), the sub-chats its agents handed work to, and its earlier
    /// conversations with an orchestrator (Start fresh, Make Orchestrator).
    static func project(_ projectID: String, conversations: [ConversationSummary], agents: [AgentProfile]) -> ConversationsListing {
        let mine = conversations.filter { $0.projectId == projectID && !$0.isChat }
        let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agentsRows = mine.filter { $0.parent == nil && $0.orchestrator == nil }
        let subChats = mine.filter { $0.parent != nil }
        let earlier = mine.filter { $0.parent == nil && $0.orchestrator == "earlier" }
        return ConversationsListing(sections: [
            Section(id: "agents", title: "Agents", rows: newestFirst(agentsRows).map { ConversationsRow($0, agents: agents) }),
            Section(id: "subChats", title: "Sub-chats", rows: newestFirst(subChats).map { ConversationsRow($0, agents: agents, parent: $0.parent.flatMap { byID[$0] }) }),
            Section(id: "earlier", title: "Earlier with an orchestrator", rows: newestFirst(earlier).map { ConversationsRow($0, agents: agents) }),
        ].filter { !$0.rows.isEmpty })
    }

    /// The conversations outside projects: chats (pinned first, as chat mode lists them, then newest first), agents'
    /// conversations that belong to no project, and their sub-chats.
    static func outside(conversations: [ConversationSummary], agents: [AgentProfile]) -> ConversationsListing {
        let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chats = conversations.filter { $0.isChat && $0.parent == nil }
            .sorted { ($0.isPinned ? 1 : 0, $0.updatedAt, $0.id) > ($1.isPinned ? 1 : 0, $1.updatedAt, $1.id) }
        let outside = conversations.filter { $0.projectId == nil && !$0.isChat }
        return ConversationsListing(sections: [
            Section(id: "chats", title: "Chats", rows: chats.map { ConversationsRow($0, agents: agents) }),
            Section(id: "outside", title: "Outside projects", rows: newestFirst(outside.filter { $0.parent == nil }).map { ConversationsRow($0, agents: agents) }),
            Section(id: "subChats", title: "Sub-chats", rows: newestFirst(outside.filter { $0.parent != nil }).map { ConversationsRow($0, agents: agents, parent: $0.parent.flatMap { byID[$0] }) }),
        ].filter { !$0.rows.isEmpty })
    }

    /// What the search field leaves: every word typed has to be in the title, the agent's name, or "chat" for a chat, as
    /// the Mac's Archive filters.
    func filtered(_ query: String) -> ConversationsListing {
        let words = ConversationsFilter.words(query)
        guard !words.isEmpty else { return self }
        return ConversationsListing(sections: sections.map { section in
            Section(id: section.id, title: section.title, rows: section.rows.filter {
                ConversationsFilter.matches(words, "\($0.title) \($0.chat ? "Chat" : $0.agentName ?? "")")
            })
        }.filter { !$0.rows.isEmpty })
    }

    private static func newestFirst(_ rows: [ConversationSummary]) -> [ConversationSummary] {
        rows.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}

/// The words of a search field, and whether a text has every one of them, as the Mac's Archive filters.
enum ConversationsFilter {
    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ words: [String], _ text: String) -> Bool {
        words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// When something happened, as a list's row says it: the time today, "Yesterday", the weekday within the week, then the
/// date (the projects list's drawing: "Tue", "Mon").
enum ConversationsTime {
    static func short(_ milliseconds: Double, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        switch days {
        case ...0:
            return date.formatted(style)
        case 1:
            return "Yesterday"
        case 2...6:
            var weekday = Date.FormatStyle().weekday(.abbreviated)
            weekday.timeZone = calendar.timeZone
            return date.formatted(weekday)
        default:
            var day = Date.FormatStyle().day().month(.abbreviated)
            day.timeZone = calendar.timeZone
            return date.formatted(day)
        }
    }

    /// "today", "yesterday", "5 days ago", then the date: when something was archived or deleted, as the Mac's Archive
    /// says it (`ArchiveRow.ago`).
    static func ago(_ milliseconds: Double, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2...30: return "\(days) days ago"
        default:
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.timeZone = calendar.timeZone
            return "on \(date.formatted(style))"
        }
    }
}

extension EngineSession {
    /// A project the phone can show by its id, deleted ones included (the Archive lists a deleted project's conversations).
    func conversationsProject(_ id: String) -> ProjectRow? {
        projects.first { $0.id == id }
    }
}
