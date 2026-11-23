import Foundation
import PiModels

/// Where a share can go: a project's orchestrator, an agent's conversation in a project, or a chat, by its conversation.
struct ShareDestination: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case orchestrator
        case agent
        case chat
    }

    let conversation: Int
    let kind: Kind
    /// The conversation's title; for an orchestrator, the project's name.
    let title: String
    /// The project's name, for an orchestrator or an agent's conversation.
    let project: String?

    var id: Int { conversation }

    /// How the page and a list name it.
    var label: String {
        switch kind {
        case .orchestrator: "\(title)’s orchestrator"
        case .agent, .chat: title.isEmpty ? "Untitled conversation" : title
        }
    }

    /// The line under it.
    var detail: String {
        switch kind {
        case .orchestrator: "Orchestrator"
        case .agent: project.map { "Agent in \($0)" } ?? "Agent"
        case .chat: "Chat"
        }
    }
}

/// The list the share extension offers, which the app writes for it into the shared folder (`ShareDrop`) from what its
/// Mac last sent: the extension cannot reach the Mac, nor read the phone's store, which is sealed with a key only a
/// session Face ID opened can read (docs/iphone-app.md, "The extensions").
///
/// It holds names only (projects' and conversations'), never what was said in them.
struct ShareDestinations: Codable, Equatable, Sendable {
    let writtenAt: Date
    /// The paired Mac's name, when known.
    let macName: String?
    let destinations: [ShareDestination]

    /// A list older than this is not offered: the phone's store wipes what has gone seven days without the Mac
    /// (`PhoneStore.keptWithoutMac`), and the list goes with it.
    static let keptWithoutMac: TimeInterval = 7 * 86_400
    /// How many of a project's agents' conversations, and of the chats, are offered: the most recent.
    static let perProject = 5
    static let chats = 5

    func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(writtenAt) <= Self.keptWithoutMac
    }

    /// The list from the Mac's projects and conversations, as the session's client holds them: each project's
    /// orchestrator, then the project's agents' own conversations, most recent first, then the chats. Archived and
    /// deleted projects, projects whose orchestrator has not started, and sub-chats (an orchestrator's to hand out, not
    /// the person's to message) are left out.
    static func make(projects: [ProjectRow], conversations: [ConversationSummary], macName: String?, at date: Date) -> ShareDestinations {
        var list: [ShareDestination] = []
        let recent = conversations.filter { $0.parent == nil }.sorted { $0.updatedAt > $1.updatedAt }
        for project in projects where project.archivedAt == nil && project.deletedAt == nil {
            if let conversation = project.conversation {
                list.append(ShareDestination(conversation: conversation, kind: .orchestrator, title: project.name, project: project.name))
            }
            let agents = recent.filter { $0.projectId == project.id && $0.orchestrator == nil && $0.chat != true && $0.id != project.conversation }
            list += agents.prefix(perProject).map {
                ShareDestination(conversation: $0.id, kind: .agent, title: $0.title, project: project.name)
            }
        }
        list += recent.filter { $0.chat == true && $0.projectId == nil }.prefix(chats).map {
            ShareDestination(conversation: $0.id, kind: .chat, title: $0.title, project: nil)
        }
        return ShareDestinations(writtenAt: date, macName: macName, destinations: list)
    }
}
