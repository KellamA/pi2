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

/// A command's output, kept up to date from the engine while its page shows, as the Mac's output window keeps it
/// (`BackgroundOutputFeed`): it asks for the output from where the last answer ended, and the engine holds the request
/// until there is more or the command ends (`background.output` with `wait`). Between answers it waits half a second.
/// Reading here does not change what counts as read for the agent.
@MainActor
@Observable
final class BackgroundCommandsFeed {
    /// The engine keeps the last 128 KB of a command's output; the page keeps up to twice that before cutting it back.
    static let keep = 128 * 1024

    let id: String
    /// The engine's last answer: how the command stands.
    private(set) var latest: BackgroundOutput?
    /// Why the output cannot be shown, from the engine.
    private(set) var problem: String?
    /// The output shown: plain text, exactly as the command printed it.
    private(set) var text = ""
    /// How many characters it printed before `text` that are not shown, because they were not kept.
    private(set) var notShown = 0
    /// Goes up whenever `text` is replaced rather than added to, so the view sets it whole.
    private(set) var replaced = 0

    init(id: String) {
        self.id = id
    }

    /// A feed that shows `output` as an answer, for a test or a debug sample: nothing is asked of the engine.
    init(id: String, showing output: BackgroundOutput) {
        self.id = id
        take(output, askedFrom: 0)
    }

    /// Follows the command until it ends or the task is cancelled (the page went).
    func follow(_ engine: ConversationsRequests.Engine) async {
        var from = 0
        var first = true
        while !Task.isCancelled {
            do {
                // The first answer comes at once, so the page can say how the command stands before it prints.
                let answer = try await ConversationsRequests.output(engine, command: id, from: from, wait: first ? 0 : 20)
                first = false
                take(answer, askedFrom: from)
                from = answer.total
                problem = nil
                if !answer.running { return }
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                // The engine is out of reach for now: ask again once it is back, when it says whether it still has it.
                if engine.status != .connected {
                    try? await Task.sleep(for: .seconds(2))
                    first = true
                    continue
                }
                problem = error.localizedDescription
                return
            }
        }
    }

    func take(_ answer: BackgroundOutput, askedFrom: Int) {
        latest = answer
        if answer.dropped > 0 || answer.from < askedFrom || askedFrom == 0 {
            // More was printed since the last answer than the engine keeps, or this is the first: start again from what it has.
            text = answer.output
            notShown = answer.from
            replaced += 1
        } else if !answer.output.isEmpty {
            text += answer.output
        }
        // A command that prints for hours would otherwise fill the page without end: keep the last part, from a new line.
        let units = text.utf16.count
        if units > 2 * Self.keep {
            var cut = text.utf16.index(text.utf16.startIndex, offsetBy: units - Self.keep)
            if let newline = text[cut...].firstIndex(of: "\n") { cut = text.index(after: newline) }
            notShown += text[..<cut].utf16.count
            text = String(text[cut...])
            replaced += 1
        }
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
