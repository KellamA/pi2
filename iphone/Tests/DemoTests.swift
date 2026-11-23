
import EngineKit
import Foundation
import PiModels
import SwiftUI
import Testing
import UIKit
import UserNotifications
@testable import pi2

/// Every screen of the app, opened in the demo mode. **A screen's issue adds its own lines here** (docs/iphone-app.md,
/// "The demo mode"): the screen's name and the route that opens it, with what it shows taken from the demo. The test
/// below opens each, checks that it draws, and that no request it sent went unanswered by the demo's script.
@MainActor
enum DemoScreens {
    static func all(in engine: EngineSession<MessageField>) throws -> [(name: String, route: Route)] {
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        let second = try #require(engine.projects.first { $0.name == "Demo project 2" })
        let orchestrator = try #require(project.conversation)
        let agent = try #require(engine.rootConversations.first { $0.projectId == project.id && $0.id != orchestrator }?.id)
        // The sub-chat the recording holds at work, its report still to come.
        let subChat = try #require(engine.conversations.first { $0.projectId == project.id && $0.parent == orchestrator && $0.busy }?.id)
        return [
            ("The projects list (#685)", .home),
            ("A project's hub, Chat (#688)", .project(project.id, tab: .chat)),
            ("A project's hub, Now (#688)", .project(project.id, tab: .now)),
            ("A project's hub, Work (#688)", .project(project.id, tab: .work)),
            ("A project's hub, More (#688)", .project(project.id, tab: .more)),
            ("The Dashboard (#688)", .dashboard()),
            ("The Dashboard at a project (#688)", .dashboard(project: project.id)),
            ("The orchestrator's conversation (#687)", .conversation(orchestrator)),
            ("An agent's conversation (#687)", .conversation(agent)),
            ("Needs you, every project (#686)", .needs()),
            ("Needs you, one project (#686)", .needs(project: project.id)),
            // The second project holds the cards the first does not: a start held back by its limit, and an approval its
            // fileWork switch asked for, its orchestrator waiting on it.
            ("Needs you, the second project (#686)", .needs(project: second.id)),
            ("The second project's hub, Now (#688)", .project(second.id, tab: .now)),
            ("The Dashboard at the second project (#688)", .dashboard(project: second.id)),
            ("An orchestrator waiting on a switch's approval (#687)", .conversation(try #require(second.conversation))),
            ("A sub-chat at work (#687)", .conversation(subChat)),
            ("The app's settings (#697)", .settings),
            ("A project's settings and limits (#697)", .projectSettings(project.id)),
            ("Schedules (#697)", .schedules),
        ]
    }
}

@MainActor
struct DemoTests {
    /// Waits for `condition`, polling, for at most `seconds`: the demo hands the client its lines on the main actor, a
    /// little after they are made.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A session in the demo, its scripted steps run quickly, once the greeting is in.
    private func demo() async throws -> (AppSession, DemoTransport) {
        let transport = try #require(DemoTransport.recorded(), "the demo's recording is in the app's bundle, in every build")
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        #expect(try await eventually { !session.engine.projects.isEmpty && !session.engine.needs.isEmpty })
        return (session, transport)
    }

    /// The sockets this process has open, by descriptor.
    private func sockets() -> Set<Int32> {
        var open = Set<Int32>()
        for descriptor in 0..<getdtablesize() {
            var info = stat()
            if fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { open.insert(descriptor) }
        }
        return open
    }

    /// Draws `view` in a window of a phone's size, and says whether it drew anything: more than one colour.
    private func draws(_ view: some View, session: AppSession) async throws -> Bool {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view.environment(session))
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.cgImage?.dataProvider?.data as Data? else { return false }
        return Set(stride(from: 0, to: data.count, by: 4 * 97).map { data[$0..<min($0 + 3, data.count)] }).count > 1
    }

    @Test func everyScreenOpensInTheDemoWithNoSocket() async throws {
        let before = sockets()
        let (session, transport) = try await demo()
        #expect(session.connection == .demo)

        #expect(try await draws(FirstScreen(), session: AppSession()), "the first screen, with Try it without a Mac")
        #expect(try await draws(NavigationStack { RouteView(.home) }.demoBar(), session: session), "the Demo bar")
        for (name, route) in try DemoScreens.all(in: session.engine) {
            #expect(try await draws(NavigationStack { RouteView(route) }.demoBar(), session: session), "\(name) draws")
        }
        // What the screens asked for came, and the demo answered all of it.
        try await Task.sleep(for: .milliseconds(300))
        #expect(transport.world.unanswered.isEmpty, "requests the demo's script does not answer: \(transport.world.unanswered)")

        // Writing to a conversation and answering a card, the demo's two scripted answers, with the screens above.
        let orchestrator = try #require(session.engine.projects.first?.conversation)
        session.engine.openConversation(orchestrator)
        #expect(await session.engine.submit("Hello from the demo", to: orchestrator, steer: false) == .sent)
        #expect(try await eventually { session.engine.open[orchestrator]?.items.last?.text.hasPrefix("You said: \"Hello from the demo\"") == true })
        let need = try #require(session.engine.needs.first { $0.kind == "question" })
        try await session.engine.call("needs.answer", ["id": need.id, "answer": ["kind": "question", "text": "Everyone"]])

        #expect(sockets().subtracting(before).isEmpty, "the demo opened a socket")
    }

    @Test func theRecordingHoldsEveryKindOfCardItCan() async throws {
        let (session, _) = try await demo()
        let engine = session.engine
        #expect(engine.projects.map(\.name).sorted() == ["Demo project", "Demo project 2"])
        #expect(Set(engine.needs.map(\.kind)) == ["approval", "question", "decision", "reach", "rule", "limit"])
        // An approval of each sort: one the inbox holds for an agent's command, and one a project's switch asked for.
        #expect(engine.needs.contains { need in need.kind == "approval" && need.projectSwitch == nil && engine.inbox.contains { $0.id == need.id } })
        #expect(engine.needs.contains { $0.kind == "approval" && $0.projectSwitch == "fileWork" })
        #expect(engine.needs.first { $0.kind == "limit" }?.start?.agentName == "Forge")
        // Agents at work in both projects, a sub-chat among them whose report is still to come.
        for project in engine.projects {
            #expect(engine.hubRuns(project.id).contains { $0.status == "working" }, "\(project.name)")
        }
        let reports = engine.projects.flatMap { engine.extras["reports"]?["projects"]?[$0.id]?.arrayValue ?? [] }
        #expect(reports.filter { $0["ended"] == .null }.count == 1)
        #expect(!engine.agents.isEmpty)
        #expect(engine.rootConversations.count >= 8)
        // Its times are moved to now: the newest card is from the last day, not from when it was recorded.
        let newest = try #require(engine.needs.map(\.createdAt).max())
        #expect(abs(Date().timeIntervalSince1970 * 1000 - newest) < 86_400_000)
        // Nothing of the Mac it was made on.
        let recording = try #require(DemoTransport.recording())
        #expect(!recording.contains(NSUserName()) || NSUserName().count < 3)
    }

    @Test func aMessageGetsTheDemoModelsStreamedAnswer() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let id = try #require(engine.projects.first { $0.name == "Demo project" }?.conversation)
        engine.openConversation(id)
        #expect(try await eventually { engine.open[id]?.state != nil })
        let before = engine.open[id]?.items.count ?? 0

        #expect(await engine.submit("Plan the launch", to: id, steer: false) == .sent)
        #expect(try await eventually { engine.open[id]?.state?.busy == true || engine.open[id]?.items.last?.kind == "assistant" })
        #expect(try await eventually { engine.open[id]?.state?.busy == false && engine.open[id]?.items.last?.kind == "assistant" })
        let items = try #require(engine.open[id]?.items)
        #expect(items.count == before + 2)
        #expect(items[items.count - 2].kind == "user")
        #expect(items[items.count - 2].text == "Plan the launch")
        #expect(items.last?.text == DemoReplies.answer(to: "Plan the launch"))
        #expect(engine.projects.first { $0.conversation == id }?.lastWords?.text == DemoReplies.answer(to: "Plan the launch"))
        #expect(engine.activity.allSatisfy { $0.conversationId != id })
        #expect(transport.world.unanswered.isEmpty)

        // Two messages at once: the second waits its turn, and is answered after the first.
        #expect(await engine.submit("First", to: id, steer: false) == .sent)
        #expect(await engine.submit("Second", to: id, steer: false) == .sent)
        #expect(try await eventually { engine.open[id]?.items.last?.text == DemoReplies.answer(to: "Second") && engine.open[id]?.state?.busy == false })
        #expect(engine.open[id]?.items.filter { $0.kind == "user" }.suffix(2).map(\.text) == ["First", "Second"])

        // An empty message is refused, as the engine refuses it.
        await #expect(throws: (any Error).self) { try await engine.call("submit", ["id": id, "text": "  "]) }
    }

