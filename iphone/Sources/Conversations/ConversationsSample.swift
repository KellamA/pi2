import PiModels
import SwiftUI

#if DEBUG
import Foundation

/// A debug build's way to picture the states of the conversations' screens that the recorded session never reaches (it
/// has no chats, nothing archived, no background command, and does not answer `projects.folders`), chosen with
/// `PI2_CONVERSATIONS_SAMPLE=1` in the environment (`--env` with `scripts/iphone-sim run`). Each screen then draws these
/// plainly sample rows in place of the engine's, under a line that says so; nothing is answered: its requests still go to
/// the engine, which refuses them. None of it is compiled into a release build.
///
/// `PI2_CONVERSATIONS_ACT` does what a tap would, once, as the screen shows, so that what the engine answers can be
/// pictured: `archive` (the first row of a conversations list), `new-chat`, `restore` (the Archive's first conversation),
/// `restore-project` (the first conversation of a deleted project: its dry run), `restore-project-go` (the same, then the
/// sheet's Restore), `unarchive-project` (the Archive's first archived project), `stop` (the first background command, or
/// the one whose output shows), `make` (Make Project). Each sends the real request through the session, once the client
/// has reached the Mac itself.
struct ConversationsSample {
    static let current: ConversationsSample? = ProcessInfo.processInfo.environment["PI2_CONVERSATIONS_SAMPLE"] == "1" ? ConversationsSample() : nil

    private static let act = ProcessInfo.processInfo.environment["PI2_CONVERSATIONS_ACT"]
    @MainActor private static var done: Set<String> = []

