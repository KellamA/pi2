import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// A project's hub and the Dashboard's pages (#688): what they read of the engine's state, as the Mac's Now tab and
/// Dashboard columns read it, and the requests they send, each as the Mac app makes it.
@MainActor
struct HubTests {
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
        #expect(try await eventually { session.engine.projects.count == 2 && !session.engine.activity.isEmpty })
        return session
    }

    @Test func readsTheRecordedProjectAsTheMacDoes() async throws {
        let session = try await replaySession()
        let engine = session.engine
        #expect(engine.hubListedProjects.map(\.name) == ["Demo project", "Demo project 2"])
        let project = try #require(engine.hubListedProjects.first { $0.name == "Demo project" })
        #expect(engine.hubProject(project.id) == project)
        #expect(engine.hubProject("no-such-project") == nil)

        // What needs the person and who works, of this project only.
        #expect(try await eventually { engine.hubNeeds(project.id).count == 3 })
        #expect(engine.hubNeeds(project.id).allSatisfy { $0.projectId == project.id })
        let runs = engine.hubRuns(project.id)
        #expect(runs.map(\.conversationId) == [17, 23, 29])
        #expect(runs.contains { $0.status == "waiting" })
        #expect(engine.hubModelName(agent: project.orchestratorId) != nil)

        // The recording reports no plan's windows, so the hub's bar has no meter.
        #expect(engine.hubPlanWeek() == nil)
    }

    @Test func finishedTodayIsSinceMidnightNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // 2026-11-22 15:00 UTC.
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let hour = 3_600_000.0
        let ms = now.timeIntervalSince1970 * 1000
        let json = """
            [{"submissionId": 1, "agentId": "scout", "title": "Yesterday", "ended": {"at": \(ms - 16 * hour), "outcome": "answered"}, "delivered": null},
             {"submissionId": 2, "agentId": "forge", "title": "Morning", "ended": {"at": \(ms - 6 * hour), "outcome": "failed"}, "delivered": {"by": "wake"}},
             {"submissionId": 3, "agentId": "atlas", "title": "Still going", "ended": null, "delivered": null},
             {"submissionId": 4, "agentId": "scout", "title": "Just now", "ended": {"at": \(ms - hour), "outcome": "answered"}, "delivered": null}]
            """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let reports = HubReport.today(value, now: now, calendar: calendar)
        #expect(reports.map(\.title) == ["Just now", "Morning"])
        #expect(reports.map(\.outcomeWord) == ["done", "failed"])
        #expect(reports[0].deliveredBy == nil)
        #expect(reports[1].deliveredBy == "wake")
        #expect(HubReport.today(nil, now: now).isEmpty)
    }

    @Test func planWeekIsTheBusiestWeekNotYetReset() throws {
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let later = now.timeIntervalSince1970 * 1000 + 86_400_000
        let earlier = now.timeIntervalSince1970 * 1000 - 1000
        let json = """
            {"providers": [
              {"id": "anthropic", "name": "Anthropic", "plan": "Max", "reports": "usage", "windows": [
                {"id": "5h", "label": "5-hour", "usedPercent": 90, "resetsAt": \(later)},
                {"id": "week", "label": "This week", "usedPercent": 41, "resetsAt": \(later)}]},
              {"id": "openai", "name": "OpenAI", "plan": null, "reports": "responses", "windows": [
                {"id": "week", "label": "Weekly", "usedPercent": 77, "resetsAt": \(earlier)}]}],
             "notices": []}
            """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let limits = try #require(PlanLimits(value))
        #expect(HubPlanWeek.read(limits, now: now) == HubPlanWeek(plan: "Anthropic Max", usedPercent: 41))
        #expect(HubPlanWeek.read(nil, now: now) == nil)
    }

    @Test func clockReadsAsTheMacs() {
        let now = Date(timeIntervalSince1970: 1_795_359_600)
        let ms = now.timeIntervalSince1970 * 1000
        #expect(HubClock.text(since: ms - 247_000, now: now) == "4:07")
        #expect(HubClock.text(since: ms - 7_500_000, now: now) == "2h 05m")
        #expect(HubClock.text(since: ms + 5000, now: now) == "0:00")
    }

    @Test func requestsAreTheMacsAndARefusalIsSaid() async throws {
        let transport = HubRecordingTransport(refusal: "Refused for the test.")
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        let engine = session.engine
        #expect(try await eventually { engine.projects.count == 1 })
        let project = try #require(engine.projects.first)

        #expect(await HubRequests.setWake(engine, project: "p-1", on: true) == "Refused for the test.")
        #expect(await HubRequests.stop(engine, conversation: 17) == "Refused for the test.")
        #expect(await HubRequests.startConversation(engine, project: "p-1") == "Refused for the test.")
        #expect(await HubRequests.message(engine, "Who joins on Friday?", to: project) == "Refused for the test.")

        let sent = transport.sent
        #expect(sent.map(\.method) == ["projects.set", "abort", "projects.startFresh", "submit"])
        #expect(sent[0].params["id"] as? String == "p-1")
        #expect((sent[0].params["settings"] as? [String: Any])?["wakeOnReports"] as? Bool == true)
        #expect(sent[1].params["id"] as? Int == 17)
        #expect(sent[2].params["id"] as? String == "p-1")
        #expect(sent[3].params["id"] as? Int == 9)
        #expect(sent[3].params["text"] as? String == "Who joins on Friday?")
        #expect(sent[3].params["mode"] as? String == "queue")

        // Taken, each answers nil.
        transport.refusal = nil
        #expect(await HubRequests.setWake(engine, project: "p-1", on: false) == nil)
        #expect(await HubRequests.stop(engine, conversation: 17) == nil)
    }

    @Test func aMessageToAProjectWithNoConversationIsNotSent() async throws {
        let transport = HubRecordingTransport(refusal: nil, conversation: nil)
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { session.engine.projects.count == 1 })
        let project = try #require(session.engine.projects.first)
        #expect(await HubRequests.message(session.engine, "Hello", to: project) != nil)
        #expect(transport.sent.isEmpty)
    }

    @Test func watchNamesTheNewestProjectWithATabShown() async throws {
        let transport = HubRecordingTransport(refusal: nil)
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { session.engine.status == .connected })
        let watch = HubTabWatch()

        watch.shows("a", tab: .now, engine: session.engine)
        #expect(watch.parameters["projectId"] as? String == "a")
        #expect(watch.parameters["tabs"] as? [String] == ["now"])
        watch.shows("b", tab: .now, engine: session.engine)
        #expect(watch.parameters["projectId"] as? String == "b")
        // The tab that goes after the next one came tells the engine what is left, rather than emptying the watch.
        watch.hides("a", tab: .now, engine: session.engine)
        #expect(watch.parameters["projectId"] as? String == "b")
        watch.hides("b", tab: .now, engine: session.engine)
        #expect(watch.parameters["projectId"] is NSNull)
        #expect(watch.parameters["tabs"] as? [String] == [])

        // Sent in the order made.
        #expect(try await eventually { transport.sent.count == 4 })
        #expect(transport.sent.allSatisfy { $0.method == "projects.watch" })
        #expect(transport.sent.map { $0.params["projectId"] as? String } == ["a", "b", "b", nil])
    }

    @Test func dashboardWatchesEveryProjectUntilOneIsChosen() async throws {
        let session = try await replaySession()
        let listed = session.engine.hubListedProjects
        let first = listed[0].id
        let second = listed[1].id

        let watched = DashboardWatched()
        #expect(watched.watched(listed).map(\.id) == [first, second])
        #expect(watched.watching(second, listed: listed))
        watched.toggle(first, listed: listed)
        #expect(watched.watched(listed).map(\.id) == [second])
        #expect(!watched.watching(first, listed: listed))
        watched.toggle(first, listed: listed)
        #expect(watched.watched(listed).map(\.id) == [first, second])

        // Opened at the project asked for when it has a page, else at the first.
        #expect(DashboardWatched.opening(second, in: listed) == second)
        #expect(DashboardWatched.opening(nil, in: listed) == first)
        #expect(DashboardWatched.opening("no-such-project", in: listed) == first)
        #expect(DashboardWatched.opening(nil, in: []) == nil)
    }
}