    @Test func stopKeepsWhatWasWritten() async throws {
        let (session, transport) = try await demo()
        transport.world.pace = 1
        let engine = session.engine
        let id = try #require(engine.projects.first?.conversation)
        engine.openConversation(id)
        #expect(await engine.submit("Something long", to: id, steer: false) == .sent)
        #expect(try await eventually { (engine.open[id]?.state?.partial?.text.count ?? 0) > 0 })
        try await engine.call("abort", ["id": id])
        #expect(try await eventually { engine.open[id]?.state?.busy == false })
        let last = try #require(engine.open[id]?.items.last)
        #expect(last.stop == "aborted")
        #expect(DemoReplies.answer(to: "Something long").hasPrefix(last.text))
    }

    @Test func answeringACardTakesItAway() async throws {
        let (session, _) = try await demo()
        let engine = session.engine

        // An approval, through the inbox's request: gone from both lists, and the agent's command runs.
        let approval = try #require(engine.needs.first { $0.kind == "approval" })
        #expect(engine.inbox.contains { $0.id == approval.id })
        engine.openConversation(approval.conversationId)
        try await engine.call("inbox.decide", ["id": approval.id, "decision": "once"])
        #expect(try await eventually { !engine.needs.contains { $0.id == approval.id } && !engine.inbox.contains { $0.id == approval.id } })
        #expect(try await eventually { engine.open[approval.conversationId]?.state?.busy == false })
        #expect(engine.open[approval.conversationId]?.items.contains { $0.kind == "tool" && $0.text == "(no output)" } == true)
        // A second answer is refused, in the engine's words.
        do {
            try await engine.call("inbox.decide", ["id": approval.id, "decision": "deny"])
            Issue.record("a second answer was taken")
        } catch {
            #expect(error.localizedDescription == DemoNeeds.gone)
        }

        // A decision: one of its choices, not another's.
        let decision = try #require(engine.needs.first { $0.kind == "decision" })
        await #expect(throws: (any Error).self) { try await engine.call("needs.answer", ["id": decision.id, "answer": ["kind": "decision", "choice": "nope"]]) }
        await #expect(throws: (any Error).self) { try await engine.call("needs.answer", ["id": decision.id, "answer": ["kind": "question", "text": "x"]]) }
        let choice = try #require(decision.choices?.first?.id)
        try await engine.call("needs.answer", ["id": decision.id, "answer": ["kind": "decision", "choice": choice]])
        #expect(try await eventually { !engine.needs.contains { $0.id == decision.id } })

        // More reach, allowed: the project's switch is on.
        let reach = try #require(engine.needs.first { $0.kind == "reach" })
        try await engine.call("needs.answer", ["id": reach.id, "answer": ["kind": "reach", "allow": true]])
        #expect(try await eventually { engine.projects.first { $0.id == reach.projectId }?.settings?.withoutAsking?["merge"] == true })

        // A proposed rule, accepted: it is one of the project's rules.
        let rule = try #require(engine.needs.first { $0.kind == "rule" })
        let projectID = try #require(rule.projectId)
        try await engine.call("needs.answer", ["id": rule.id, "answer": ["kind": "rule", "accept": true]])
        #expect(try await eventually { engine.projectRules[projectID]?.contains { $0.text == rule.text } == true })
        #expect(!engine.needs.contains { $0.id == rule.id })

        // needs.list, of one project.
        let listed = try await engine.call("needs.list", ["projectId": projectID])
        #expect(listed["items"]?.arrayValue?.count == engine.needs.filter { $0.projectId == projectID }.count)
    }

