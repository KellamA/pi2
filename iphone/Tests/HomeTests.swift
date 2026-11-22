
import EngineKit
import Foundation
import PiModels
import Testing
@testable import pi2

/// The projects list (#685): its lists worked out from the recorded session, the connection bar's every state, search,
/// and the requests it makes, each as the Mac app makes it, with the engine's refusal kept to be shown.
@MainActor
struct HomeTests {
    /// Waits for `condition`, polling, for at most `seconds`.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func replay() async throws -> AppSession {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        #expect(try await eventually { session.engine.projects.count == 2 && session.engine.hasLoadedLibrary })
        return session
    }

    /// A session over `Scripted`, given the lines the engine would have sent, connected.
    private func scripted(_ lines: [String], answers: [String: String] = [:]) async throws -> (AppSession, Scripted) {
        let transport = Scripted(lines: lines, answers: answers)
        let session = AppSession()
        session.start(transport, as: .connected(.relay))
        #expect(try await eventually { session.engine.status == .connected && session.engine.hasLoadedLibrary })
        return (session, transport)
    }

    // MARK: The lists

    @Test func projectsAreTheSidebarsWithTheirBadges() async throws {
        let session = try await replay()
        let projects = HomeLists.projects(session.engine)
        #expect(projects.map(\.name) == ["Demo project", "Demo project 2"])
        let first = try #require(projects.first)
        // Two questions and an approval wait in each demo project (the recording's needs n1, n2 and 134).
        #expect(first.needs == session.engine.needs.count(where: { $0.projectId == first.id }))
        #expect(first.needs == 3)
        #expect(first.badge == .needs(3))
        #expect(first.working > 0)
        #expect(first.lastWords?.hasPrefix("Done.") == true)
        #expect(first.lastWordsAt != nil)
        #expect(first.conversation == 9)
        #expect(first.color == session.engine.agent(session.engine.projects[0].orchestratorId)?.color)
    }

    @Test func aBadgeSaysNeedsThenWorkingThenIdle() {
        func project(needs: Int, working: Int) -> HomeProject {
            HomeProject(id: "p", name: "P", color: nil, needs: needs, working: working, orchestratorWorking: false,
                        orchestratorWaiting: false, orchestratorAtLimit: false, lastWords: nil, lastWordsAt: nil,
                        conversation: nil, folderMissing: false)
        }
        #expect(project(needs: 2, working: 3).badge == .needs(2))
        #expect(project(needs: 0, working: 3).badge == .working(3))
        #expect(project(needs: 0, working: 0).badge == .idle)
    }

    @Test func archivedAndDeletedProjectsAreLeftOut() async throws {
        let (session, _) = try await scripted([
            Lines.library(conversations: [], archived: []),
            #"{"event":"projects","projects":[\#(Lines.project("p-1", "Kept")),\#(Lines.project("p-2", "Archived", archivedAt: 5)),\#(Lines.project("p-3", "Deleted", deletedAt: 6))],"carryOver":null}"#,
        ])
        #expect(try await eventually { session.engine.projects.count == 3 })
        #expect(HomeLists.projects(session.engine).map(\.name) == ["Kept"])
        #expect(HomeLists.archivedCount(session.engine) == 1)
    }

    @Test func chatsArePinnedFirstThenNewest() async throws {
        let (session, _) = try await scripted([
            Lines.library(conversations: [
                Lines.chat(1, "Old", updated: 100),
                Lines.chat(2, "Newest", updated: 300),
                Lines.chat(3, "Pinned and old", updated: 50, pinned: true),
                Lines.conversation(4, "An agent's", updated: 400),
                Lines.chat(5, "", updated: 200),
            ], archived: []),
        ])
        #expect(HomeLists.chats(session.engine.conversations).map(\.id) == [3, 2, 5, 1])
        // New Chat opens the untitled chat rather than making another, as on the Mac.
        #expect(HomeLists.emptyChat(session.engine.conversations)?.id == 5)
    }

    // MARK: The connection bar

    @Test func theBarSaysEachStateOfTheConnection() {
        typealias Reading = HomeConnectionBar.Reading
        let now = Date()
        #expect(Reading(.connected(.home), mac: "Studio Mac").line == "Studio Mac · at home")
        #expect(Reading(.connected(.relay), mac: "Studio Mac").line == "Studio Mac · through pi²'s relay")
        #expect(Reading(.connected(.direct), mac: "Studio Mac").line == "Studio Mac · direct")
        #expect(Reading(.connected(.home), mac: "Studio Mac").tone == .ok)
        let down = Reading(.connected(.home, relayReachable: false), mac: "Studio Mac")
        #expect(down.line == "Studio Mac · at home · relay unreachable")
        #expect(down.tone == .warn)
        #expect(down.title == "Relay unreachable · at home only")
        #expect(Reading(.connecting, mac: nil).line == "Reaching your Mac…")
        #expect(Reading(.connecting, mac: nil).tone == .busy)
        #expect(Reading(.demo, mac: nil).tone == .demo)
        #expect(Reading(.notPaired, mac: nil).line == "No Mac paired")
        let seen = Calendar.current.date(bySettingHour: 0, minute: 1, second: 0, of: now) ?? now
        let away = Reading(.outOfReach(lastSeen: seen), mac: "Studio Mac", now: now)
        #expect(away.line == "Studio Mac out of reach · last seen \(seen.formatted(date: .omitted, time: .shortened))")
        #expect(away.tone == .warn)
        #expect(Reading(.outOfReach(lastSeen: nil), mac: nil).line == "Your Mac out of reach")
        // Every state has something to say when tapped.
        let states: [AppSession.Connection] = [.notPaired, .demo, .connecting, .connected(.home), .connected(.relay), .connected(.direct),
                                               .connected(.home, relayReachable: false), .connected(.direct, relayReachable: false), .outOfReach(lastSeen: nil)]
        for state in states {
            #expect(!Reading(state, mac: "M").explanation.isEmpty, "\(state)")
        }
    }

    @Test func timesAreShortAsAListShowsThem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15)))
        let today = try #require(calendar.date(byAdding: .hour, value: -2, to: now))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let lastWeek = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let longAgo = try #require(calendar.date(byAdding: .day, value: -40, to: now))
        #expect(HomeTime.short(today, now: now, calendar: calendar) == today.formatted(date: .omitted, time: .shortened))
        #expect(HomeTime.short(yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(HomeTime.short(lastWeek, now: now, calendar: calendar) == lastWeek.formatted(.dateTime.weekday(.abbreviated)))
        #expect(HomeTime.short(longAgo, now: now, calendar: calendar) == longAgo.formatted(date: .numeric, time: .omitted))
        #expect(HomeTime.date(1_000) == Date(timeIntervalSince1970: 1))
    }

    // MARK: Search

    @Test func searchFindsNamesAsThePaletteDoes() async throws {
        let session = try await replay()
        #expect(HomeSearch.names("", in: session.engine).isEmpty)
        let projects = HomeSearch.names("demo project 2", in: session.engine).filter { $0.kind == .project }
        #expect(projects.map(\.title) == ["Demo project 2"])
        // A project's conversation is named by its project, and found by words of both in any order.
        let walk = HomeSearch.names("walkthrough", in: session.engine)
        #expect(walk.contains { $0.title == "Demo project › Put together a short walkthrough for Friday." && $0.route == .conversation(9) })
        #expect(HomeSearch.names("handoff 2 demo", in: session.engine).contains { $0.title == "Demo project 2 › Check the handoff" })
    }

    @Test func aRefusedMessageSearchIsShownNotTakenForNothingFound() async throws {
        let session = try await replay()
        let state = await HomeMessageSearch.search("walkthrough", in: session.engine)
        guard case .failed(let message) = state else {
            Issue.record("expected the recording's refusal, got \(state)")
            return
        }
        #expect(message.contains("does not answer search"))
    }

    @Test func messageSearchSendsTheMacsRequestAndListsItsResults() async throws {
        let (session, transport) = try await scripted([Lines.library(conversations: [], archived: [])], answers: [
            "search": #"{"results":[{"conversationId":9,"title":"Plan","entryId":41,"snippet":"the walkthrough on Friday","archived":true}]}"#,
        ])
        let state = await HomeMessageSearch.search("walkthrough", in: session.engine)
        #expect(state == .found([HomeSearch.Found(id: "m-41", kind: .message, title: "the walkthrough on Friday", detail: "In “Plan” · archived", route: .conversation(9))]))
        #expect(transport.sent.last?.method == "search")
        #expect(transport.sent.last?.params["query"] == .string("walkthrough"))

        let search = HomeMessageSearch()
        search.update("w", in: session.engine)
        #expect(search.state == .idle)
        search.update("walkthrough", in: session.engine, pause: .zero)
        #expect(try await eventually { if case .found = search.state { true } else { false } })
    }

    // MARK: Requests

    @Test func requestsAreTheMacsAndRefusalsAreKept() async throws {
        let (session, transport) = try await scripted([
            Lines.library(conversations: [Lines.chat(7, "Recipe", updated: 10)], archived: []),
            #"{"event":"projects","projects":[\#(Lines.project("p-1", "Kept"))],"carryOver":null}"#,
        ], answers: ["conversation.create": #"{"id":12}"#])
        let engine = session.engine
        #expect(try await eventually { !engine.projects.isEmpty })
        let project = try #require(HomeLists.projects(engine).first)
        let chat = try #require(engine.conversations.first)
        let actions = HomeActions()

        await actions.archive(project, in: engine)
        await actions.rename(project, to: "  Renamed ", in: engine)
        await actions.rename(project, to: "Kept", in: engine)  // the same name: nothing sent
        await actions.stopOrchestrator(of: project, in: engine)
        await actions.pin(chat, true, in: engine)
        await actions.archive(chat, in: engine)
        let made = await actions.newChat(in: engine)
        #expect(made == 12)
        #expect(transport.sent.map(\.method) == ["projects.archive", "projects.rename", "abort", "conversation.pin", "conversation.archive", "conversation.create"])
        #expect(transport.sent[1].params == ["id": .string("p-1"), "name": .string("Renamed")])
        #expect(transport.sent[2].params == ["id": .number(9)])
        #expect(transport.sent[3].params == ["id": .number(7), "pinned": .bool(true)])
        #expect(transport.sent[5].params == ["chat": .bool(true)])
        // Every one of them but conversation.create was refused by the script, and the last refusal is kept to show.
        #expect(actions.failure?.title == "The chat was not archived")
        #expect(actions.failure?.message.contains("conversation.archive") == true)
    }

    @Test func theRecordingRefusesTheListsRequestsAndTheListSaysSo() async throws {
        let session = try await replay()
        let project = try #require(HomeLists.projects(session.engine).first)
        let actions = HomeActions()
        await actions.archive(project, in: session.engine)
        #expect(actions.failure?.title == "The project was not archived")
        #expect(actions.failure?.message.contains("does not answer projects.archive") == true)
        #expect(await actions.newChat(in: session.engine) == nil)
        #expect(actions.failure?.title == "No chat was made")
    }
}

/// An engine that sends `lines` once ready, answers the methods in `answers` with their result, refuses every other
/// request, and keeps what it was sent; but `conversations.shown`, which the client sends by itself as it connects.
@MainActor
private final class Scripted: EngineTransport {
    struct Request: Decodable {
        let id: Int
        let method: String
        let params: [String: JSONValue]
    }

    let lines: [String]
    let answers: [String: String]
    private(set) var sent: [Request] = []
    private var handler: (@MainActor (EngineTransportEvent) -> Void)?

    init(lines: [String], answers: [String: String]) {
        self.lines = lines
        self.answers = answers
    }

    func start(_ handler: @escaping @MainActor (EngineTransportEvent) -> Void) {
        self.handler = handler
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        Task { @MainActor [weak self] in
            self?.handler?(.ready)
            self?.handler?(.received(data))
        }
    }

    func send(_ data: Data) {
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        if request.method != "conversations.shown" { sent.append(request) }
        let answers = self.answers.merging(["conversations.shown": "{}"]) { mine, _ in mine }
        let reply = answers[request.method].map { #"{"id":\#(request.id),"result":\#($0)}"# }
            ?? #"{"id":\#(request.id),"error":"The script does not answer \#(request.method)."}"#
        Task { @MainActor [weak self] in self?.handler?(.received(Data((reply + "\n").utf8))) }
    }

    func cancel() {
        handler = nil
    }
}

/// Lines of the engine's events, as it sends them.
private enum Lines {
    static func library(conversations: [String], archived: [String]) -> String {
        #"{"event":"library","conversations":[\#(conversations.joined(separator: ","))],"archived":[\#(archived.joined(separator: ","))]}"#
    }

    static func chat(_ id: Int, _ title: String, updated: Double, pinned: Bool = false) -> String {
        #"{"id":\#(id),"title":"\#(title)","updatedAt":\#(updated),"busy":false,"agentId":null,"createdAt":1,"parent":null,"chat":true,"pinned":\#(pinned)}"#
    }

    static func conversation(_ id: Int, _ title: String, updated: Double) -> String {
        #"{"id":\#(id),"title":"\#(title)","updatedAt":\#(updated),"busy":false,"agentId":"a","createdAt":1,"parent":null}"#
    }

    static func project(_ id: String, _ name: String, archivedAt: Double? = nil, deletedAt: Double? = nil) -> String {
        let archived = archivedAt.map { String($0) } ?? "null"
        let deleted = deletedAt.map { String($0) } ?? "null"
        return #"{"id":"\#(id)","name":"\#(name)","folder":null,"repository":null,"orchestratorId":"o","conversation":9,"archivedAt":\#(archived),"deletedAt":\#(deleted),"lastWords":{"text":"Hello","at":1000}}"#
    }
}
