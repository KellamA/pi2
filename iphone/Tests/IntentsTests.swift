
import AppIntents
import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// The intents for Shortcuts and Siri (#701, `Intents/`): each one's `perform()` and what it says in each state, against
/// the recorded session and against stand-ins for a Mac that answers and for the Outbox while the Mac is out of reach.
/// The Shortcuts app itself cannot be driven from a test; these call what it calls.
@MainActor
@Suite(.serialized)
struct IntentsTests {
    private static let demo = "p-bae6908c-84e6-4971-94f5-3a00f06625da"

    /// Waits for `condition`, polling, for at most `seconds`.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A session over `transport`, registered for the intents, with its projects in.
    private func session(_ transport: any EngineTransport, as connection: AppSession.Connection, isOpen: (@MainActor () -> Bool)? = nil) async throws -> AppSession {
        let session = AppSession()
        session.start(transport, as: connection)
        IntentSessions.register(session, isOpen: isOpen)
        IntentSessions.prompts = IntentSessions.Prompts(confirm: { _ in }, foreground: { _ in })
        IntentRun.lastProject = nil
        #expect(try await eventually { session.engine.projects.count == 2 && session.engine.hasLoadedLibrary })
        return session
    }

    private func project(_ session: AppSession, _ name: String = "Demo project") throws -> ProjectRowForTest {
        let row = try #require(session.engine.projects.first { $0.name == name })
        return ProjectRowForTest(row: row, entity: IntentProject(row))
    }

    struct ProjectRowForTest {
        let row: ProjectRow
        let entity: IntentProject
    }

    // MARK: - Every intent

    @Test func everyIntentNeedsAnUnlockedPhone() {
        #expect(AskOrchestratorIntent.authenticationPolicy == .requiresAuthentication)
        #expect(WhatNeedsMeIntent.authenticationPolicy == .requiresAuthentication)
        #expect(StopProjectIntent.authenticationPolicy == .requiresAuthentication)
        #expect(PiShortcuts.appShortcuts.count == 3)
    }