    @Test func whatTheDemoDoesNotDoIsRefusedAndChangesNothing() async throws {
        let (session, transport) = try await demo()
        let projects = session.engine.projects
        do {
            // The Mac's own upkeep, which no screen of the phone sends and the demo never answers.
            try await session.engine.call("backup.create", ["directory": "/tmp"])
            Issue.record("the demo answered a request its script has no answer for")
        } catch {
            #expect(error.localizedDescription.contains("The demo does not do backup.create"))
        }
        #expect(session.engine.projects == projects)
        #expect(transport.world.unanswered == ["backup.create"])
        // A project's folder is the Mac's: answered with a refusal that changes nothing.
        await #expect(throws: (any Error).self) {
            try await session.engine.call("projects.set", ["id": projects[0].id, "folder": "/tmp"])
        }
        #expect(session.engine.projects == projects)
        #expect(DemoScript.answeredTwice.isEmpty)
    }

    @Test func leavingGoesBackToTheFirstScreen() async throws {
        let session = AppSession()
        Launch.start(session, demo: true)
        #expect(session.connection == .demo)
        #expect(session.macName == DemoTransport.macName)
        #expect(try await eventually { !session.engine.projects.isEmpty })
        DemoMode.leave(session)
        #expect(session.connection == .notPaired)
        #expect(session.macName == nil)
        #expect(DemoMode.shared.transport == nil)
        #expect(try await eventually { session.engine.status != .connected })
    }

    @Test func aNotificationOfEveryKind() async throws {
        let (session, _) = try await demo()
        let requests = DemoNotifications.requests(needs: session.engine.needs, projects: session.engine.projects)
        let kinds = requests.map { $0.content.userInfo["kind"] as? String }
        #expect(Set(kinds.compactMap { $0 }) == ["approval", "question", "decision", "reach", "rule", "limit", "notice"])
        for request in requests {
            #expect(request.identifier.hasPrefix(DemoNotifications.prefix))
            #expect(!request.content.title.isEmpty)
            #expect(request.content.body.count <= DemoNotifications.bodyLimit)
            #expect(request.content.categoryIdentifier.hasPrefix("pi2."))
        }
        // The newest approval: the one the second project's fileWork switch asked its orchestrator for.
        let approval = try #require(requests.first { $0.content.userInfo["kind"] as? String == "approval" })
        #expect(approval.content.title == "Orchestrator needs approval")
        #expect(approval.content.body.hasPrefix("Demo project 2 · "))
        #expect(approval.content.categoryIdentifier.hasPrefix("pi2.approval"))
        let limit = try #require(requests.first { $0.content.userInfo["kind"] as? String == "limit" })
        #expect(limit.content.title == "Orchestrator is held back by a limit")
        #expect(limit.content.categoryIdentifier == "pi2.limit")

        // Every category of section 7, and every button opens pi² with the phone unlocked.
        let categories = DemoNotifications.categories
        for kind in DemoNotifications.Kind.allCases {
            #expect(categories.contains { $0.identifier == kind.category }, "\(kind)")
        }
        for action in categories.flatMap(\.actions) {
            #expect(action.options.contains(.foreground) && action.options.contains(.authenticationRequired), "\(action.identifier)")
        }
        #expect(categories.first { $0.identifier == "pi2.approval" }?.actions.map(\.title) == ["Allow once", "Deny", "Open"])

        // A call too long to show whole: no Allow once.
        let long = try JSONDecoder().decode(NeedItem.self, from: Data("""
        {"id":"x","projectId":null,"kind":"approval","conversationId":1,"rootConversationId":1,"title":"t","rootTitle":"t",
         "agentId":null,"agentName":"Forge","blocking":true,"createdAt":0,"tool":"bash",
         "arguments":{"command":"\(String(repeating: "echo safe && ", count: 30))rm -rf build"}}
        """.utf8))
        let cut = DemoNotifications.content(for: long, project: nil)
        #expect(cut.categoryIdentifier == "pi2.approval.cut")
        #expect(cut.body.count == DemoNotifications.bodyLimit)

        // Scheduling them is not tried here: iOS takes them only once the person has allowed notifications, which a
        // test cannot answer for them.

        // A button opens the card's project's Needs you, or the orchestrator's conversation for a notice.
        #expect(DemoNotifications.route(kind: "approval", projectID: "p-1", conversationID: 3) == .needs(project: "p-1"))
        #expect(DemoNotifications.route(kind: "notice", projectID: "p-1", conversationID: 9) == .conversation(9))
    }
}

