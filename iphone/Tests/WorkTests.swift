import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// A project's work on the phone (#694): what the Work screens read of the engine's state, as the Mac's Work tab reads
/// the `work` and `github` events, and the requests they send, each as the Mac app makes it.
@MainActor
struct WorkTests {
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
        #expect(try await eventually {
            session.engine.projects.count == 2 && session.engine.extras["work"] != nil && !session.engine.allAgents.isEmpty
        })
        return session
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func readsTheRecordedWorkAsTheMacDoes() async throws {
        let session = try await replaySession()
        let engine = session.engine
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        #expect(engine.workProject(project.id) == project)
        #expect(engine.workProject("no-such-project") == nil)

        // The recording settles on its last `work` event: the list pi² keeps, every state of the table in it.
        #expect(try await eventually { engine.workListing(project).item(4)?.state == "blocked" })
        let listing = engine.workListing(project)
        #expect(listing.source == .kept)
        #expect(listing.arrived && !listing.firstRead && !listing.troubled)
        #expect(listing.items.map(\.id).sorted() == [1, 2, 3, 4, 5, 6])
        #expect(listing.sections(.open).map(\.id) == ["open", "in_progress", "waiting", "blocked"])
        #expect(listing.sections(.waiting).map(\.id) == ["waiting", "blocked"])
        #expect(listing.sections(.done).map(\.id) == ["done", "dropped"])
        #expect(listing.count(.open) == 4)

        let waiting = try #require(listing.item(3))
        #expect(waiting.title == "Confirm the walkthrough date")
        #expect(waiting.held && !waiting.givable && !waiting.closed)
        #expect(waiting.holderConversation == 17)
        #expect(engine.agent(waiting.holderAgentId)?.name == "Atlas")
        #expect(waiting.notes.map(\.text) == ["Waiting on the walkthrough date."])
        #expect(engine.agent(waiting.notes.first?.agentId)?.name == "Atlas")
        #expect(try #require(listing.item(1)).givable)
        #expect(try #require(listing.item(5)).result == "The notes are ready to share.")

        // Work is given to the project's workers, not its orchestrator, in the order the Agents tab shows them.
        let agents = engine.workAgents(project)
        #expect(agents.map(\.name) == ["Atlas", "Forge", "Scout", "Beacon"])
        #expect(!agents.contains { $0.id == project.orchestratorId })
        #expect(agents.allSatisfy { $0.projectId == project.id })
    }

    @Test func aRepositorysIssuesAndPullRequestsReadAsTheMacs() throws {
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let ms = now.timeIntervalSince1970 * 1000
        let event = try json("""
            {"projects": {"p-1": {"state": "ok", "readAt": \(ms - 180_000), "reading": true, "error": null,
              "issues": [
                {"id": 7, "title": "Open one", "text": "", "state": "open", "class": "local", "takenBy": null, "notes": [], "updatedAt": \(ms - 60_000)},
                {"id": 8, "title": "Newer open one", "text": "", "state": "open", "takenBy": null, "notes": [], "updatedAt": \(ms - 1000)},
                {"id": 9, "title": "Held", "state": "in_progress", "takenBy": {"agentId": "forge", "conversationId": 21}, "notes": [], "updatedAt": \(ms)},
                {"id": 3, "title": "Closed", "state": "done", "takenBy": null, "notes": [], "result": "Shipped.", "updatedAt": \(ms), "partial": true}],
              "pulls": [
                {"number": 12, "title": "Ready", "state": "open", "draft": false, "checks": "passing", "failingChecks": [], "mergeable": "yes",
                 "findings": [{"agentName": "Scout", "verdict": "changes", "at": \(ms - 9000), "url": "", "text": ""},
                              {"agentName": "Reviewer", "verdict": "approve", "at": \(ms - 1000), "url": "", "text": ""}], "work": 7},
                {"number": 14, "title": "Failing", "state": "open", "draft": false, "checks": "failing",
                 "failingChecks": [{"name": "engine", "url": ""}, {"name": "app", "url": ""}], "mergeable": "yes", "findings": []},
                {"number": 10, "title": "Merged", "state": "merged", "draft": false, "checks": "passing", "failingChecks": [], "mergeable": "unknown", "findings": []}],
              "unknown": [{"intent": "merge:12", "summary": "merging pull request #12", "at": \(ms - 600_000)}]}}}
            """)
        let listing = WorkListing.github(event, project: "p-1", repository: "octo/sample")
        #expect(listing.onGitHub && listing.noun == "issue" && listing.noteWord == "comment")
        #expect(!listing.firstRead && !listing.troubled && listing.reading)
        #expect(listing.readAt == now.addingTimeInterval(-180))

        // The open pull requests first, newest first; the open issues by state, newest-changed first; what was merged or
        // closed after the closed work.
        let open = listing.sections(.open)
        #expect(open.map(\.id) == ["pulls", "open", "in_progress"])
        #expect(open[0].rows.map(\.id) == ["pull:14", "pull:12"])
        #expect(open[1].rows.map(\.id) == ["item:8", "item:7"])
        #expect(listing.sections(.done).map(\.id) == ["done", "closedPulls"])
        #expect(listing.sections(.waiting).isEmpty)

        let ready = try #require(listing.pulls.first { $0.number == 12 })
        #expect(ready.newestFinding?.agentName == "Reviewer")
        #expect(ready.standing == "ready")
        #expect(ready.checksWords == "Checks passing")
        #expect(ready.work == 7)
        let failing = try #require(listing.pulls.first { $0.number == 14 })
        #expect(failing.standing == "checks failing")
        #expect(failing.checksWords == "2 checks failing")
        #expect(try #require(listing.pulls.first { $0.number == 10 }).standing == "merged")
        #expect(WorkPull.verdictWords("changes") == "asked for changes")

        #expect(listing.unknown.map(\.summary) == ["merging pull request #12"])
        #expect(try #require(listing.item(3)).partial)
        #expect(try #require(listing.item(7)).modelClass == "local")
    }

    @Test func gitHubOutOfReachKeepsTheLastReadAndSaysWhy() throws {
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let ms = now.timeIntervalSince1970 * 1000
        func listing(_ state: String, readAt: Double?, error: String? = nil) throws -> WorkListing {
            let value: [String: Any] = ["projects": ["p-1": [
                "state": state, "readAt": readAt.map { $0 as Any } ?? NSNull(), "error": error.map { $0 as Any } ?? NSNull(),
                "issues": [], "pulls": [],
            ]]]
            let event = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
            return WorkListing.github(event, project: "p-1", repository: "octo/sample")
        }
        let signedOut = try listing("signed_out", readAt: ms - 7_200_000)
        #expect(signedOut.troubled && !signedOut.firstRead)
        #expect(signedOut.troubleWords(now: now) == "gh is not signed in to GitHub on the Mac. The last read, 2 h ago, is below; nothing here can change until it is.")
        let missing = try listing("signed_out", readAt: nil, error: "gh: command not found")
        // Nothing read, and GitHub out of reach: the list shows, empty, under the words, as on the Mac.
        #expect(!missing.firstRead && missing.items.isEmpty)
        #expect(missing.troubleWords(now: now)?.hasPrefix("GitHub's command-line tool gh is not installed on the Mac. Nothing has been read yet") == true)
        #expect(try listing("unreachable", readAt: ms).troubleWords(now: now)?.hasPrefix("GitHub cannot be reached.") == true)
        #expect(try listing("rate_limited", readAt: ms).troubleWords(now: now)?.hasPrefix("GitHub's rate limit is reached.") == true)

        // The first read under way, and the event not come at all, both show the frame and a wait.
        let first = try listing("loading", readAt: nil)
        #expect(first.firstRead && !first.troubled && first.troubleWords() == nil)
        #expect(WorkListing.github(nil, project: "p-1", repository: "octo/sample").firstRead)
        #expect(WorkListing.kept(nil, project: "p-1").firstRead)
        // A project the `work` event does not name has nothing yet: an empty list, not a wait.
        let none = WorkListing.kept(try json(#"{"projects": {}}"#), project: "p-1")
        #expect(!none.firstRead && none.items.isEmpty && none.sections(.open).isEmpty)
    }

    @Test func aChangeOnItsWayShowsAtOnce() throws {
        let item = try #require(WorkItem(try json("""
            {"id": 4, "title": "Held", "text": "", "state": "waiting", "takenBy": {"agentId": "forge", "conversationId": 23}, "notes": []}
            """)))
        let closing = item.showing(.of("close", as: "dropped"))
        #expect(closing.state == "dropped" && closing.holderAgentId == nil && closing.holderConversation == nil)
        #expect(WorkChange.of("close").state == "done")
        #expect(item.showing(.of("resume")).state == "in_progress")
        #expect(item.showing(.of("resume")).holderAgentId == "forge")
        #expect(item.showing(.of("note")) == item)
        let giving = item.showing(WorkChange(word: "Giving to Atlas", state: "in_progress", holderAgentId: "atlas"))
        #expect(giving.state == "in_progress" && giving.holderAgentId == "atlas" && giving.holderConversation == nil)
        #expect(WorkItem(try json(#"{"id": 1}"#)) == nil)
        #expect(WorkState.name("in_progress") == "In progress")
        #expect(WorkState.name("someday") == "someday")
    }

    @Test func requestsAreTheMacsAndARefusalIsSaid() async throws {
        let transport = WorkRecordingTransport(refusal: "Refused for the test.")
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.status == .connected })

        #expect(await WorkRequests.create(engine, project: "p-1", title: "File it", text: "Why") == "Refused for the test.")
        #expect(await WorkRequests.act(engine, project: "p-1", item: 3, "close", ["as": "dropped"]) == "Refused for the test.")
        #expect(await WorkRequests.act(engine, project: "p-1", item: 3, "classify", ["class": NSNull()]) == "Refused for the test.")
        #expect(await WorkRequests.assign(engine, project: "p-1", item: 1, agent: "atlas") == .refused("Refused for the test."))
        #expect(await WorkRequests.refresh(engine, project: "p-1") == "Refused for the test.")
        #expect(await WorkRequests.show(engine, project: "p-1", number: 600) == "Refused for the test.")
        #expect(await WorkRequests.settle(engine, project: "p-1", intent: "merge:12", happened: false) == "Refused for the test.")

        let sent = transport.sent
        #expect(sent.map(\.method) == ["work.create", "work.act", "work.act", "work.act", "github.refresh", "github.show", "github.settle"])
        #expect(sent[0].params["projectId"] as? String == "p-1")
        #expect(sent[0].params["title"] as? String == "File it")
        #expect(sent[0].params["text"] as? String == "Why")
        #expect(sent[1].params["id"] as? Int == 3)
        #expect(sent[1].params["action"] as? String == "close")
        #expect(sent[1].params["as"] as? String == "dropped")
        #expect(sent[2].params["class"] is NSNull)
        #expect(sent[3].params["action"] as? String == "assign")
        #expect(sent[3].params["agentId"] as? String == "atlas")
        // No folder of its own: the engine gives the same default an agent's `assign` gets, as from the Mac's Give.
        #expect(sent[3].params["worktree"] == nil && sent[3].params["confirmLimit"] == nil)
        #expect(sent[5].params["number"] as? Int == 600)
        #expect(sent[6].params["intent"] as? String == "merge:12")
        #expect(sent[6].params["happened"] as? Bool == false)

        // Taken, each answers nil.
        transport.refusal = nil
        #expect(await WorkRequests.create(engine, project: "p-1", title: "File it", text: "") == nil)
        #expect(await WorkRequests.assign(engine, project: "p-1", item: 1, agent: "atlas") == .given)
    }

    @Test func aStartPastTheLimitIsHeldThenConfirmedOnce() async throws {
        let transport = WorkRecordingTransport(refusal: "Starting it goes past the project's daily spending limit.",
                                               data: ["limit": ["id": "reading-7", "limit": "dailySpend", "reason": "$5.10 of $5.00 spent"]])
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.status == .connected })
        let item = try #require(WorkItem(try json(#"{"id": 1, "title": "Write the release checklist", "state": "open", "notes": []}"#)))
        let agent = try JSONDecoder().decode(AgentProfile.self, from: Data(#"""
            {"id": "atlas", "name": "Atlas", "description": "", "color": "blue", "instructions": "", "access": "full", "delegates": [], "createdAt": 0}
            """#.utf8))

        let desk = WorkDesk()
        await desk.assign(engine, project: "p-1", item: item, to: agent)
        let held = try #require(desk.held)
        #expect(held.limit.id == "reading-7")
        #expect(held.limit.name == "daily spending limit")
        #expect(held.title == "Past the project's daily spending limit")
        #expect(held.message == "Starting Atlas on “Write the release checklist” goes past it: $5.10 of $5.00 spent. Work already running carries on. Start it anyway?")
        #expect(desk.problem == nil)
        #expect(desk.pending.isEmpty)

        // Start Anyway confirms that one reading, and the engine takes it.
        transport.refusal = nil
        await desk.assign(engine, project: "p-1", item: item, to: agent, confirming: held.limit)
        #expect(transport.sent.last?.params["confirmLimit"] as? String == "reading-7")
        #expect(desk.held == nil && desk.problem == nil)

        // Any other refusal is said, and the piece is as it was.
        transport.refusal = "Atlas is busy."
        transport.data = nil
        #expect(await desk.act(engine, project: "p-1", item: item, "release") == false)
        #expect(desk.problem == "Atlas is busy.")
        #expect(desk.pending.isEmpty)
        #expect(await desk.note(engine, project: "p-1", item: item, text: "A note") == "Atlas is busy.")
        #expect(desk.sending.isEmpty)
    }

    @Test func wordsReadAsTheMacs() {
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        #expect(WorkTime.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(WorkTime.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(WorkTime.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(WorkTime.ago(now.addingTimeInterval(-50 * 3600), now: now) == "2 d ago")
        #expect(WorkTime.date(.number(1_795_359_600_000)) == now)
        #expect(WorkComposer.oneLine("  Two\nlines \n") == "Two lines")
        #expect(WorkFilter.allCases.map(\.name) == ["Open", "Waiting", "Done"])
    }
}

/// A stand-in for a Mac that keeps every request a Work screen sends it and answers each with `refusal` as the engine's
/// error (with `data` beside it, as a limit's refusal carries its reading), or with an empty result when it is nil.
@MainActor
final class WorkRecordingTransport: EngineTransport {
    struct Request {
        let method: String
        let params: [String: Any]
    }

    var refusal: String?
    var data: [String: Any]?
    private(set) var sent: [Request] = []
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    init(refusal: String?, data: [String: Any]? = nil) {
        self.refusal = refusal
        self.data = data
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
        var answer: [String: Any] = ["id": id]
        if let refusal {
            answer["error"] = refusal
            if let data = self.data { answer["data"] = data }
        } else {
            answer["result"] = [String: Any]()
        }
        var line = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        line.append(0x0A)
        Task { @MainActor [weak self] in self?.handler?(.received(line)) }
    }

    func cancel() {
        handler = nil
    }
}
