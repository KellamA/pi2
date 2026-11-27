import EngineKit
import Foundation
import Observation
import PiModels

/// A command an agent left running in the background, as the list shows it (the Mac's Activity page and the strip above a
/// conversation's field: app/Sources/pi2/ActivityPage.swift, BackgroundViews.swift).
struct BackgroundCommandsRow: Identifiable, Equatable {
    /// "bg-3".
    let id: String
    let command: String
    /// The conversation it was started in, and the one in the list it belongs to (they differ for a sub-chat's command).
    let conversationId: Int
    let rootConversationId: Int
    /// "Check the sample build · Atlas", or "sub-chat “Read the notes” · Scout".
    let source: String
    /// The last component of the folder it was started in.
    let folder: String
    /// Milliseconds since 1970.
    let startedAt: Double

    /// The command on one line, for a title or a row (the Mac's `oneLine`).
    var oneLine: String { BackgroundCommandsRow.oneLine(command) }

    static func oneLine(_ command: String) -> String {
        command.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func read(_ commands: [BackgroundCommand], conversations: [ConversationSummary], agents: [AgentProfile]) -> [BackgroundCommandsRow] {
        commands.map { command in
            BackgroundCommandsRow(id: command.id, command: command.command, conversationId: command.conversationId,
                                  rootConversationId: command.rootConversationId,
                                  source: source(command.conversationId, conversations: conversations, agents: agents),
                                  folder: (command.cwd as NSString).lastPathComponent, startedAt: command.startedAt)
        }
    }

    /// Whose it is, as the Mac's output window names the conversation that started it.
    static func source(_ id: Int, conversations: [ConversationSummary], agents: [AgentProfile]) -> String {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return "Conversation \(id)" }
        let title = conversation.title.isEmpty ? (conversation.isChat ? "New chat" : "New conversation") : conversation.title
        let agent = agents.first { $0.id == (conversation.runsAs ?? conversation.agentId) }?.name
        let named = conversation.parent == nil ? title : "sub-chat “\(title)”"
        return [named, agent].compactMap(\.self).joined(separator: " · ")
    }
}

/// "0:42", "12:05", "2h 5m": how long since `start` (milliseconds since 1970), as the Mac's `runningTime` says it.
enum BackgroundCommandsClock {
    static func text(since start: Double, until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - start / 1000))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The same, as VoiceOver reads it: "4 minutes 7 seconds".
    static func spoken(since start: Double, until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - start / 1000))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? ""
    }
}

/// The phone's name for EngineKit's `BackgroundOutputFollower`, the one loop the Mac's output window and the phone's
/// command's output screen follow a background command's output with (the Mac's `BackgroundOutputFeed`): what it asks,
/// how it waits and how it joins the parts are told there.
typealias BackgroundCommandsFeed = BackgroundOutputFollower

/// How the follower asks this engine, and hears whether it is connected; and what the page says of what is not shown.
extension BackgroundOutputFollower {
    /// Follows the command until it ends or the task is cancelled (the page went).
    func follow(_ engine: ConversationsRequests.Engine) async {
        await follow(
            { from, wait in try await ConversationsRequests.output(engine, command: self.id, from: from, wait: wait) },
            connected: { engine.status == .connected })
    }

    /// What the output area does not show, said above it.
    var note: String? {
        guard let latest else { return nil }
        if !latest.kept { return "Its output was in pi²'s engine when it stopped, and was not kept." }
        if notShown > 0 {
            return "The first \(notShown.formatted()) characters it printed are not shown: pi² keeps only the last 128 KB of a command's output."
        }
        return nil
    }
}