// MARK: - The screens' requests, answered (#684, second part)

/// Each screen's requests sent as the screen itself sends them (its own request type), and the session's state checked
/// afterwards: what the screen then draws.
extension DemoTests {
    /// A value `make` gives once it gives one, polling, for at most `seconds`.
    private func eventuallyValue<T>(_ seconds: Double = 30, _ make: () -> T?) async throws -> T? {
        let end = Date(timeIntervalSinceNow: seconds)
        while true {
            if let value = make() { return value }
            if Date() > end { return nil }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func everyKindOfCardIsAnsweredAsNeedsYouSendsIt() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let second = try #require(engine.projects.first { $0.name == "Demo project 2" })

        /// Answers `need` as its card does, and checks it left Needs you, with every count that shows it.
        func answer(_ reply: NeedReply, _ need: NeedItem) async throws {
            let all = engine.needs.count
            let project = need.projectId ?? ""
            let inProject = engine.hubNeeds(project).count
            let listed = HomeLists.projects(engine).first { $0.id == project }?.needs
            #expect(await NeedAnswering.send(reply, to: need.id, through: engine) == nil, "\(need.kind) \(need.id)")
            #expect(try await eventually { !engine.needs.contains { $0.id == need.id } }, "\(need.kind) \(need.id) left Needs you")
            #expect(engine.needs.count == all - 1)
            #expect(engine.hubNeeds(project).count == inProject - 1)
            #expect(HomeLists.projects(engine).first { $0.id == project }?.needs == listed.map { $0 - 1 })
            #expect(!engine.inbox.contains { $0.id == need.id })
        }

        // A question, in the person's words: the orchestrator is told.
        let question = try #require(engine.needs.first { $0.kind == "question" })
        engine.openConversation(question.conversationId)
        try await answer(.question("Everyone on the team"), question)
        #expect(try await eventually { engine.open[question.conversationId]?.items.last?.text.contains("Everyone on the team") == true })

        // Decisions: one by a choice, one in words.
        let decisions = engine.needs.filter { $0.kind == "decision" }
        #expect(decisions.count == 2)
        try await answer(.choice(try #require(decisions.first?.choices?.first?.id)), decisions[0])
        try await answer(.decisionWords("Both, one after the other"), decisions[1])

        // An approval the inbox holds: allowed once, the command runs and the agent finishes.
        let approval = try #require(engine.needs.first { $0.kind == "approval" && $0.projectSwitch == nil })
        engine.openConversation(approval.conversationId)
        try await answer(.decide(.once), approval)
        #expect(try await eventually { engine.open[approval.conversationId]?.state?.busy == false })
        #expect(!engine.hubRuns(approval.projectId ?? "").contains { $0.conversationId == approval.conversationId })

        // An approval the second project's fileWork switch asked for: once or deny only; allowed, the work is filed.
        let held = try #require(engine.needs.first { $0.projectSwitch == "fileWork" })
        #expect(held.projectId == second.id)
        #expect(await NeedAnswering.send(.switchApproval(.always), to: held.id, through: engine)
            == "This can only be allowed once, or denied: the project's settings ask each time")
        let work = { engine.extras["work"]?["projects"]?[second.id]?.arrayValue ?? [] }
        let filed = work().count
        engine.openConversation(held.conversationId)
        try await answer(.switchApproval(.once), held)
        #expect(try await eventually { work().count == filed + 1 })
        #expect(work().last?["title"]?.stringValue == "Write the walkthrough FAQ")
        #expect(try await eventually { engine.open[held.conversationId]?.state?.busy == false })
        #expect(engine.open[held.conversationId]?.items.contains { $0.kind == "tool" && $0.text.hasPrefix("Filed #") } == true)

        // More reach, refused: the switch stays off.
        let reach = try #require(engine.needs.first { $0.kind == "reach" })
        try await answer(.reach(allow: false), reach)
        #expect(engine.projects.first { $0.id == reach.projectId }?.settings?.withoutAsking?["merge"] == false)

        // A proposed rule, accepted with its words and whom it binds changed.
        let rule = try #require(engine.needs.first { $0.kind == "rule" })
        let ruleProject = try #require(rule.projectId)
        try await answer(.acceptRule(text: "Run every test before a review.", binds: .orchestrator), rule)
        #expect(try await eventually {
            engine.projectRules[ruleProject]?.contains { $0.text == "Run every test before a review." && $0.binds == .orchestrator } == true
        })

        // A start the limit held back, started anyway: the sub-chat it holds works, answers, and shows under what
        // finished today.
        let limit = try #require(engine.needs.first { $0.kind == "limit" })
        let task = try #require(limit.start?.task)
        let before = Set(engine.conversations.map(\.id))
        try await answer(.limit(start: true), limit)
        let started = try #require(try await eventuallyValue { engine.conversations.first { !before.contains($0.id) } })
        #expect(started.parent == second.conversation)
        #expect(started.projectId == second.id)
        engine.openConversation(started.id)
        #expect(try await eventually { engine.open[started.id]?.items.last?.text == DemoReplies.answer(to: task) })
        #expect(try await eventually { engine.hubReports(second.id).contains { $0.title == started.title && $0.outcomeWord == "done" } })

        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func theHubAndTheDashboardWork() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let project = try #require(engine.projects.first { $0.name == "Demo project" })

        // The switch for reports waking the orchestrator.
        #expect(project.settings?.wakeOnReports == false)
        #expect(await HubRequests.setWake(engine, project: project.id, on: true) == nil)
        #expect(try await eventually { engine.hubProject(project.id)?.settings?.wakeOnReports == true })
        #expect(await HubRequests.setWake(engine, project: project.id, on: false) == nil)
        #expect(try await eventually { engine.hubProject(project.id)?.settings?.wakeOnReports == false })

        // Stop on a working row: the sub-chat's run ends, it leaves who is working, and shows under Finished today.
        let run = try #require(engine.hubRuns(project.id).first { $0.parent == project.conversation && $0.status == "working" })
        let finished = engine.hubReports(project.id).count
        engine.openConversation(run.conversationId)
        #expect(await HubRequests.stop(engine, conversation: run.conversationId) == nil)
        #expect(try await eventually { !engine.hubRuns(project.id).contains { $0.conversationId == run.conversationId } })
        #expect(try await eventually { engine.hubReports(project.id).count == finished + 1 })
        #expect(engine.hubReports(project.id).first?.title == run.title)
        #expect(engine.hubReports(project.id).first?.outcomeWord == "stopped")
        #expect(try await eventually { engine.open[run.conversationId]?.state?.failure?.reason == "aborted" })
        #expect(engine.conversations.first { $0.id == run.conversationId }?.busy == false)

        // Stop on an agent waiting for approval: what it waited for leaves Needs you.
        let waiting = try #require(engine.hubRuns(project.id).first { $0.status == "waiting" })
        let asked = try #require(engine.needs.first { $0.conversationId == waiting.conversationId })
        #expect(await HubRequests.stop(engine, conversation: waiting.conversationId) == nil)
        #expect(try await eventually { !engine.needs.contains { $0.id == asked.id } && !engine.inbox.contains { $0.id == asked.id } })
        #expect(!engine.hubRuns(project.id).contains { $0.conversationId == waiting.conversationId })

        // A message from the Dashboard's field: the orchestrator's answer comes, and is the project's last words.
        let orchestrator = try #require(project.conversation)
        engine.openConversation(orchestrator)
        #expect(await HubRequests.message(engine, "Where are we?", to: project) == nil)
        #expect(try await eventually { engine.hubProject(project.id)?.lastWords?.text == DemoReplies.answer(to: "Where are we?") })
        #expect(engine.open[orchestrator]?.items.last?.text == DemoReplies.answer(to: "Where are we?"))

        // What the phone shows of the project, watched; a tab the engine does not watch is refused.
        try await engine.call("projects.watch", ["projectId": project.id, "tabs": ["now"]])
        try await engine.call("projects.watch", ["projectId": NSNull(), "tabs": [String]()])
        await #expect(throws: (any Error).self) { try await engine.call("projects.watch", ["projectId": project.id, "tabs": ["chat"]]) }

        // A fresh conversation with the orchestrator: the project names it, and the one before is an earlier one.
        #expect(await HubRequests.startConversation(engine, project: project.id) == nil)
        let fresh = try #require(try await eventuallyValue { engine.hubProject(project.id)?.conversation.flatMap { $0 == orchestrator ? nil : $0 } })
        #expect(engine.conversations.first { $0.id == fresh }?.orchestrator == "current")
        #expect(engine.conversations.first { $0.id == fresh }?.freshFrom == orchestrator)
        #expect(engine.conversations.first { $0.id == orchestrator }?.orchestrator == "earlier")
        engine.openConversation(fresh)
        #expect(await HubRequests.message(engine, "Hello again", to: try #require(engine.hubProject(project.id))) == nil)
        #expect(try await eventually { engine.open[fresh]?.items.last?.text == DemoReplies.answer(to: "Hello again") })

        // The second project's orchestrator waits on an approval: no fresh start until it is answered.
        let second = try #require(engine.projects.first { $0.name == "Demo project 2" })
        #expect(await HubRequests.startConversation(engine, project: second.id) == "Answer what the orchestrator is waiting for first.")

        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func theConversationWorks() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let id = try #require(engine.projects.first { $0.name == "Demo project" }?.conversation)
        let requests = ConversationRequests(engine: engine, conversationID: id)
        engine.openConversation(id)
        #expect(try await eventually { engine.open[id]?.state != nil })

        // A message with a picture: the answer says it came, and the page can have the picture.
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let picture = ConversationPicture(name: "Sketch.png", data: png, mimeType: "image/png", thumbnail: png)
        #expect(await requests.send("Here is the layout", pictures: [picture], steer: false) == .sent)
        #expect(try await eventually { engine.open[id]?.items.last?.text == DemoReplies.answer(to: "Here is the layout", pictures: 1) })
        let sent = try #require(engine.open[id]?.items.last { $0.kind == "user" })
        #expect(sent.images == 1)
        #expect(sent.attachments?.first?.name == "Sketch.png")
        let fetched = try #require(await requests.picture(entry: sent.id, index: 0))
        #expect(fetched.mimeType == "image/png")
        #expect(Data(base64Encoded: fetched.data) == png)
        #expect(await requests.picture(entry: sent.id, index: 1) == nil)

        // Steer while it answers, then a message queued and taken back: the steered one is answered, the other never.
        // Slowly, so that the answer is still being written when both arrive.
        transport.world.pace = 5
        #expect(await requests.send("A long one", pictures: [], steer: false) == .sent)
        #expect(try await eventually { engine.open[id]?.state?.busy == true })
        #expect(await requests.send("Shorter, please", pictures: [], steer: true) == .sent)
        #expect(await requests.send("Never mind", pictures: [], steer: false) == .sent)
        #expect(try await eventually { engine.open[id]?.state?.queued.count == 2 })
        #expect(engine.open[id]?.state?.queued.map(\.mode) == ["steer", "followUp"])
        let takenBack = try #require(engine.open[id]?.state?.queued.last?.id)
        #expect(await requests.withdraw(takenBack) == nil)
        #expect(try await eventually { engine.open[id]?.state?.queued.count == 1 })
        transport.world.pace = 0.02
        #expect(try await eventually(60) { engine.open[id]?.items.last?.text == DemoReplies.answer(to: "Shorter, please") && engine.open[id]?.state?.busy == false })
        #expect(engine.open[id]?.items.contains { $0.text == "Never mind" } == false)

        // Stop, then Continue: the run resumes and answers.
        transport.world.pace = 1
        #expect(await requests.send("Something to stop", pictures: [], steer: false) == .sent)
        #expect(try await eventually { (engine.open[id]?.state?.partial?.text.count ?? 0) > 0 })
        #expect(await requests.stop() == nil)
        #expect(try await eventually { engine.open[id]?.state?.busy == false })
        #expect(engine.open[id]?.state?.failure?.reason == "aborted")
        #expect(engine.open[id]?.items.last?.stop == "aborted")
        transport.world.pace = 0.02
        #expect(await requests.carryOn() == nil)
        #expect(try await eventually { engine.open[id]?.items.last?.text == DemoReplies.answer(to: "Something to stop") && engine.open[id]?.state?.busy == false })
        #expect(engine.open[id]?.state?.failure == nil)

        // Nothing older than what the recording holds.
        #expect(try await engine.call("conversation.older", ["id": id])["more"] == .bool(false))

        // Archived, it takes no message; Restore brings it back. Archiving an agent at work stops it first.
        let agent = try #require(engine.rootConversations.first { $0.projectId != nil && $0.title == "Check the sample build" && $0.busy })
        try await engine.call("conversation.archive", ["id": agent.id])
        #expect(try await eventually { engine.archived.contains { $0.id == agent.id } && !engine.conversations.contains { $0.id == agent.id } })
        let archived = ConversationRequests(engine: engine, conversationID: agent.id)
        if case .refused(let why) = await archived.send("Still there?", pictures: [], steer: false) {
            #expect(why.contains("archived"))
        } else {
            Issue.record("an archived conversation took a message")
        }
        #expect(await archived.restore(agent.id) == nil)
        #expect(try await eventually { engine.conversations.contains { $0.id == agent.id } && !engine.archived.contains { $0.id == agent.id } })
        #expect(engine.conversations.first { $0.id == agent.id }?.busy == false)
        #expect(!engine.activity.contains { $0.conversationId == agent.id })

        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func theProjectsListWorks() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let actions = HomeActions()

        // New Chat, pinned, found by search once written to, then archived.
        let chat = try #require(await actions.newChat(in: engine))
        #expect(try await eventually { engine.conversations.contains { $0.id == chat && $0.chat == true } })
        let row = try #require(engine.conversations.first { $0.id == chat })
        await actions.pin(row, true, in: engine)
        #expect(try await eventually { engine.conversations.first { $0.id == chat }?.pinned == true })
        engine.openConversation(chat)
        #expect(await engine.submit("Plan a picnic", to: chat, steer: false) == .sent)
        #expect(try await eventually { engine.conversations.first { $0.id == chat }?.title == "Plan a picnic" && engine.open[chat]?.state?.busy == false })
        let found = try await engine.call("search", ["query": "picnic"])
        #expect(found["results"]?.arrayValue?.contains { $0["conversationId"]?.intValue == chat } == true)
        await actions.archive(try #require(engine.conversations.first { $0.id == chat }), in: engine)
        #expect(try await eventually { engine.archived.contains { $0.id == chat } })

        // A project renamed; a project at work is not archived.
        let project = try #require(HomeLists.projects(engine).first { $0.name == "Demo project" })
        await actions.rename(project, to: "  Friday walkthrough ", in: engine)
        #expect(try await eventually { engine.hubProject(project.id)?.name == "Friday walkthrough" })
        await actions.archive(project, in: engine)
        #expect(actions.failure?.message == "Stop the project's agents first.")
        #expect(engine.hubProject(project.id)?.archivedAt == nil)

        #expect(transport.world.unanswered.isEmpty)
    }
}