    @Test func theProjectQueryReadsTheSessionsProjects() async throws {
        let session = try await session(try #require(ReplayTransport.recording()), as: .connected(.home))
        let query = IntentProjectQuery()
        #expect(try await query.suggestedEntities().map(\.name).sorted() == ["Demo project", "Demo project 2"])
        #expect(try await query.entities(matching: "project 2").map(\.name) == ["Demo project 2"])
        #expect(try await query.entities(for: [Self.demo, "p-gone"]).map(\.name) == ["Demo project"])
        _ = session
    }

    // MARK: - Against the recorded session: reads answer, writes are refused

    @Test func whatNeedsMeReadsTheRecordedNeeds() async throws {
        let session = try await session(try #require(ReplayTransport.recording()), as: .connected(.home))
        let all = WhatNeedsMe.list(session: session, project: nil, reach: .connected(outOfReach: false))
        #expect(all.lines.count == 6)
        #expect(all.dialog.hasPrefix("6 things need you. Orchestrator asks: Who should join the Friday walkthrough? Orchestrator asks: Which preview layout should we show? Beacon asks for approval: /usr/bin/true."))
        #expect(all.dialog.hasSuffix("And 3 more in pi²."))
        #expect(all.lines.first?.place.hasPrefix("in Demo project") == true)

        let demo = try project(session)
        let one = WhatNeedsMe.list(session: session, project: demo.row, reach: .connected(outOfReach: false))
        #expect(one.lines.count == 3)
        #expect(one.dialog.hasPrefix("3 things need you in Demo project."))

        // The intent itself, as Shortcuts runs it.
        _ = try await WhatNeedsMeIntent(project: demo.entity).perform()
        _ = try await WhatNeedsMeIntent(project: nil).perform()
    }

    @Test func askSaysTheRecordingRefusedTheMessage() async throws {
        let session = try await session(try #require(ReplayTransport.recording()), as: .connected(.home))
        let demo = try project(session)
        let reply = await AskOrchestrator.ask("Who is on call?", of: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(reply.outcome == .notSent)
        #expect(reply.dialog == "Not sent to Demo project’s orchestrator: The recorded session (PI2_TRANSPORT=replay) does not answer submit.")
        _ = try await AskOrchestratorIntent(message: "Who is on call?", project: demo.entity).perform()
    }

    @Test func stopSaysTheRecordingRefusedEachStop() async throws {
        let session = try await session(try #require(ReplayTransport.recording()), as: .connected(.home))
        let demo = try project(session)
        let runs = StopProject.runs(in: demo.row, session: session)
        #expect(runs.map(\.conversationId) == [17, 23, 29])
        #expect(StopProject.question(runs, in: demo.row, session: session).hasPrefix("Stop 3 runs in Demo project?"))
        let reply = await StopProject.stop(runs, in: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(reply.refused == 3 && reply.stopped == 0)
        #expect(reply.dialog == "Couldn’t stop the runs in Demo project: The recorded session (PI2_TRANSPORT=replay) does not answer abort.")

        var asked: [String] = []
        IntentSessions.prompts = IntentSessions.Prompts(confirm: { asked.append($0) }, foreground: { _ in })
        _ = try await StopProjectIntent(project: demo.entity).perform()
        #expect(asked.count == 1)
        #expect(asked.first?.hasPrefix("Stop 3 runs in Demo project?") == true)
    }

    @Test func aProjectIsAskedForWhenSeveralCouldBeMeant() async throws {
        _ = try await session(try #require(ReplayTransport.recording()), as: .connected(.home))
        await #expect(throws: (any Error).self) { _ = try await StopProjectIntent(project: nil).perform() }
        await #expect(throws: (any Error).self) { _ = try await AskOrchestratorIntent(message: "Hello", project: nil).perform() }
    }

    // MARK: - A Mac that answers

    @Test func askGivesTheOrchestratorsAnswer() async throws {
        let mac = StandInMac(answer: "Dana is on call this week.")
        let session = try await session(mac, as: .connected(.relay))
        let demo = try project(session)
        let reply = await AskOrchestrator.ask("Who is on call?", of: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(reply.outcome == .answered)
        #expect(reply.answer == "Dana is on call this week.")
        #expect(reply.dialog == "Dana is on call this week.")
        #expect(mac.sent.contains { $0.method == "submit" && $0.params["id"] as? Int == 9 && $0.params["mode"] as? String == "queue" })
        // The last one asked is asked again when none is named.
        #expect(IntentRun.lastProject == Self.demo)
        if case .project(let row) = IntentRun.project(nil, in: session, orLast: true) { #expect(row.id == Self.demo) } else { Issue.record("no project") }
    }

    @Test func askSaysTheAnswerWillBeInPiWhenItIsLate() async throws {
        let mac = StandInMac(answer: nil)
        let session = try await session(mac, as: .connected(.home))
        let demo = try project(session)
        AskOrchestrator.answerWait = .milliseconds(300)
        defer { AskOrchestrator.answerWait = .seconds(20) }
        let reply = await AskOrchestrator.ask("Who is on call?", of: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(reply.outcome == .stillWorking)
        #expect(reply.dialog == "Sent to Demo project’s orchestrator. It’s still working on the answer, which will be in pi².")
    }

    @Test func stopSendsAbortForEachRunTopsFirst() async throws {
        let mac = StandInMac(answer: nil)
        let session = try await session(mac, as: .connected(.home))
        let demo = try project(session)
        let reply = await StopProject.stop(StopProject.runs(in: demo.row, session: session), in: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(reply.stopped == 3)
        #expect(reply.dialog == "Stopped 3 runs in Demo project. Each conversation stays as it is and can be continued.")
        #expect(mac.sent.filter { $0.method == "abort" }.compactMap { $0.params["id"] as? Int } == [17, 23, 29])
    }

    // MARK: - The demo mode

    @Test func theDemoAnswersEachIntent() async throws {
        // The demo's transport as `DemoMode.start` makes it, without the shared `DemoMode`, which DemoTests use beside these.
        let transport = try #require(DemoTransport.recorded())
        let session = AppSession()
        session.start(transport, as: .demo)
        defer { transport.close() }
        IntentSessions.register(session)
        IntentSessions.prompts = IntentSessions.Prompts(confirm: { _ in }, foreground: { _ in })
        #expect(try await eventually { !session.engine.projects.isEmpty && session.engine.hasLoadedLibrary })
        #expect(await IntentSessions.reach(session) == .connected(outOfReach: false))
        let row = try #require(IntentProject.all(in: session).first { $0.conversation != nil })

        let ask = await AskOrchestrator.ask("Who is on call?", of: row, session: session, courier: EngineCourier(session: session))
        #expect(ask.outcome == .answered)
        #expect(ask.answer?.hasPrefix("You said: \"Who is on call?\". I am the demo model") == true)

        let needs = WhatNeedsMe.list(session: session, project: nil, reach: .connected(outOfReach: false))
        #expect(needs.lines.count == session.engine.needs.count)
        #expect(!needs.lines.isEmpty)

        let runs = StopProject.runs(in: row, session: session)
        let stop = await StopProject.stop(runs, in: row, session: session, courier: EngineCourier(session: session))
        #expect(stop.refused == 0)
        #expect(stop.stopped == runs.count)

        _ = try await AskOrchestratorIntent(message: "Hello", project: IntentProject(row)).perform()
        _ = try await WhatNeedsMeIntent(project: nil).perform()
        _ = try await StopProjectIntent(project: IntentProject(row)).perform()
    }

    // MARK: - Not paired, out of reach, locked

    @Test func notPairedSaysSo() async throws {
        let session = AppSession(connection: .notPaired)
        IntentSessions.register(session)
        #expect(await IntentSessions.reach(session) == .notPaired)
        _ = try await WhatNeedsMeIntent(project: nil).perform()
        #expect(IntentRun.words(for: .notPaired, unreachable: "") == IntentWords.notPaired)
    }

    @Test func outOfReachWithNothingToKeepItSaysNothingWasSent() async throws {
        let session = AppSession(connection: .outOfReach(lastSeen: nil))
        IntentSessions.register(session)
        #expect(await IntentSessions.reach(session) == .unreachable)
        let reply = await EngineCourier(session: session).request("abort", ["id": 17])
        #expect(reply == .unreachable(IntentWords.unreachableNotSent))
        _ = try await AskOrchestratorIntent(message: "Hello", project: IntentProject(id: Self.demo, name: "Demo project")).perform()
    }

    @Test func outOfReachTheMessageAndTheStopWaitInTheMailbox() async throws {
        let lastSeen = Date(timeIntervalSinceNow: -40 * 60)
        let outbox = StandInOutbox()
        let session = try await session(outbox, as: .outOfReach(lastSeen: lastSeen))
        #expect(await IntentSessions.reach(session) == .connected(outOfReach: true))
        let demo = try project(session)
        let away = IntentWords.away(lastSeen)
        #expect(away.hasPrefix("Your Mac has been asleep or out of reach since "))

        let ask = await AskOrchestrator.ask("Who is on call?", of: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(ask.outcome == .kept)
        #expect(ask.dialog == "\(away), so your message to Demo project’s orchestrator waits in the mailbox and goes to it when your Mac wakes. The answer will come later, in pi².")

        let stop = await StopProject.stop(StopProject.runs(in: demo.row, session: session), in: demo.row, session: session, courier: EngineCourier(session: session))
        #expect(stop.kept == 3)
        #expect(stop.dialog == "\(away), so the stop for 3 runs waits in the mailbox and reaches it when it wakes.")
        #expect(outbox.kept.map(\.method) == ["submit", "abort", "abort", "abort"])

        let needs = WhatNeedsMe.list(session: session, project: demo.row, reach: .connected(outOfReach: true))
        #expect(needs.dialog.hasPrefix("\(away). When it was last heard from, 3 things need you in Demo project."))
        #expect(needs.asOf == "\(away). This is what it last sent.")
    }

    @Test func lockedOpensPiForFaceIDFirst() async throws {
        var open = false
        let session = try await session(try #require(ReplayTransport.recording()), as: .connected(.home), isOpen: { open })
        var asked: [String] = []
        IntentSessions.prompts = IntentSessions.Prompts(confirm: { _ in }, foreground: { asked.append($0); open = true })
        _ = try await WhatNeedsMeIntent(project: nil).perform()
        #expect(asked == [IntentWords.unlock])

        // Unlocked already: nothing is asked.
        _ = try await WhatNeedsMeIntent(project: nil).perform()
        #expect(asked.count == 1)
        _ = session
    }
}

// MARK: - Stand-ins

/// A Mac that answers: the recording's state, then `submit` taken and, when `answer` is given, the orchestrator's
/// answer arriving as the engine sends a conversation's new entries; `abort` taken.
@MainActor
final class StandInMac: EngineTransport {
    struct Sent {
        let method: String
        let params: [String: Any]
    }

    private let replay = ReplayTransport.recording()!
    private let answer: String?
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?
    private(set) var sent: [Sent] = []

    init(answer: String?) {
        self.answer = answer
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        replay.start(handler)
    }

    func send(_ data: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, let method = request["method"] as? String else { return }
        let params = request["params"] as? [String: Any] ?? [:]
        sent.append(Sent(method: method, params: params))
        switch method {
        case "submit":
            var reply = line(["id": id, "result": ["submissionId": 1]])
            if let answer, let conversation = params["id"] as? Int, let text = params["text"] as? String,
               let entries = entries(conversation, { [["id": $0 + 1, "kind": "user", "text": text], ["id": $0 + 2, "kind": "assistant", "text": answer, "stop": "stop"]] }) {
                reply.append(entries)
            }
            Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
        case "abort":
            let reply = line(["id": id, "result": [String: Any]()])
            Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
        default:
            replay.send(data)
        }
    }

    func cancel() {
        handler = nil
        replay.cancel()
    }

    /// The conversation's last recorded event, as an update adding the entries `items` makes after the newest entry
    /// recorded, its run over.
    private func entries(_ conversation: Int, _ items: (_ after: Int) -> [[String: Any]]) -> Data? {
        guard let url = Bundle.main.url(forResource: "session", withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var last: [String: Any]?
        var newest = 0
        for raw in text.split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  event["event"] as? String == "conversation", event["id"] as? Int == conversation else { continue }
            last = event
            for item in event["items"] as? [[String: Any]] ?? [] { newest = max(newest, item["id"] as? Int ?? 0) }
        }
        guard var event = last, var state = event["state"] as? [String: Any] else { return nil }
        state["busy"] = false
        event["state"] = state
        event["reset"] = false
        event["items"] = items(newest)
        return line(event)
    }

    private func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// The phone's store standing in for an out-of-reach Mac, as #692's `CachedTransport` does: the last state (here the
/// recording's), and every write kept in the Outbox and answered `{ "outbox": <id> }`.
@MainActor
final class StandInOutbox: EngineTransport {
    private let replay = ReplayTransport.recording()!
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?
    private(set) var kept: [StandInMac.Sent] = []

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        replay.start(handler)
    }

    func send(_ data: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, let method = request["method"] as? String else { return }
        switch method {
        case "submit", "abort":
            kept.append(StandInMac.Sent(method: method, params: request["params"] as? [String: Any] ?? [:]))
            var reply = (try? JSONSerialization.data(withJSONObject: ["id": id, "result": ["outbox": "item-\(kept.count)"]])) ?? Data()
            reply.append(0x0A)
            Task { @MainActor [weak self] in self?.handler?(.received(reply)) }
        default:
            replay.send(data)
        }
    }

    func cancel() {
        handler = nil
        replay.cancel()
    }
}