/// A stand-in for a Mac that sends one project, keeps every request a screen sends it, and answers each with `refusal` as the
/// engine's error, or with an empty result when it is nil.
@MainActor
final class HubRecordingTransport: EngineTransport {
    struct Request {
        let method: String
        let params: [String: Any]
    }

    var refusal: String?
    private(set) var sent: [Request] = []
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?
    private let events: Data

    init(refusal: String?, conversation: Int? = 9) {
        self.refusal = refusal
        let project: [String: Any] = [
            "id": "p-1", "name": "Hub test", "folder": NSNull(), "repository": NSNull(), "orchestratorId": "orchestrator-1",
            "conversation": conversation.map { $0 as Any } ?? NSNull(), "archivedAt": NSNull(), "deletedAt": NSNull(),
            "lastWords": NSNull(), "ruleTokens": NSNull(),
        ]
        var data = (try? JSONSerialization.data(withJSONObject: ["event": "projects", "projects": [project]])) ?? Data()
        data.append(0x0A)
        events = data
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        let events = events
        Task { @MainActor [weak self] in
            self?.handler?(.ready)
            self?.handler?(.received(events))
        }
    }

    func send(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        // What the session says by itself on connecting, which no screen sends, is answered and not kept.
        if method != "conversations.shown" {
            sent.append(Request(method: method, params: object["params"] as? [String: Any] ?? [:]))
        }
        let answer: [String: Any] = refusal.map { ["id": id, "error": $0] } ?? ["id": id, "result": [String: Any]()]
        var line = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        line.append(0x0A)
        Task { @MainActor [weak self] in self?.handler?(.received(line)) }
    }

    func cancel() {
        handler = nil
    }
}
