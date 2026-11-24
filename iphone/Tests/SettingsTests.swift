import Foundation
import PiModels
import Testing
@testable import pi2

/// Settings, a project's settings and limits, and schedules (#697): the requests each control makes, as the Mac makes
/// them; where the contract's table puts each (docs/iphone.md 4.2); the readings of the engine's events; the schedules'
/// places and words; and the recorded session's answers, refused and shown rather than pretended.
@MainActor
struct SettingsTests {
    /// A request's parameters as JSON with sorted keys, to compare with what the Mac sends.
    private func json(_ request: SettingsRequest) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: request.params, options: [.sortedKeys]), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private func agent(_ id: String, _ name: String, project: String?, createdAt: Double = 1, removed: Bool = false) throws -> AgentProfile {
        let projectField = project.map { "\"\($0)\"" } ?? "null"
        return try decode(AgentProfile.self, """
        {"id":"\(id)","name":"\(name)","description":"","color":"blue","instructions":"","access":"ask","delegates":[],"createdAt":\(createdAt),
         "projectId":\(projectField)\(removed ? ",\"removedAt\":5" : "")}
        """)
    }

    private func project(_ id: String, _ name: String, orchestrator: String, deleted: Bool = false) throws -> ProjectRow {
        try decode(ProjectRow.self, """
        {"id":"\(id)","name":"\(name)","folder":"/demo/\(id)","repository":null,"orchestratorId":"\(orchestrator)","conversation":9,
         "archivedAt":null,"deletedAt":\(deleted ? "7" : "null"),"ruleTokens":null,
         "settings":{"wakeOnReports":false,"withoutAsking":{"merge":false},"limits":{"planShare":90,"dailySpend":null}}}
        """)
    }

    private func schedule(_ id: String, agent: String, kind: String = "daily", enabled: Bool = true, hold: String? = nil, next: Double? = nil,
                          copy: String? = nil, last: Int? = nil) -> Schedule {
        Schedule(id: id, title: "Brief \(id)", agentId: agent, prompt: "Say what needs me.", repeat: Repeat(kind: kind, hour: 7, minute: 30),
                 enabled: enabled, holdReason: hold, nextRunAt: next, lastConversationId: last, projectAgentId: copy)
    }

    // MARK: - The requests, as the Mac makes them

    @Test func aProjectsSettingsAreSentAsItsSettingsTabSendsThem() throws {
        let cases: [(SettingsRequest, String, String)] = [
            (.rename(project: "p", to: "Site"), "projects.rename", #"{"id":"p","name":"Site"}"#),
            (.wakeOnReports(project: "p", on: true), "projects.set", #"{"id":"p","settings":{"wakeOnReports":true}}"#),
            (.withoutAsking(project: "p", "merge", on: true), "projects.set", #"{"id":"p","settings":{"withoutAsking":{"merge":true}}}"#),
            (.planShare(project: "p", 80), "projects.set", #"{"id":"p","settings":{"limits":{"planShare":80}}}"#),
            (.planShare(project: "p", nil), "projects.set", #"{"id":"p","settings":{"limits":{"planShare":null}}}"#),
            (.dailySpend(project: "p", 2.5), "projects.set", #"{"id":"p","settings":{"limits":{"dailySpend":2.5}}}"#),
            (.dailySpend(project: "p", nil), "projects.set", #"{"id":"p","settings":{"limits":{"dailySpend":null}}}"#),
            (.attach(project: "p", repository: "demo/site"), "github.attach", #"{"projectId":"p","repository":"demo\/site"}"#),
            (.attach(project: "p", repository: nil), "github.attach", #"{"projectId":"p"}"#),
            (.detach(project: "p"), "github.detach", #"{"projectId":"p"}"#),
            (.archive(project: "p"), "projects.archive", #"{"id":"p"}"#),
            (.restore(project: "p"), "projects.unarchive", #"{"id":"p"}"#),
            (.delete(project: "p"), "projects.delete", #"{"id":"p"}"#),
        ]
        for (request, method, params) in cases {
            #expect(request.method == method)
            #expect(try json(request) == params, "\(method)")
        }
    }

    @Test func theOrchestratorsAgentIsSavedWithOnlyWhatChanged() throws {
        let orchestrator = try agent("o", "Orchestrator", project: "p")
        let model = SettingsRequest.agentModel(orchestrator, ModelRef(provider: "demo", modelId: "demo-1"))
        #expect(model.method == "agents.save")
        #expect(try json(model) == #"{"agent":{"id":"o","model":{"modelId":"demo-1","provider":"demo"},"name":"Orchestrator"}}"#)
        #expect(try json(.agentCompaction(orchestrator, nil)) == #"{"agent":{"compactionTokens":null,"id":"o","name":"Orchestrator"}}"#)
        #expect(try json(.agentCompaction(orchestrator, 0)) == #"{"agent":{"compactionTokens":0,"id":"o","name":"Orchestrator"}}"#)
    }

    @Test func theAppsSettingsAreSentAsTheMacsSettingsSendThem() throws {
        let cases: [(SettingsRequest, String, String)] = [
            (.awake(keep: true, battery: false), "settings.setAwake", #"{"battery":false,"keep":true}"#),
            (.autoArchive(days: 30), "settings.setAutoArchive", #"{"days":30}"#),
            (.autoArchive(days: 0), "settings.setAutoArchive", #"{"days":null}"#),
            (.autoArchive(days: nil), "settings.setAutoArchive", #"{"days":null}"#),
            (.compaction(200_000), "settings.setCompaction", #"{"defaultCompactionTokens":200000}"#),
            (.compaction(nil), "settings.setCompaction", #"{"defaultCompactionTokens":null}"#),
            (.coauthor(enabled: true), "coauthor.set", #"{"enabled":true}"#),
            (.coauthor(line: "Co-authored-by: x"), "coauthor.set", #"{"line":"Co-authored-by: x"}"#),
            (.chatInstructions("Be brief."), "chat.set", #"{"instructions":"Be brief."}"#),
            (.chatModel(nil), "chat.set", #"{"defaultModel":null}"#),
            (.chatModel(ModelRef(provider: "demo", modelId: "demo-1")), "chat.set", #"{"defaultModel":{"modelId":"demo-1","provider":"demo"}}"#),
            (.chatWeb(false), "chat.set", #"{"web":false}"#),
            (.chatMemory(true), "chat.set", #"{"memory":true}"#),
        ]
        for (request, method, params) in cases {
            #expect(request.method == method)
            #expect(try json(request) == params, "\(method)")
        }
    }

    @Test func schedulesAreSavedRunAndDeletedAsTheMacsListDoes() throws {
        let saved = schedule("s1", agent: "forge")
        #expect(try json(.saveSchedule(saved, isNew: true))
            == #"{"schedule":{"agentId":"forge","enabled":true,"prompt":"Say what needs me.","repeat":{"hour":7,"kind":"daily","minute":30},"title":"Brief s1"}}"#)
        #expect(try json(.saveSchedule(saved, isNew: false)).contains(#""id":"s1""#))
        let off = SettingsRequest.setSchedule(saved, enabled: false)
        #expect(off.method == "schedules.save")
        #expect(try json(off).contains(#""enabled":false"#))
        #expect(try json(off).contains(#""id":"s1""#))
        #expect(SettingsRequest.runSchedule("s1").method == "schedules.runNow")
        #expect(try json(.runSchedule("s1")) == #"{"id":"s1"}"#)
        #expect(SettingsRequest.deleteSchedule("s1").method == "schedules.delete")
    }

    // MARK: - What a phone may send (docs/iphone.md 4.2)

    @Test func everyChangeTheseScreensSendIsOneAPhoneMaySend() throws {
        let orchestrator = try agent("o", "Orchestrator", project: "p")
        let sent: [SettingsRequest] = [
            .rename(project: "p", to: "x"), .wakeOnReports(project: "p", on: true), .withoutAsking(project: "p", "merge", on: true),
            .planShare(project: "p", 80), .dailySpend(project: "p", 5), .attach(project: "p", repository: nil), .detach(project: "p"),
            .archive(project: "p"), .restore(project: "p"), .delete(project: "p"),
            .agentModel(orchestrator, ModelRef(provider: "demo", modelId: "demo-1")), .agentCompaction(orchestrator, nil),
            .awake(keep: true, battery: true), .autoArchive(days: 7), .compaction(nil), .coauthor(enabled: true), .coauthor(line: "x"),
            .chatInstructions("x"), .chatModel(nil), .chatWeb(true), .chatMemory(false),
            .saveSchedule(schedule("s", agent: "o"), isNew: true), .runSchedule("s"), .deleteSchedule("s"),
        ]
        for request in sent {
            #expect(SettingsReach.of(request.method, request.params) != .mac, "\(request.method) is the Mac's alone")
        }
    }

    @Test func whatWidensIsToldApartFromWhatNarrows() throws {
        #expect(SettingsReach.of("projects.set") == .widens)
        #expect(SettingsReach.of("schedules.save") == .widens)
        #expect(SettingsReach.of("agents.save") == .widens)
        #expect(SettingsReach.of("projects.delete") == .widens)
        #expect(SettingsReach.of("github.attach") == .widens)
        #expect(SettingsReach.of("projects.archive") == .phone)
        #expect(SettingsReach.of("schedules.delete") == .phone)
        #expect(SettingsReach.of("schedules.runNow", ["id": "s"]) == .phone)
        #expect(SettingsReach.of("schedules.runNow", ["id": "s", "confirmLimit": true]) == .widens)
        let chat = { (request: SettingsRequest) in SettingsReach.of(request.method, request.params) }
        #expect(chat(.chatModel(nil)) == .phone)
        #expect(chat(.chatWeb(false)) == .phone)
        #expect(chat(.chatMemory(false)) == .phone)
        #expect(chat(.chatWeb(true)) == .widens)
        #expect(chat(.chatMemory(true)) == .widens)
        #expect(chat(.chatInstructions("x")) == .widens)
    }

    @Test func whatStaysOnTheMacIsNeverOffered() {
        for method in ["providers.setKey", "auth.login", "variables.set", "endpoints.save", "mcp.save", "local.install", "computer.enable",
                       "browser.open", "pictures.setModel", "look.setModel", "priority.set", "backup.create", "settings.finishOnboarding",
                       "devices.pairStart", "settings.setAgentDefault", "test-copy.anything"] {
            #expect(SettingsReach.of(method) == .mac, "\(method)")
        }
        #expect(SettingsReach.of("agents.allowEverything", ["on": true]) == .mac)
        #expect(SettingsReach.of("agents.allowEverything", ["on": false]) == .phone)
        #expect(SettingsReach.onTheMac.contains { $0.title.hasPrefix("Providers") })
        #expect(SettingsReach.onTheMac.contains { $0.title.hasPrefix("Allow everything") })
    }

    // MARK: - Limits typed in

    @Test func aPlanLimitIsAWholePercentOrNone() {
        #expect(SettingsLimitInput.planShare("") == .success(nil))
        #expect(SettingsLimitInput.planShare(" 80 ") == .success(80))
        #expect(SettingsLimitInput.planShare("80%") == .success(80))
        #expect(SettingsLimitInput.planShare("100") == .success(100))
        for refused in ["0", "101", "8.5", "a lot"] {
            #expect((try? SettingsLimitInput.planShare(refused).get()) == nil, "\(refused)")
        }
    }

    @Test func aDailyLimitIsAnAmountAboveZeroOrNone() {
        #expect(SettingsLimitInput.dailySpend("") == .success(nil))
        #expect(SettingsLimitInput.dailySpend("$5") == .success(5))
        #expect(SettingsLimitInput.dailySpend("2,50") == .success(2.5))
        for refused in ["0", "-1", "five", "inf"] {
            #expect((try? SettingsLimitInput.dailySpend(refused).get()) == nil, "\(refused)")
        }
        #expect(SettingsLimitInput.text(5) == "5")
        #expect(SettingsLimitInput.text(2.5) == "2.5")
        #expect(SettingsLimitInput.text(nil) == "")
    }

    // MARK: - The engine's events, read

    @Test func eachSettingIsUnknownUntilItsEventCame() {
        #expect(SettingsAwake(nil) == nil)
        #expect(SettingsCoauthor(nil) == nil)
        #expect(SettingsChat(nil) == nil)
        #expect(SettingsCompaction(nil) == nil)
        #expect(SettingsAgentDefault(nil) == nil)
    }

    @Test func eventsAreReadAsTheMacReadsThem() throws {
        let awake = try decode(JSONValue.self, #"{"event":"awake","keep":false,"battery":true,"holding":false}"#)
        #expect(SettingsAwake(awake) == SettingsAwake(keep: false, battery: true))
        let coauthor = try decode(JSONValue.self, #"{"enabled":true,"line":"Co-authored-by: x","defaultLine":"Co-authored-by: y"}"#)
        #expect(SettingsCoauthor(coauthor) == SettingsCoauthor(enabled: true, line: "Co-authored-by: x", defaultLine: "Co-authored-by: y"))
        let chat = try decode(JSONValue.self, #"{"instructions":"Be brief.","defaultModel":{"provider":"demo","modelId":"demo-1"},"web":false,"memory":true}"#)
        #expect(SettingsChat(chat) == SettingsChat(instructions: "Be brief.", defaultModel: ModelRef(provider: "demo", modelId: "demo-1"), web: false, memory: true))
        #expect(SettingsCompaction(try decode(JSONValue.self, #"{"defaultCompactionTokens":200000}"#))?.tokens == 200_000)
        #expect(SettingsCompaction(try decode(JSONValue.self, #"{"defaultCompactionTokens":null}"#)) == SettingsCompaction(tokens: nil))
        let agentDefault = try decode(JSONValue.self, #"{"model":null,"using":{"provider":"demo","modelId":"demo-1"},"fellBack":false}"#)
        #expect(SettingsAgentDefault(agentDefault) == SettingsAgentDefault(model: nil, using: ModelRef(provider: "demo", modelId: "demo-1")))
    }

    @Test func thePlanLimitCountsTheMostUsedWindowNotYetReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let limits = try decode(JSONValue.self, """
        {"providers":[{"id":"anthropic","name":"Anthropic","plan":"Max","reports":"usage","windows":[
          {"id":"5h","label":"5 hours","usedPercent":97,"resetsAt":\(ms - 60_000)},
          {"id":"week","label":"week","usedPercent":41.4,"resetsAt":\(ms + 86_400_000)}]},
         {"id":"openai","name":"OpenAI","reports":"none"}],"notices":[]}
        """)
        let windows = SettingsPlanWindow.read(limits)
        #expect(windows.count == 2)
        let top = try #require(SettingsPlanWindow.mostUsed(windows, at: now))
        #expect(top.label == "week")
        #expect(top.line(at: now).hasPrefix("Anthropic Max, week: 41% used, resets "))
        #expect(SettingsPlanWindow.mostUsed([], at: now) == nil)
    }

    @Test func autoArchiveAndSummaryChoicesKeepWhatIsSet() {
        #expect(SettingsAutoArchive.choices(including: nil) == [7, 30, 90, 365])
        #expect(SettingsAutoArchive.choices(including: 14) == [7, 14, 30, 90, 365])
        #expect(SettingsAutoArchive.label(nil) == "Never")
        #expect(SettingsAutoArchive.label(30) == "A month")
        #expect(SettingsAutoArchive.label(14) == "14 days")
        #expect(SettingsCompaction.choices(including: 150_000).contains(150_000))
        #expect(SettingsCompaction.choices(including: 0) == SettingsCompaction.choices(including: nil))
    }

    @Test func moneyReadsAsUsageShowsIt() {
        #expect(SettingsMoney.text(0) == "$0")
        #expect(SettingsMoney.text(3.42) == "$3.42")
        #expect(SettingsMoney.text(0.004) == "less than $0.01")
    }

    // MARK: - Schedules

    @Test func aScheduleBelongsToTheProjectOfTheAgentItRunsAs() throws {
        let agents = [
            try agent("o1", "Orchestrator", project: "p1", createdAt: 5),
            try agent("forge1", "Forge", project: "p1", createdAt: 1),
            try agent("forge", "Forge", project: nil),
            try agent("gone", "Gone", project: "p1", removed: true),
        ]
        let projects = [try project("p1", "Site", orchestrator: "o1")]
        let book = ScheduleBook(
            schedules: [
                schedule("own", agent: "o1"),
                schedule("carried", agent: "forge", copy: "forge1"),
                schedule("template", agent: "forge"),
                schedule("removedCopy", agent: "forge", copy: "gone"),
            ],
            agents: agents, projects: projects, conversations: [9]
        )
        #expect(book.runsAs(book.schedules[1]) == "forge1")
        #expect(book.runsAs(book.schedules[3]) == "forge")
        #expect(book.schedules(ofProject: "p1").map(\.id) == ["own", "carried"])
        #expect(book.groups.map(\.title) == ["Site", "Templates"])
        #expect(book.groups.last?.schedules.map(\.id) == ["template", "removedCopy"])
        // The orchestrator first, then the rest as made; a removed agent is offered to nobody.
        #expect(book.agents(ofProject: "p1").map(\.id) == ["o1", "forge1"])
        #expect(book.everyAgent.map(\.id) == ["o1", "forge1", "forge"])
    }

    @Test func aDeletedProjectsCopyGivesTheScheduleBackToItsTemplate() throws {
        let book = ScheduleBook(
            schedules: [schedule("carried", agent: "forge", copy: "forge1")],
            agents: [try agent("forge1", "Forge", project: "p1"), try agent("forge", "Forge", project: nil)],
            projects: [try project("p1", "Site", orchestrator: "o1", deleted: true)], conversations: []
        )
        #expect(book.runsAs(book.schedules[0]) == "forge")
        #expect(book.groups.map(\.title) == ["Templates"])
    }

    @Test func aRowSaysWhoRunsItWhenAndWhyItIsHeld() throws {
        let agents = [try agent("o1", "Orchestrator", project: "p1"), try agent("scout", "Scout", project: "p1")]
        var bySomeone = schedule("a", agent: "scout", next: 1_795_400_000_000)
        bySomeone.createdBy = try decode(Schedule.Creator.self, #"{"agentId":"o1","conversationId":9}"#)
        let book = ScheduleBook(
            schedules: [schedule("held", agent: "o1", hold: "the daily limit is reached"), schedule("off", agent: "o1", enabled: false), bySomeone],
            agents: agents, projects: [try project("p1", "Site", orchestrator: "o1")], conversations: [9]
        )
        #expect(book.detail(book.schedules[0]) == "Orchestrator · Held: the daily limit is reached")
        #expect(book.detail(book.schedules[1]) == "Orchestrator · Every day at 07:30 · off")
        #expect(book.detail(book.schedules[2]).hasPrefix("Scout · Every day at 07:30 · next "))
        #expect(book.detail(book.schedules[2]).hasSuffix(" · set by Orchestrator"))
        #expect(!book.isActive(book.schedules[0]))
        #expect(!book.isActive(book.schedules[1]))
        #expect(book.isActive(book.schedules[2]))
    }

    @Test func aLastRunIsOfferedOnlyWhileTheMacListsIt() throws {
        let book = ScheduleBook(
            schedules: [schedule("a", agent: "o", last: 9), schedule("b", agent: "o", last: 12), schedule("c", agent: "o")],
            agents: [], projects: [], conversations: [9]
        )
        #expect(book.schedules.map(book.lastRun) == [9, nil, nil])
    }

    @Test func theSheetMakesEachKindOfScheduleAsTheMacsSheetDoes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        var draft = ScheduleDraft(original: nil, shownAgent: nil, firstAgent: "o1", calendar: calendar, now: now)
        #expect(draft.agentID == "o1")
        #expect(!draft.canSave)
        draft.title = "Morning brief"
        draft.prompt = "Say what needs me."
        #expect(draft.canSave)
        draft.time = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: now)!

        let daily = try draft.schedule(calendar: calendar).get()
        #expect(daily.repeat == Repeat(kind: "daily", hour: 7, minute: 30))
        #expect(daily.id == "")

        draft.kind = "weekly"
        draft.weekday = 3
        #expect(try draft.schedule(calendar: calendar).get().repeat == Repeat(kind: "weekly", hour: 7, minute: 30, weekday: 3))

        draft.kind = "interval"
        draft.minutes = "90"
        #expect(try draft.schedule(calendar: calendar).get().repeat == Repeat(kind: "interval", minutes: 90))
        draft.minutes = "0"
        #expect((try? draft.schedule(calendar: calendar).get()) == nil)

        draft.kind = "once"
        draft.date = now.addingTimeInterval(3600)
        #expect(try draft.schedule(calendar: calendar).get().repeat == Repeat(kind: "once", at: (now.timeIntervalSince1970 + 3600) * 1000))
    }

    @Test func aCarriedScheduleLeftOnItsCopyKeepsItsOwnAgent() throws {
        let carried = schedule("c", agent: "forge", copy: "forge1")
        var draft = ScheduleDraft(original: carried, shownAgent: "forge1", firstAgent: "o1")
        #expect(draft.agentID == "forge1")
        #expect(draft.title == carried.title)
        #expect(try draft.schedule().get().agentId == "forge")
        #expect(try draft.schedule().get().id == "c")
        draft.agentID = "o1"
        #expect(try draft.schedule().get().agentId == "o1")
    }

    // MARK: - Against the recorded session

    private func replay() async throws -> AppSession {
        let session = AppSession()
        session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
        let end = Date(timeIntervalSinceNow: 30)
        while session.engine.projects.isEmpty || session.engine.status != .connected || session.engine.extras["coauthor"] == nil {
            if Date() > end { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return session
    }

    @Test func theRecordingsSettingsAreReadWhole() async throws {
        let session = try await replay()
        let source = SettingsSource(session.engine)
        #expect(source.connected)
        let project = try #require(source.projects.first { $0.name == "Demo project" })
        #expect(project.settings?.limits.planShare == 90)
        #expect(project.settings?.limits.dailySpend == nil)
        #expect(source.agent(project.orchestratorId)?.compactionTokens == 100_000)
        #expect(source.awake == SettingsAwake(keep: true, battery: false))
        #expect(source.coauthor?.enabled == false)
        #expect(source.chat == SettingsChat(instructions: "", defaultModel: nil, web: true, memory: true))
        #expect(source.compaction == SettingsCompaction(tokens: nil))
        #expect(source.agentDefault?.using == ModelRef(provider: "demo", modelId: "demo-1"))
        #expect(source.plan == [])
        #expect(source.spentToday?[project.id] == 0)
        #expect(source.libraryLoaded)
        // The recording has no schedule: the screens draw their empty states.
        #expect(source.book.groups.isEmpty)
        #expect(!source.book.agents(ofProject: project.id).isEmpty)
    }

    @Test func theRecordingRefusesAChangeAndNothingChanges() async throws {
        let session = try await replay()
        let project = try #require(session.engine.projects.first)
        let refused = await SettingsRequest.wakeOnReports(project: project.id, on: true).send(through: session.engine)
        #expect(refused?.contains("projects.set") == true)
        let refusedToo = await SettingsRequest.awake(keep: false, battery: false).send(through: session.engine)
        #expect(refusedToo?.contains("settings.setAwake") == true)
        // Nothing answered in the engine's place: the settings are as they were.
        #expect(session.engine.projects.first?.settings?.wakeOnReports == false)
        #expect(SettingsAwake(session.engine.extras["awake"])?.keep == true)
    }

    // MARK: - In the demo mode, which answers as the engine does

    private func demo() async throws -> (AppSession, DemoTransport) {
        let transport = try #require(DemoTransport.recorded())
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        let end = Date(timeIntervalSinceNow: 30)
        while session.engine.projects.isEmpty || session.engine.extras["coauthor"] == nil || session.engine.allAgents.isEmpty {
            if Date() > end { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (session, transport)
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: 30)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func theDemoChangesAProjectsSettingsAsTheEngineDoes() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        #expect(await SettingsRequest.planShare(project: project.id, 75).send(through: engine) == nil)
        #expect(await SettingsRequest.dailySpend(project: project.id, 2.5).send(through: engine) == nil)
        #expect(await SettingsRequest.withoutAsking(project: project.id, "merge", on: true).send(through: engine) == nil)
        #expect(await SettingsRequest.wakeOnReports(project: project.id, on: true).send(through: engine) == nil)
        #expect(try await eventually { engine.projects.first { $0.id == project.id }?.settings?.limits.dailySpend == 2.5 })
        let settings = try #require(engine.projects.first { $0.id == project.id }?.settings)
        #expect(settings.limits.planShare == 75)
        #expect(settings.withoutAsking?["merge"] == true)
        #expect(settings.withoutAsking?["startAgents"] == true, "the switches not sent are kept")
        #expect(settings.wakeOnReports)
        // The engine's checks, in its words.
        #expect(await SettingsRequest.planShare(project: project.id, 0).send(through: engine) == "planShare must be a whole number from 1 to 100, or null")
        #expect(await SettingsRequest.withoutAsking(project: project.id, "everything", on: true).send(through: engine) == "Unknown switch: everything")
        let other = try #require(engine.projects.first { $0.id != project.id })
        #expect(await SettingsRequest.rename(project: project.id, to: other.name.uppercased()).send(through: engine)?.hasPrefix("There is already a project called") == true)
        #expect(await SettingsRequest.rename(project: project.id, to: "Site").send(through: engine) == nil)
        #expect(try await eventually { engine.projects.contains { $0.name == "Site" } })
        // The recording has an agent of each project at work: archiving or deleting waits for it, as on a Mac.
        #expect(await SettingsRequest.archive(project: project.id).send(through: engine) == "Stop the project's agents first.")
        #expect(await SettingsRequest.delete(project: project.id).send(through: engine) == "Stop the project's agents first.")
        #expect(engine.projects.first { $0.id == project.id }?.archivedAt == nil)
        // Restoring one that is not archived changes nothing, and is no error.
        #expect(await SettingsRequest.restore(project: project.id).send(through: engine) == nil)
        // No repository to reach in the demo: refused, and nothing attached.
        #expect(await SettingsRequest.attach(project: project.id, repository: nil).send(through: engine) != nil)
        #expect(engine.projects.first { $0.id == project.id }?.repository == nil)
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func theDemoChangesTheAppsSettingsAndTheOrchestrator() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        #expect(await SettingsRequest.awake(keep: false, battery: false).send(through: engine) == nil)
        #expect(await SettingsRequest.autoArchive(days: 30).send(through: engine) == nil)
        #expect(await SettingsRequest.compaction(200_000).send(through: engine) == nil)
        #expect(await SettingsRequest.coauthor(enabled: true).send(through: engine) == nil)
        #expect(await SettingsRequest.coauthor(line: "Co-authored-by: Someone <someone@example.invalid>").send(through: engine) == nil)
        #expect(await SettingsRequest.chatWeb(false).send(through: engine) == nil)
        #expect(await SettingsRequest.chatInstructions("  Keep it short.  ").send(through: engine) == nil)
        #expect(try await eventually { SettingsChat(engine.extras["chat"])?.instructions == "Keep it short." })
        let source = SettingsSource(session)
        #expect(source.awake == SettingsAwake(keep: false, battery: false))
        #expect(source.autoArchiveDays == 30)
        #expect(source.compaction?.tokens == 200_000)
        #expect(source.coauthor == SettingsCoauthor(enabled: true, line: "Co-authored-by: Someone <someone@example.invalid>", defaultLine: SettingsCoauthor.fallback))
        #expect(source.chat?.web == false)
        #expect(await SettingsRequest.coauthor(line: "Someone").send(through: engine)?.hasPrefix("Start the line with") == true)
        #expect(await SettingsRequest.chatModel(ModelRef(provider: "none", modelId: "x")).send(through: engine) == "Unknown model: none/x")

        let project = try #require(engine.projects.first)
        let orchestrator = try #require(engine.agent(project.orchestratorId))
        #expect(await SettingsRequest.agentCompaction(orchestrator, 0).send(through: engine) == nil)
        #expect(try await eventually { engine.agent(orchestrator.id)?.compactionTokens == 0 })
        #expect(engine.agent(orchestrator.id)?.instructions == orchestrator.instructions, "what was not sent is kept")
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func theDemoSavesAndDeletesSchedules() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let project = try #require(engine.projects.first)
        var schedule = Schedule(id: "", title: "Morning brief", agentId: project.orchestratorId, prompt: "Say what needs me.",
                                repeat: Repeat(kind: "daily", hour: 7, minute: 30), enabled: true)
        #expect(await SettingsRequest.saveSchedule(schedule, isNew: true).send(through: engine) == nil)
        #expect(try await eventually { !engine.schedules.isEmpty })
        let saved = try #require(engine.schedules.first)
        #expect(saved.title == "Morning brief")
        let next = try #require(saved.nextRunAt)
        let at = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: next / 1000))
        #expect(at.hour == 7 && at.minute == 30)
        #expect(SettingsSource(session).book.schedules(ofProject: project.id).map(\.id) == [saved.id])

        #expect(await SettingsRequest.setSchedule(saved, enabled: false).send(through: engine) == nil)
        #expect(try await eventually { engine.schedules.first?.enabled == false })
        #expect(engine.schedules.count == 1)

        schedule.title = " "
        #expect(await SettingsRequest.saveSchedule(schedule, isNew: true).send(through: engine) == "Give the schedule a name")
        schedule.title = "Once"
        schedule.repeat = Repeat(kind: "once", at: 1_000)
        #expect(await SettingsRequest.saveSchedule(schedule, isNew: true).send(through: engine) == "That time has already passed")

        #expect(await SettingsRequest.deleteSchedule(saved.id).send(through: engine) == nil)
        #expect(try await eventually { engine.schedules.isEmpty })
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func nothingIsOfferedWhileTheMacIsOutOfReach() async throws {
        let session = try await replay()
        #expect(SettingsSource(session).connected)
        session.connection = .outOfReach(lastSeen: nil)
        #expect(!SettingsSource(session).connected)
        session.connection = .connecting
        #expect(!SettingsSource(session).connected)
        // What was last seen is still drawn.
        #expect(!SettingsSource(session).projects.isEmpty)
    }

    @Test func withNoEngineAChangeIsRefusedNotLost() async {
        let session = AppSession()
        let refused = await SettingsRequest.runSchedule("s").send(through: session.engine)
        #expect(refused != nil)
        #expect(!SettingsSource(session.engine).connected)
        #expect(SettingsSource(session.engine).waiting)
    }
}
