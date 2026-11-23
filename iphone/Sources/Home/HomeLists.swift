
import EngineKit
import Foundation
import PiModels

/// What the projects list shows of one project (docs/design/iphone.md, "The projects list"): its mark, its badge as the
/// Mac's sidebar has it (what needs the person, else how many agents work, else idle), the orchestrator's last words and
/// when they were said. Worked out from what the engine sent, as the Mac's `ProjectsStore` works out its rows.
struct HomeProject: Equatable, Identifiable {
    let id: String
    let name: String
    /// The orchestrator's colour, by name, for the project's mark.
    let color: String?
    /// How many things wait for the person in this project.
    let needs: Int
    /// How many of its runs are working (not waiting for the person).
    let working: Int
    /// The orchestrator's own conversation runs: working, or waiting for the person or a limit.
    let orchestratorWorking: Bool
    let orchestratorWaiting: Bool
    let orchestratorAtLimit: Bool
    /// The last line of the orchestrator's last finished answer, and when it came.
    let lastWords: String?
    let lastWordsAt: Date?
    /// The orchestrator's conversation, for stopping it.
    let conversation: Int?
    let folderMissing: Bool

    /// What the badge says.
    enum Badge: Equatable {
        case needs(Int)
        case working(Int)
        case idle
    }

    var badge: Badge {
        if needs > 0 { return .needs(needs) }
        if working > 0 { return .working(working) }
        return .idle
    }
}

/// The lists the projects list is made of, worked out from the engine's state. Each is a function of what the engine
/// sent and nothing else, so that the tests can check them against the recorded session.
@MainActor
enum HomeLists {
    /// The projects the Mac's sidebar lists, in the engine's order: neither archived nor deleted.
    static func projects(_ engine: EngineSession<MessageField>) -> [HomeProject] {
        projects(engine.projects, needs: engine.needs, activity: engine.activity, agents: engine.allAgents)
    }

    static func projects(_ rows: [ProjectRow], needs: [NeedItem], activity: [ActivityRun], agents: [AgentProfile]) -> [HomeProject] {
        let projectRuns = activity.filter { $0.projectId != nil && $0.chat != true }
        return rows.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map { row in
            let mine = projectRuns.filter { $0.projectId == row.id }
            let orchestratorRun = row.conversation.flatMap { conversation in mine.first { $0.conversationId == conversation } }
            return HomeProject(
                id: row.id,
                name: row.name,
                color: agents.first { $0.id == row.orchestratorId }?.color,
                needs: needs.count(where: { $0.projectId == row.id }),
                working: mine.count(where: { $0.status != "waiting" }),
                orchestratorWorking: orchestratorRun != nil,
                orchestratorWaiting: orchestratorRun?.status == "waiting",
                orchestratorAtLimit: orchestratorRun?.limit != nil,
                lastWords: row.lastWords?.text,
                lastWordsAt: row.lastWords.map { Date(timeIntervalSince1970: $0.at / 1000) },
                conversation: row.conversation,
                folderMissing: row.folderMissing == true
            )
        }
    }

    /// Chats with pi²'s own assistant, as chat mode lists them on the Mac: pinned ones first, then the most recently used.
    static func chats(_ conversations: [ConversationSummary]) -> [ConversationSummary] {
        let chats = conversations.filter(\.isChat).sorted { $0.updatedAt > $1.updatedAt }
        return chats.filter(\.isPinned) + chats.filter { !$0.isPinned }
    }

    /// How many chats are listed before "Show all": the pinned ones, and at least this many.
    static let chatsShown = 5

    /// A chat waiting to be written in: untitled (a chat is titled after its first message) and not answering. New Chat
    /// opens it rather than making another, as on the Mac (`AppModel.newChat`).
    static func emptyChat(_ conversations: [ConversationSummary]) -> ConversationSummary? {
        chats(conversations).first { $0.title.isEmpty && !$0.busy }
    }

    /// What the Archive holds: conversations and projects put away.
    static func archivedCount(_ engine: EngineSession<MessageField>) -> Int {
        engine.archived.count + engine.projects.count(where: { $0.archivedAt != nil && $0.deletedAt == nil })
    }
}

/// Dates as a list of conversations shows them: the time today, "Yesterday", the weekday within a week, else the date.
enum HomeTime {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week, date < now {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// When the Mac was last heard from: the time today, else the day and the time.
    static func lastSeen(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return calendar.isDate(date, inSameDayAs: now) ? time : "\(short(date, now: now, calendar: calendar)) \(time)"
    }

    /// Milliseconds since 1970, as the engine sends times.
    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
