
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
        let orchestrator = try #require(project.conversation)
        let agent = try #require(engine.rootConversations.first { $0.projectId == project.id && $0.id != orchestrator }?.id)
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
        // A limit card is not in the recording yet: the fill cannot make one (engine/scripts/test-copy-project.ts).
        #expect(Set(engine.needs.map(\.kind)).isSuperset(of: ["approval", "question", "decision", "reach", "rule"]))
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
            try await session.engine.call("projects.rename", ["id": projects[0].id, "name": "Renamed"])
            Issue.record("the demo answered a request its script has no answer for")
        } catch {
            #expect(error.localizedDescription.contains("The demo does not do projects.rename"))
        }
        #expect(session.engine.projects == projects)
        #expect(transport.world.unanswered == ["projects.rename"])
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
        #expect(Set(kinds.compactMap { $0 }) == ["approval", "question", "decision", "reach", "rule", "notice"])
        for request in requests {
            #expect(request.identifier.hasPrefix(DemoNotifications.prefix))
            #expect(!request.content.title.isEmpty)
            #expect(request.content.body.count <= DemoNotifications.bodyLimit)
            #expect(request.content.categoryIdentifier.hasPrefix("pi2."))
        }
        let approval = try #require(requests.first { $0.content.userInfo["kind"] as? String == "approval" })
        #expect(approval.content.title == "Beacon needs approval")
        #expect(approval.content.body == "Demo project 2 · /usr/bin/true" || approval.content.body == "Demo project · /usr/bin/true")
        #expect(approval.content.categoryIdentifier == "pi2.approval")

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

        // A button opens the card's project's Needs you, or the orchestrator's conversation for a notice.
        #expect(DemoNotifications.route(kind: "approval", projectID: "p-1", conversationID: 3) == .needs(project: "p-1"))
        #expect(DemoNotifications.route(kind: "notice", projectID: "p-1", conversationID: 9) == .conversation(9))
    }
}