    /// Whether `name` was asked for and not done yet; marks it done. Waits first for the client to reach the Mac itself
    /// (a paired phone's starts on what the Mac last sent, which refuses every request), up to half a minute, then a
    /// moment more, for the screen to have drawn.
    @MainActor static func take(_ name: String, in session: AppSession) async -> Bool {
        guard act == name, !done.contains(name) else { return false }
        done.insert(name)
        for _ in 0..<150 where !ConversationsReach(session).ready {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1))
        // A screen's task started again (it reached the Mac meanwhile) takes it then, on what the Mac sent.
        if Task.isCancelled {
            done.remove(name)
            return false
        }
        return true
    }

    private static let now = Date().timeIntervalSince1970 * 1000
    private static let minute = 60_000.0
    private static let day = 86_400_000.0

    /// The list for a project, or for no project: chats and conversations outside projects.
    func listing(project: String?) -> ConversationsListing? {
        let now = Self.now, minute = Self.minute, day = Self.day
        if project != nil {
            return ConversationsListing(sections: [
                .init(id: "agents", title: "Agents", rows: [
                    ConversationsRow(id: 9001, title: "Fold the board on narrow windows", agentName: "Forge", agentColor: "orange", busy: true, updatedAt: now - 2 * minute),
                    ConversationsRow(id: 9002, title: "Document the Dashboard", agentName: "Scribe", agentColor: "teal", updatedAt: now - 3 * 60 * minute),
                ]),
                .init(id: "subChats", title: "Sub-chats", rows: [
                    ConversationsRow(id: 9003, title: "Check the links on every page", agentName: "Scout", agentColor: "blue", updatedAt: now - day,
                                     subChatOf: "Put together a short walkthrough for Friday."),
                ]),
                .init(id: "earlier", title: "Earlier with an orchestrator", rows: [
                    ConversationsRow(id: 9004, title: "Plan the hub", agentName: "Orchestrator", agentColor: "violet", updatedAt: now - 9 * day),
                ]),
            ])
        }
        return ConversationsListing(sections: [
            .init(id: "chats", title: "Chats", rows: [
                ConversationsRow(id: 9101, title: "Recipe for 12, scaled", agentName: nil, agentColor: nil, chat: true, pinned: true, updatedAt: now - 2 * day),
                ConversationsRow(id: 9102, title: "Which lens for low light?", agentName: nil, agentColor: nil, chat: true, updatedAt: now - 30 * minute),
                ConversationsRow(id: 9103, title: "", agentName: nil, agentColor: nil, chat: true, busy: true, updatedAt: now - minute),
            ]),
            .init(id: "outside", title: "Outside projects", rows: [
                ConversationsRow(id: 9104, title: "Tidy the downloads folder", agentName: "Atlas", agentColor: "violet", updatedAt: now - 4 * day),
            ]),
        ])
    }

    var archive: ArchiveListing? {
        let now = Self.now, day = Self.day
        return ArchiveListing(
            archivedProjects: [
                .init(id: "p-sample-1", name: "taxes 2026", color: "pink", detail: "taxes-2026 · archived 3 days ago"),
            ],
            deletedProjects: [
                .init(id: "p-sample-2", name: "old website", color: "teal", detail: "website · deleted yesterday", conversations: [
                    .init(id: 9201, title: "Check every link", chat: false, agentName: "Scout", agentColor: "blue", detail: "Scout · 2 sub-chats"),
                ]),
            ],
            conversations: [
                .init(id: 9202, title: "Fix the login form", chat: false, agentName: "Forge", agentColor: "orange",
                      detail: "Forge · archived \(ConversationsTime.ago(now - 2 * day)) · 1 sub-chat"),
                .init(id: 9203, title: "Read the draft notes", chat: false, agentName: "Scout", agentColor: "blue",
                      detail: "Scout · sub-chat of “Put together a short walkthrough for Friday.” · archived today"),
                .init(id: 9204, title: "Packing list for the trip", chat: true, agentName: nil, agentColor: nil,
                      detail: "Chat · archived \(ConversationsTime.ago(now - 40 * day))"),
            ],
            autoArchiveDays: 30
        )
    }

    var commands: [BackgroundCommandsRow]? {
        let now = Self.now, minute = Self.minute
        return [
            BackgroundCommandsRow(id: "bg-3", command: "npm --prefix engine run dev", conversationId: 9001, rootConversationId: 9001,
                                  source: "Fold the board on narrow windows · Forge", folder: "pi2", startedAt: now - 42 * minute - 7_000),
            BackgroundCommandsRow(id: "bg-5", command: "python3 -m http.server 8080 --directory site/build", conversationId: 9003, rootConversationId: 9,
                                  source: "sub-chat “Check the links on every page” · Scout", folder: "website", startedAt: now - 3 * minute),
        ]
    }

    /// A command's output as `background.output` answers it, decoded from the engine's own shape.
    func output(_ id: String) -> BackgroundOutput? {
        let lines = (1...60).map { "GET /docs/page-\($0).html 200 \(12 + $0 % 7) ms" }.joined(separator: "\n")
        let answer: [String: Any] = [
            "conversationId": 9003, "rootConversationId": 9, "command": "python3 -m http.server 8080 --directory site/build",
            "cwd": "/Users/someone/Developer/website", "startedAt": Self.now - 3 * Self.minute, "running": true, "stopping": false,
            "ended": NSNull(), "kept": true, "total": lines.utf16.count + 400, "from": 400, "dropped": 0,
            "output": "Serving HTTP on :: port 8080 (http://[::]:8080/) ...\n" + lines + "\n",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: answer) else { return nil }
        return try? JSONDecoder().decode(BackgroundOutput.self, from: data)
    }

    var folders: [NewProjectFolder]? {
        [
            NewProjectFolder(path: "/Users/someone/Developer/website", name: "website", where: "~/Developer", repository: "someone/website"),
            NewProjectFolder(path: "/Users/someone/Documents/Taxes 2026", name: "Taxes 2026", where: "~/Documents"),
            NewProjectFolder(path: "/Users/someone/Developer/pi2", name: "pi2", where: "~/Developer", project: "pi2", repository: "someone/pi2"),
        ]
    }
}
#endif

/// The line over a debug sample, so that a picture of one never passes for the engine's.
struct ConversationsSampleNote: View {
    var body: some View {
        Label("Debug sample: these rows are not from the engine.", systemImage: "hammer")
            .font(.footnote)
            .foregroundStyle(Color.pi2Accent)
    }
}
