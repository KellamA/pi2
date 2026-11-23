import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// The conversations' screens (#698): a project's other conversations, chats and conversations outside projects, the
/// archive, background commands and a new project. What they read of the engine's state, as the Mac's sidebar, chat mode,
/// Archive and output window read it, and the requests they send, each as the Mac app makes it.
@MainActor
struct ConversationsTests {
    /// Waits for `condition`, polling, for at most `seconds`.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func replaySession() async throws -> AppSession {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        #expect(try await eventually { session.engine.projects.count == 2 && session.engine.hasLoadedLibrary && session.engine.conversations.count >= 10 })
        return session
    }

    /// The engine's own types, decoded from the engine's JSON: plainly sample data.
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func agent(_ id: String, _ name: String, _ color: String, project: String? = nil) -> String {
        """
        {"id": "\(id)", "name": "\(name)", "description": "", "color": "\(color)", "instructions": "", "access": "read",
         "delegates": [], "createdAt": 1, "projectId": \(project.map { "\"\($0)\"" } ?? "null")}
        """
    }

    // MARK: - Reading

    @Test func readsTheRecordedProjectsOtherConversations() async throws {
        let session = try await replaySession()
        let engine = session.engine
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        let listing = ConversationsListing.project(project.id, conversations: engine.conversations, agents: engine.allAgents)

        // The orchestrator's conversation (9) is the hub's Chat tab, not listed here; the other project's are not either.
        let agents = try #require(listing.sections.first { $0.id == "agents" })
        #expect(Set(agents.rows.map(\.id)) == [17, 23, 29])
        #expect(agents.rows.allSatisfy { $0.agentName != nil && !$0.chat })
        let subChats = try #require(listing.sections.first { $0.id == "subChats" })
        #expect(subChats.rows.map(\.id) == [37])
        #expect(subChats.rows[0].agentName == "Scout")
        #expect(subChats.rows[0].subChatOf == "Put together a short walkthrough for Friday.")
        #expect(!listing.sections.contains { $0.id == "earlier" })

        // The recording has no chat and no conversation outside projects.
        #expect(ConversationsListing.outside(conversations: engine.conversations, agents: engine.allAgents).isEmpty)
        #expect(engine.conversationsProject(project.id) == project)
    }

    @Test func outsideProjectsListsChatsPinnedFirstThenConversationsAndSubChats() throws {
        let conversations = try decode([ConversationSummary].self, """
            [{"id": 1, "title": "Old chat", "updatedAt": 100, "busy": false, "agentId": null, "parent": null, "chat": true},
             {"id": 2, "title": "Pinned chat", "updatedAt": 50, "busy": false, "agentId": null, "parent": null, "chat": true, "pinned": true},
             {"id": 3, "title": "", "updatedAt": 300, "busy": true, "agentId": null, "parent": null, "chat": true},
             {"id": 4, "title": "Tidy the downloads", "updatedAt": 200, "busy": false, "agentId": "atlas", "parent": null},
             {"id": 5, "title": "Find the receipts", "updatedAt": 210, "busy": false, "agentId": "scout", "parent": 4},
             {"id": 6, "title": "In a project", "updatedAt": 400, "busy": false, "agentId": "atlas", "parent": null, "projectId": "p-1"},
             {"id": 7, "title": "Earlier", "updatedAt": 90, "busy": false, "agentId": "orch", "parent": null, "projectId": "p-1", "orchestrator": "earlier"},
             {"id": 8, "title": "Now", "updatedAt": 95, "busy": false, "agentId": "orch", "parent": null, "projectId": "p-1", "orchestrator": "current"}]
            """)
        let agents = try decode([AgentProfile].self, "[\(agent("atlas", "Atlas", "violet")), \(agent("scout", "Scout", "teal")), \(agent("orch", "Orchestrator", "violet", project: "p-1"))]")

        let outside = ConversationsListing.outside(conversations: conversations, agents: agents)
        #expect(outside.sections.map(\.id) == ["chats", "outside", "subChats"])
        #expect(outside.sections[0].rows.map(\.id) == [2, 3, 1])
        #expect(outside.sections[0].rows[1].shownTitle == "New chat")
        #expect(outside.sections[0].rows[1].detail == "Chat · working")
        #expect(outside.sections[0].rows[0].spokenLabel == "Pinned chat, Chat, pinned")
        #expect(outside.sections[1].rows.map(\.id) == [4])
        #expect(outside.sections[1].rows[0].detail == "Atlas")
        #expect(outside.sections[2].rows.map(\.id) == [5])
        #expect(outside.sections[2].rows[0].detail == "Scout · sub-chat of “Tidy the downloads”")

        let project = ConversationsListing.project("p-1", conversations: conversations, agents: agents)
        #expect(project.sections.map(\.id) == ["agents", "earlier"])
        #expect(project.sections[0].rows.map(\.id) == [6])
        #expect(project.sections[1].rows.map(\.id) == [7])

        // Every word typed, in the title, the agent's name, or "chat".
        #expect(outside.filtered("chat").count == 3)
        #expect(outside.filtered("atlas tidy").sections.flatMap(\.rows).map(\.id) == [4])
        #expect(outside.filtered("nothing like it").isEmpty)
        #expect(outside.filtered("  ") == outside)
    }

    @Test func timesReadAsTheListsSayThem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // Sunday 2026-11-22 15:00 UTC.
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let ms = now.timeIntervalSince1970 * 1000
        let day = 86_400_000.0
        #expect(ConversationsTime.short(ms - day, now: now, calendar: calendar) == "Yesterday")
        #expect(!ConversationsTime.short(ms - 3 * day, now: now, calendar: calendar).isEmpty)
        #expect(ConversationsTime.ago(ms, now: now, calendar: calendar) == "today")
        #expect(ConversationsTime.ago(ms - day, now: now, calendar: calendar) == "yesterday")
        #expect(ConversationsTime.ago(ms - 5 * day, now: now, calendar: calendar) == "5 days ago")
        #expect(ConversationsTime.ago(ms - 60 * day, now: now, calendar: calendar).hasPrefix("on "))
    }

    @Test func archiveListsProjectsDeletedProjectsAndConversationsAsTheMacDoes() throws {
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let ms = now.timeIntervalSince1970 * 1000
        let projects = try decode([ProjectRow].self, """
            [{"id": "p-live", "name": "Live", "folder": "/x/live", "repository": null, "orchestratorId": "o1", "conversation": 1, "archivedAt": null, "deletedAt": null, "lastWords": null},
             {"id": "p-archived", "name": "Taxes", "folder": "/x/taxes-2026", "repository": null, "orchestratorId": "o2", "conversation": 2, "archivedAt": \(ms - 3 * 86_400_000), "deletedAt": null, "lastWords": null},
             {"id": "p-deleted", "name": "Old site", "folder": null, "repository": null, "orchestratorId": "o3", "conversation": 3, "archivedAt": null, "deletedAt": \(ms), "lastWords": null}]
            """)
        let conversations = try decode([ConversationSummary].self, """
            [{"id": 30, "title": "Still listed", "updatedAt": 1, "busy": false, "agentId": "scout", "parent": null, "projectId": "p-deleted"},
             {"id": 31, "title": "Its sub-chat", "updatedAt": 1, "busy": false, "agentId": "scout", "parent": 30, "projectId": "p-deleted"}]
            """)
        let archived = try decode([ArchivedConversation].self, """
            [{"id": 40, "title": "Fix the login form", "archivedAt": \(ms), "agentId": "forge", "subChats": 1, "parent": null, "parentTitle": null},
             {"id": 41, "title": "", "archivedAt": \(ms - 86_400_000), "agentId": null, "subChats": 0, "parent": null, "parentTitle": null, "chat": true},
             {"id": 42, "title": "Read the notes", "archivedAt": \(ms), "agentId": "scout", "subChats": 0, "parent": 1, "parentTitle": "", "projectId": "p-live"},
             {"id": 25, "title": "Of the deleted one", "archivedAt": \(ms), "agentId": "scout", "subChats": 2, "parent": null, "parentTitle": null, "projectId": "p-deleted"}]
            """)
        let agents = try decode([AgentProfile].self, "[\(agent("forge", "Forge", "orange")), \(agent("scout", "Scout", "teal")), \(agent("o2", "Orchestrator", "pink", project: "p-archived"))]")

        let listing = ArchiveListing.read(archived: archived, conversations: conversations, projects: projects, agents: agents, autoArchiveDays: 45, now: now)
        #expect(listing.archivedProjects.map(\.id) == ["p-archived"])
        #expect(listing.archivedProjects[0].detail == "taxes-2026 · archived 3 days ago")
        #expect(listing.archivedProjects[0].color == "pink")
        #expect(listing.deletedProjects.map(\.id) == ["p-deleted"])
        #expect(listing.deletedProjects[0].detail == "No folder · deleted today")
        // Its live conversation and its archived one, oldest first; a sub-chat comes with its conversation.
        #expect(listing.deletedProjects[0].conversations.map(\.id) == [25, 30])
        #expect(listing.deletedProjects[0].conversations[0].detail == "Scout · archived today · 2 sub-chats")
        #expect(listing.deletedProjects[0].conversations[1].detail == "Scout · 1 sub-chat")
        // The Archive's own list leaves out the deleted project's, which are listed under it.
        #expect(listing.conversations.map(\.id) == [40, 41, 42])
        #expect(listing.conversations[0].detail == "Forge · archived today · 1 sub-chat")
        #expect(listing.conversations[1].shownTitle == "New chat")
        #expect(listing.conversations[1].detail == "Chat · archived yesterday")
        #expect(listing.conversations[2].detail == "Scout · sub-chat of “New conversation” · archived today")
        #expect(listing.filtered("chat").map(\.id) == [41])
        #expect(listing.filtered("forge login").map(\.id) == [40])
        #expect(!listing.isEmpty)

        #expect(ArchiveListing.autoArchiveChoices(45) == [7, 30, 45, 90, 365])
        #expect(ArchiveListing.autoArchiveChoices(nil) == [7, 30, 90, 365])
        #expect(ArchiveListing.autoArchiveLabel(90) == "Three months")
        #expect(ArchiveListing.autoArchiveLabel(45) == "45 days")
    }

    @Test func theRecordedArchiveIsEmpty() async throws {
        let session = try await replaySession()
        let engine = session.engine
        let listing = ArchiveListing.read(archived: engine.archived, conversations: engine.conversations, projects: engine.projects,
                                          agents: engine.allAgents, autoArchiveDays: engine.autoArchiveDays)
        #expect(listing.isEmpty)
        #expect(BackgroundCommandsRow.read(engine.backgroundCommands, conversations: engine.conversations, agents: engine.allAgents).isEmpty)
    }

    // MARK: - Background commands

    @Test func backgroundCommandsNameWhoseTheyAre() async throws {
        let session = try await replaySession()
        let engine = session.engine
        let commands = try decode([BackgroundCommand].self, """
            [{"id": "bg-3", "conversationId": 17, "rootConversationId": 17, "command": "npm run dev\\n--watch", "cwd": "/x/demo-project", "startedAt": 1000},
             {"id": "bg-4", "conversationId": 37, "rootConversationId": 9, "command": "make", "cwd": "/x/y", "startedAt": 2000},
             {"id": "bg-5", "conversationId": 999, "rootConversationId": 999, "command": "ls", "cwd": "/", "startedAt": 3000}]
            """)
        let rows = BackgroundCommandsRow.read(commands, conversations: engine.conversations, agents: engine.allAgents)
        #expect(rows.map(\.id) == ["bg-3", "bg-4", "bg-5"])
        #expect(rows[0].oneLine == "npm run dev --watch")
        #expect(rows[0].source == "Check the sample build · Atlas")
        #expect(rows[0].folder == "demo-project")
        #expect(rows[1].source == "sub-chat “Read the draft notes” · Scout")
        #expect(rows[1].rootConversationId == 9)
        #expect(rows[2].source == "Conversation 999")

        let start = 1_795_359_600_000.0
        #expect(BackgroundCommandsClock.text(since: start, until: Date(timeIntervalSince1970: start / 1000 + 247)) == "4:07")
        #expect(BackgroundCommandsClock.text(since: start, until: Date(timeIntervalSince1970: start / 1000 + 7500)) == "2h 5m")
        #expect(BackgroundCommandsClock.text(since: start, until: Date(timeIntervalSince1970: start / 1000 - 5)) == "0:00")
    }

    private func output(running: Bool = true, total: Int, from: Int, dropped: Int = 0, kept: Bool = true, _ text: String) throws -> BackgroundOutput {
        let answer: [String: Any] = [
            "conversationId": 17, "rootConversationId": 17, "command": "npm test", "cwd": "/x", "startedAt": 1000, "running": running,
            "stopping": false, "ended": running ? NSNull() : ["how": "exited with code 0 after 4 seconds", "failed": false] as [String: Any],
            "kept": kept, "total": total, "from": from, "dropped": dropped, "output": text,
        ]
        return try JSONDecoder().decode(BackgroundOutput.self, from: JSONSerialization.data(withJSONObject: answer))
    }

    @Test func outputFeedAddsToWhatItHasAndStartsAgainWhenMoreWasDropped() throws {
        let feed = BackgroundCommandsFeed(id: "bg-3", showing: try output(total: 6, from: 0, "hello\n"))
        #expect(feed.text == "hello\n")
        #expect(feed.notShown == 0)
        #expect(feed.note == nil)
        let first = feed.replaced

        feed.take(try output(total: 12, from: 6, "world\n"), askedFrom: 6)
        #expect(feed.text == "hello\nworld\n")
        #expect(feed.replaced == first)

        // More was printed than the engine keeps: what it has replaces what was shown.
        feed.take(try output(total: 500, from: 400, dropped: 388, "tail\n"), askedFrom: 12)
        #expect(feed.text == "tail\n")
        #expect(feed.notShown == 400)
        #expect(feed.replaced == first + 1)
        #expect(feed.note?.contains("The first 400 characters") == true)

        let gone = BackgroundCommandsFeed(id: "bg-9", showing: try output(running: false, total: 0, from: 0, kept: false, ""))
        #expect(gone.note == "Its output was in pi²'s engine when it stopped, and was not kept.")
    }

    @Test func outputFeedKeepsTheLastPartOfALongOutput() throws {
        let line = String(repeating: "x", count: 1023) + "\n"
        let big = String(repeating: line, count: 300)
        let feed = BackgroundCommandsFeed(id: "bg-3", showing: try output(total: big.utf16.count, from: 0, big))
        #expect(feed.text.utf16.count <= BackgroundCommandsFeed.keep)
        #expect(feed.text.hasPrefix("x"))
        #expect(feed.notShown + feed.text.utf16.count == big.utf16.count)
    }

    // MARK: - A new project

    @Test func foldersAreReadFromTheAnswerAndATakenOneCannotBeChosen() throws {
        let answer = try decode(JSONValue.self, """
            {"folders": [
              {"path": "/x/Developer/website", "name": "website", "where": "~/Developer", "repository": "someone/website"},
              {"path": "/x/Documents/Taxes", "name": "Taxes"},
              {"path": "/x/Developer/pi2", "name": "pi2", "where": "~/Developer", "project": "pi2"}]}
            """)
        let folders = try NewProjectFolder.list(answer)
        #expect(folders.map(\.name) == ["website", "Taxes", "pi2"])
        #expect(folders[0].detail == "someone/website · ~/Developer")
        #expect(folders[1].detail == "")
        #expect(folders[2].detail == "Already the folder of pi2 · ~/Developer")
        #expect(throws: (any Error).self) { try NewProjectFolder.list(try decode(JSONValue.self, #"{"nothing": []}"#)) }

        var choice = NewProjectChoice()
        #expect(choice.suggestedName == "No folder")
        #expect(choice.sentName == nil)
        #expect(choice.refusal == nil)
        choice.folder = folders[0]
        choice.name = "  Site  "
        #expect(choice.suggestedName == "website")
        #expect(choice.sentName == "Site")
        choice.folder = folders[2]
        #expect(choice.refusal == "That folder is already the folder of pi2.")
        choice.folder = nil
        choice.name = String(repeating: "n", count: 81)
        #expect(choice.refusal != nil)
    }

    // MARK: - Requests

    @Test func requestsAreTheMacsAndARefusalIsSaid() async throws {
        let transport = ConversationsRecordingTransport(refusal: "Refused for the test.")
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.status == .connected })

        #expect(await ConversationsRequests.archive(engine, conversation: 17) == "Refused for the test.")
        #expect(await ConversationsRequests.pin(engine, conversation: 3, pinned: true) == "Refused for the test.")
        #expect(await ConversationsRequests.rename(engine, conversation: 17, title: "New title") == "Refused for the test.")
        #expect(await ConversationsRequests.unarchive(engine, conversation: 40) == "Refused for the test.")
        #expect(await ConversationsRequests.delete(engine, conversation: 40) == "Refused for the test.")
        #expect(await ConversationsRequests.unarchiveProject(engine, project: "p-1") == "Refused for the test.")
        #expect(await ConversationsRequests.setAutoArchive(engine, days: nil) == "Refused for the test.")
        #expect(await ConversationsRequests.setAutoArchive(engine, days: 30) == "Refused for the test.")
        #expect(await ConversationsRequests.stopCommand(engine, command: "bg-3") == "Refused for the test.")
        #expect(await ConversationsRequests.newChat(engine) == .failure(ConversationsProblem("Refused for the test.")))
        #expect(await ConversationsRequests.folders(engine) == .failure(ConversationsProblem("Refused for the test.")))
        #expect(await ConversationsRequests.createProject(engine, folder: nil, name: nil, template: nil) == .failure(ConversationsProblem("Refused for the test.")))
        #expect(await ConversationsRequests.createProject(engine, folder: "/x/website", name: "Site", template: "forge") == .failure(ConversationsProblem("Refused for the test.")))
        #expect(await ConversationsRequests.restorePlan(engine, conversation: 25) == .failure(ConversationsProblem("Refused for the test.")))
        #expect(await ConversationsRequests.restore(engine, conversation: 25, plan: "plan-1") == .failed("Refused for the test."))
        await #expect(throws: EngineError.self) { try await ConversationsRequests.output(engine, command: "bg-3", from: 0, wait: 0) }

        let sent = transport.sent
        #expect(sent.map(\.method) == [
            "conversation.archive", "conversation.pin", "conversation.rename", "conversation.unarchive", "conversation.delete",
            "projects.unarchive", "settings.setAutoArchive", "settings.setAutoArchive", "background.stop", "conversation.create",
            "projects.folders", "projects.create", "projects.create", "projects.restoreConversation", "projects.restoreConversation",
            "background.output",
        ])
        #expect(sent[0].params["id"] as? Int == 17)
        #expect(sent[1].params["pinned"] as? Bool == true)
        #expect(sent[2].params["title"] as? String == "New title")
        #expect(sent[5].params["id"] as? String == "p-1")
        #expect(sent[6].params["days"] is NSNull)
        #expect(sent[7].params["days"] as? Int == 30)
        #expect(sent[8].params["id"] as? String == "bg-3")
        #expect(sent[9].params["chat"] as? Bool == true)
        #expect(sent[11].params["folder"] is NSNull)
        #expect(sent[11].params["name"] == nil && sent[11].params["template"] == nil)
        #expect(sent[12].params["folder"] as? String == "/x/website")
        #expect(sent[12].params["name"] as? String == "Site")
        #expect(sent[12].params["template"] as? String == "forge")
        #expect(sent[13].params["dryRun"] as? Bool == true)
        #expect(sent[14].params["plan"] as? String == "plan-1")
        #expect(sent[14].params["dryRun"] == nil)
        #expect(sent[15].params["from"] as? Int == 0)
        #expect(sent[15].params["wait"] as? Int == 0)
    }

    @Test func answersAreTakenAsTheEngineGivesThem() async throws {
        let transport = ConversationsRecordingTransport(refusal: nil)
        transport.answers = [
            "conversation.create": ["id": 77],
            "projects.create": ["id": "p-new", "conversation": 78],
            "projects.folders": ["folders": [["path": "/x/website", "name": "website"]]],
            "projects.restoreConversation": ["projectId": "p-back", "plan": NSNull(), "projects": [Any]()],
        ]
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.status == .connected })

        #expect(await ConversationsRequests.archive(engine, conversation: 17) == nil)
        #expect(await ConversationsRequests.newChat(engine) == .success(77))
        #expect(await ConversationsRequests.createProject(engine, folder: nil, name: nil, template: nil) == .success("p-new"))
        #expect(await ConversationsRequests.folders(engine) == .success([NewProjectFolder(path: "/x/website", name: "website")]))
        #expect(await ConversationsRequests.restore(engine, conversation: 25, plan: "plan-1") == .restored(project: "p-back"))
        // A dry run with no plan is not of a deleted project.
        #expect(await ConversationsRequests.restorePlan(engine, conversation: 25) == .failure(ConversationsProblem("This conversation is not of a deleted project.")))
    }

    @Test func theDemoAnswersTheScreensRequestsAsTheEngine() async throws {
        let transport = try #require(DemoTransport.recorded())
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        let engine = session.engine
        #expect(try await eventually { !engine.projects.isEmpty && engine.hasLoadedLibrary })
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        let conversation = try #require(engine.rootConversations.first { $0.projectId == project.id && $0.id != project.conversation }?.id)

        #expect(await ConversationsRequests.rename(engine, conversation: conversation, title: "  Renamed in the demo  ") == nil)
        #expect(try await eventually { engine.conversations.first { $0.id == conversation }?.title == "Renamed in the demo" })
        #expect(await ConversationsRequests.archive(engine, conversation: conversation) == nil)
        #expect(try await eventually { engine.archived.contains { $0.id == conversation } })
        #expect(await ConversationsRequests.delete(engine, conversation: conversation) == nil)
        #expect(try await eventually { !engine.archived.contains { $0.id == conversation } && !engine.conversations.contains { $0.id == conversation } })
        #expect(await ConversationsRequests.rename(engine, conversation: conversation, title: "Gone") == "Unknown conversation: \(conversation)")

        #expect(await ConversationsRequests.setAutoArchive(engine, days: 30) == nil)
        #expect(try await eventually { engine.autoArchiveDays == 30 })
        #expect(await ConversationsRequests.setAutoArchive(engine, days: 0) == "Choose a whole number of days from 1 to 3650, or never")
        #expect(await ConversationsRequests.setAutoArchive(engine, days: nil) == nil)
        #expect(try await eventually { engine.autoArchiveDays == nil })

        #expect(await ConversationsRequests.unarchiveProject(engine, project: project.id) == nil)
        #expect(await ConversationsRequests.unarchiveProject(engine, project: "p-none") == "Unknown project: p-none")
        let orchestrator = try #require(project.conversation)
        #expect(await ConversationsRequests.restorePlan(engine, conversation: orchestrator) == .failure(ConversationsProblem("This conversation is not of a deleted project.")))
        #expect(await ConversationsRequests.stopCommand(engine, command: "bg-1") == "That command is no longer running")
        // What the engine does not have yet, the demo refuses as it refuses anything it does not do.
        guard case .failure(let failure) = await ConversationsRequests.folders(engine) else {
            Issue.record("The demo answered projects.folders")
            return
        }
        #expect(failure.message.hasPrefix("The demo does not do projects.folders"))
    }

    @Test func theRecordingRefusesWhatItDoesNotAnswerAndTheScreenSaysSo() async throws {
        let session = try await replaySession()
        guard case .failure(let failure) = await ConversationsRequests.folders(session.engine) else {
            Issue.record("The recording answered projects.folders")
            return
        }
        #expect(failure.message.contains("does not answer projects.folders"))
        #expect(await ConversationsRequests.archive(session.engine, conversation: 17)?.contains("conversation.archive") == true)
    }
}

/// A stand-in for a Mac that keeps every request a screen sends it, and answers each with `refusal` as the engine's error,
/// else with `answers[method]`, or an empty result.
@MainActor
final class ConversationsRecordingTransport: EngineTransport {
    struct Request {
        let method: String
        let params: [String: Any]
    }

    var refusal: String?
    var answers: [String: Any] = [:]
    private(set) var sent: [Request] = []
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    init(refusal: String?) {
        self.refusal = refusal
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        Task { @MainActor [weak self] in self?.handler?(.ready) }
    }

    func send(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        // What the session says by itself on connecting, which no screen sends, is answered and not kept.
        if method != "conversations.shown" {
            sent.append(Request(method: method, params: object["params"] as? [String: Any] ?? [:]))
        }
        let answer: [String: Any] = refusal.map { ["id": id, "error": $0] } ?? ["id": id, "result": answers[method] ?? [String: Any]()]
        var line = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        line.append(0x0A)
        Task { @MainActor [weak self] in self?.handler?(.received(line)) }
    }

    func cancel() {
        handler = nil
    }
}
