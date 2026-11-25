
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
/// below opens each, checks that it draws, and that every request it sent was answered by the demo's script, not refused
/// as one it does not do or with a thing it does not know. Every case of `Route` must be opened at least once
/// (`DemoRoute`).
@MainActor
enum DemoScreens {
    static func all(in engine: EngineSession<MessageField>) throws -> [(name: String, route: Route)] {
        let project = try #require(engine.projects.first { $0.name == "Demo project" })
        let second = try #require(engine.projects.first { $0.name == "Demo project 2" })
        // The third project keeps its work on GitHub: an open pull request, the issue it fixes, a closed issue.
        let site = try #require(engine.projects.first { $0.name == "Demo site" })
        let pull = try #require(GitHubWork.of(engine.extras["github"], project: site.id)?.pulls.first?.number)
        let reviewer = try #require(engine.allAgents.first { $0.projectId == site.id && $0.role == nil }?.id)
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
            ("Usage (#697)", .usage),
            ("The app's settings (#697)", .settings),
            ("A project's settings and limits (#697)", .projectSettings(project.id)),
            ("Schedules (#697)", .schedules),
            ("The board's Agents (#696)", .board(project: project.id, page: .agents)),
            ("The board's Rules (#696)", .board(project: project.id, page: .rules)),
            ("The board's Notes (#696)", .board(project: project.id, page: .notes)),
            ("The board's Branches (#696)", .board(project: project.id, page: .branches)),
            ("An agent's page (#696)", .agent(project.orchestratorId, project: project.id)),
            ("A template's page (#696)", .agent(try #require(engine.agents.first?.id))),
            ("The templates (#696)", .templates),
            ("Work, the list (#694)", .work(project: project.id)),
            ("Work, a piece of work (#694)", .work(project: project.id, item: 3)),
            ("Work, a piece that is not in the list (#694)", .work(project: project.id, item: 999)),
            ("A project's other conversations (#698)", .conversations(project: project.id)),
            ("Chats and conversations outside projects (#698)", .conversations()),
            ("The archive (#698)", .archive),
            ("Background commands (#698)", .backgroundCommands()),
            ("New project, from a folder the Mac offers (#698)", .newProject),
            // The demo's agents link to no file: the screen says why the Mac does not show it.
            ("A file a conversation links to (#698)", .filePreview(conversation: agent, path: "notes/plan.md")),
            // A command's output needs a command, and the demo's agents start none: the page says the output is gone.
            ("A background command's output, gone (#698)", .backgroundCommands(output: "bg-1")),
            // A project whose work is kept by pi²: the page says it has no pull requests, and asks the demo nothing.
            ("A pull request of a project with no repository (#695)", .pullRequest(project: project.id, number: 7)),
            ("A pull request's file, no repository (#695)", .pullRequest(project: project.id, number: 7, file: "docs/projects.md")),
            // Demo site's: its pull request with its checks, finding and files, and a file's diff.
            ("A pull request (#695)", .pullRequest(project: site.id, number: pull)),
            ("A pull request's file (#695)", .pullRequest(project: site.id, number: pull, file: "docs/walkthrough.md")),
            ("A pull request that is not listed (#695)", .pullRequest(project: site.id, number: 99)),
            ("Work on GitHub, the list (#694)", .work(project: site.id)),
            ("Work on GitHub, an open issue (#694)", .work(project: site.id, item: 3)),
            ("Work on GitHub, a closed issue read whole (#694)", .work(project: site.id, item: 1)),
            ("The board's Branches, in a git repository (#696)", .board(project: site.id, page: .branches)),
            ("The board's Agents, a project on GitHub (#696)", .board(project: site.id, page: .agents)),
            ("A reviewing agent's page (#696)", .agent(reviewer, project: site.id)),
            ("Demo site's hub, Now (#688)", .project(site.id, tab: .now)),
            ("Demo site's hub, Work (#688)", .project(site.id, tab: .work)),
            // Nothing is written while no Mac is out of reach: the Outbox is the store's, which the demo never opens.
            ("The Outbox (#692)", .outbox),
        ]
    }
}

/// Every case of `Route`, by name. A case added to `Route` stops this file compiling until it is named here, and then
/// `everyScreenOpensInTheDemoWithNoSocket` fails until `DemoScreens.all` opens a route of that case.
enum DemoRoute: String, CaseIterable {
    case home, project, dashboard, conversation, needs, work, pullRequest, board, agent, templates, projectSettings, settings,
         schedules, usage, conversations, archive, backgroundCommands, newProject, filePreview, outbox

    init(_ route: Route) {
        switch route {
        case .home: self = .home
        case .project: self = .project
        case .dashboard: self = .dashboard
        case .conversation: self = .conversation
        case .needs: self = .needs
        case .work: self = .work
        case .pullRequest: self = .pullRequest
        case .board: self = .board
        case .agent: self = .agent
        case .templates: self = .templates
        case .projectSettings: self = .projectSettings
        case .settings: self = .settings
        case .schedules: self = .schedules
        case .usage: self = .usage
        case .conversations: self = .conversations
        case .archive: self = .archive
        case .backgroundCommands: self = .backgroundCommands
        case .newProject: self = .newProject
        case .filePreview: self = .filePreview
        case .outbox: self = .outbox
        }
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

    /// A socket this process has open: which one (its device and inode, not its descriptor, which the system gives the
    /// next file opened once it is closed), and what it reaches.
    struct OpenSocket: Hashable, CustomStringConvertible {
        let device: Int64
        let inode: UInt64
        /// AF_INET, AF_INET6, AF_UNIX or another family, by number.
        let family: Int32
        /// The address at each end, "" where it has none: an IP address, or a Unix socket's path.
        let local: String
        let peer: String

        /// Whether it reaches past this Mac: an Internet socket with an end that is not the loopback address. A connection
        /// to a Mac, a relay or the web is one; the other tests' stand-ins on 127.0.0.1, and the system's own Unix sockets,
        /// are not.
        var reachesOut: Bool {
            guard family == AF_INET || family == AF_INET6 else { return false }
            let loopback = { (address: String) in address.isEmpty || address == "0.0.0.0" || address == "::" || address.hasPrefix("127.") || address == "::1" }
            return !loopback(local) || !loopback(peer)
        }

        var description: String { "family \(family) \(local) → \(peer)" }
    }

    /// The sockets this process has open.
    private func sockets() -> Set<OpenSocket> {
        var open = Set<OpenSocket>()
        for descriptor in 0..<getdtablesize() {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { continue }
            func address(_ read: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> (Int32, String) {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let got = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { read($0, &length) } }
                guard got == 0 else { return (-1, "") }
                let family = Int32(storage.ss_family)
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                switch family {
                case AF_INET:
                    var inet = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
                    inet_ntop(AF_INET, &inet.sin_addr, &text, socklen_t(text.count))
                    return (family, String(cString: text))
                case AF_INET6:
                    var inet6 = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee } }
                    inet_ntop(AF_INET6, &inet6.sin6_addr, &text, socklen_t(text.count))
                    return (family, String(cString: text))
                case AF_UNIX:
                    let path = withUnsafePointer(to: &storage) {
                        $0.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { unix in
                            withUnsafeBytes(of: unix.pointee.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                        }
                    }
                    return (family, path)
                default:
                    return (family, "")
                }
            }
            let (family, local) = address { getsockname(descriptor, $0, $1) }
            let (_, peer) = address { getpeername(descriptor, $0, $1) }
            open.insert(OpenSocket(device: Int64(info.st_dev), inode: UInt64(info.st_ino), family: family, local: local, peer: peer))
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

    /// Waits until the screens have sent nothing more for a moment: what one screen asks for as it opens has been asked.
    private func settled(_ world: DemoWorld) async throws {
        var count = -1
        let end = Date(timeIntervalSinceNow: 5)
        while count != world.asked.count, Date() < end {
            count = world.asked.count
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Whether the demo turned a request away as one it does not do, or for a thing it does not know: a screen sending
    /// it in the demo needs its answer in `Demo/Script/`, or the recording the thing it names.
    static func notAnswered(_ refusal: String?) -> Bool {
        guard let refusal else { return false }
        return refusal.hasPrefix("The demo does not do ") || refusal.localizedCaseInsensitiveContains("unknown")
    }

    /// Every route of `Route` opens in the demo, inside the Demo bar, and each request a screen sends as it opens is
    /// answered. No socket is opened that reaches past this Mac: other suites' stand-ins, which run beside this one in the
    /// same process, listen and connect on 127.0.0.1 only, so a socket counted here is the demo's, whenever it opened.
    @Test func everyScreenOpensInTheDemoWithNoSocket() async throws {
        let before = sockets()
        let (session, transport) = try await demo()
        #expect(session.connection == .demo)
        let screens = try DemoScreens.all(in: session.engine)
        let missing = Set(DemoRoute.allCases).subtracting(screens.map { DemoRoute($0.route) })
        #expect(missing.isEmpty, "routes DemoScreens.all does not open: \(missing.map(\.rawValue).sorted())")

        #expect(try await draws(FirstScreen(), session: AppSession()), "the first screen, with Try it without a Mac")
        #expect(try await draws(NavigationStack { RouteView(.home) }.demoBar(), session: session), "the Demo bar")
        let world = transport.world
        for (name, route) in screens {
            try await settled(world)
            let from = world.asked.count
            #expect(try await draws(NavigationStack { RouteView(route) }.demoBar(), session: session), "\(name) draws")
            try await settled(world)
            for asked in world.asked[from...] where Self.notAnswered(asked.refusal) {
                Issue.record("\(name) sent \(asked.method), which the demo answered: \(asked.refusal ?? "")")
            }
        }
        #expect(world.unanswered.isEmpty, "requests the demo's script does not answer: \(world.unanswered)")

        // Writing to a conversation and answering a card, the demo's two scripted answers, with the screens above.
        let orchestrator = try #require(session.engine.projects.first?.conversation)
        session.engine.openConversation(orchestrator)
        #expect(await session.engine.submit("Hello from the demo", to: orchestrator, steer: false) == .sent)
        #expect(try await eventually { session.engine.open[orchestrator]?.items.last?.text.hasPrefix("You said: \"Hello from the demo\"") == true })
        let need = try #require(session.engine.needs.first { $0.kind == "question" })
        try await session.engine.call("needs.answer", ["id": need.id, "answer": ["kind": "question", "text": "Everyone"]])

        let opened = sockets().subtracting(before).filter(\.reachesOut)
        #expect(opened.isEmpty, "the demo opened a socket: \(opened)")
    }

    @Test func theRecordingHoldsEveryKindOfCardItCan() async throws {
        let (session, _) = try await demo()
        let engine = session.engine
        #expect(engine.projects.map(\.name).sorted() == ["Demo project", "Demo project 2", "Demo site"])
        #expect(Set(engine.needs.map(\.kind)) == ["approval", "question", "decision", "reach", "rule", "limit"])
        // An approval of each sort: one the inbox holds for an agent's command, and one a project's switch asked for.
        #expect(engine.needs.contains { need in need.kind == "approval" && need.projectSwitch == nil && engine.inbox.contains { $0.id == need.id } })
        #expect(engine.needs.contains { $0.kind == "approval" && $0.projectSwitch == "fileWork" })
        #expect(engine.needs.first { $0.kind == "limit" }?.start?.agentName == "Forge")
        // Agents at work in the first two projects, a sub-chat among them whose report is still to come.
        for project in engine.projects where project.name != "Demo site" {
            #expect(engine.hubRuns(project.id).contains { $0.status == "working" }, "\(project.name)")
        }
        let reports = engine.projects.flatMap { engine.extras["reports"]?["projects"]?[$0.id]?.arrayValue ?? [] }
        #expect(reports.filter { $0["ended"] == .null }.count == 1)
        #expect(!engine.agents.isEmpty)
        #expect(engine.rootConversations.count >= 8)
        // Demo site keeps its work on GitHub: a pull request open, its checks passing, a finding on it, opened by its
        // orchestrator to fix an issue; and its diff, as the engine answered it.
        let site = try #require(engine.projects.first { $0.name == "Demo site" })
        let listing = try #require(GitHubWork.of(engine.extras["github"], project: site.id))
        let pull = try #require(listing.pulls.first)
        #expect(pull.state == "open" && pull.checks == "passing" && pull.mergeable == "yes")
        #expect(pull.findings.map(\.agentName) == ["Atlas"])
        #expect(pull.openedBy == site.conversation)
        #expect(listing.issues.contains { $0.id == pull.work && $0.state == "open" })
        let diff = try #require(DemoTransport.recorded()?.world.recordedAnswer("github.diff", ["projectId": site.id, "number": pull.number])?["diff"] as? String)
        #expect(PullRequestDiff(text: diff).files.map(\.path).contains("docs/walkthrough.md"))
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
        // The activity and the project's last words come in events of their own, after the conversation's (#926).
        #expect(try await eventually { engine.projects.first { $0.conversation == id }?.lastWords?.text == DemoReplies.answer(to: "Plan the launch") })
        #expect(try await eventually { engine.activity.allSatisfy { $0.conversationId != id } })
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
            // The inbox comes in an event of its own, after the needs (#926).
            #expect(try await eventually { !engine.inbox.contains { $0.id == need.id } })
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
        #expect(try await eventually { !engine.hubRuns(approval.projectId ?? "").contains { $0.conversationId == approval.conversationId } })

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
        #expect(try await eventually { !engine.hubRuns(project.id).contains { $0.conversationId == waiting.conversationId } })

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

// MARK: - The screens built since, answered (#684, third part)

extension DemoTests {
    @Test func aPullRequestIsReadMergedAndSentBack() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let site = try #require(engine.projects.first { $0.name == "Demo site" })
        let listing = { GitHubWork.of(engine.extras["github"], project: site.id) }
        let pull = try #require(listing()?.pulls.first)
        let key = PullRequestStore.Key(project: site.id, number: pull.number)
        let store = PullRequestStore()

        // Its diff, as the recording kept it, read into files.
        store.readDiff(key, through: engine)
        #expect(try await eventually { if case .read = store.diffs[key] { true } else { false } })
        if case .read(let diff)? = store.diffs[key] {
            #expect(diff.files.map(\.path) == ["docs/walkthrough.md", "site/steps.json", "README.md"])
        }
        // A number the listing does not hold, and a project with no repository, refused in the engine's words.
        let missing = PullRequestStore.Key(project: site.id, number: 99)
        store.readDiff(missing, through: engine)
        #expect(try await eventually { if case .refused = store.diffs[missing] { true } else { false } })
        let other = try #require(engine.projects.first { $0.name == "Demo project" })
        if case .failure(let refusal) = await PullRequestRequest.diff(project: other.id, number: 7).send(through: engine) {
            #expect(refusal.words == "This project has no repository attached.")
        } else {
            Issue.record("a project with no repository sent a diff")
        }

        // Send back: the reason goes to the conversation that opened it, which answers.
        let opener = try #require(pull.openedBy)
        engine.openConversation(opener)
        #expect(try await eventually { engine.open[opener]?.state != nil })
        store.send(.sendBack(project: site.id, number: pull.number, reason: "Add the timings."), for: key, shown: "Sending back", through: engine)
        #expect(store.pending[key] == "Sending back")
        #expect(try await eventually { store.pending[key] == nil })
        #expect(store.problems[key] == nil)
        let sent = "The person sent back pull request #\(pull.number): Add the timings."
        #expect(try await eventually { engine.open[opener]?.items.contains { $0.kind == "marker" && $0.text == sent } == true })
        #expect(try await eventually { engine.open[opener]?.items.last?.text == DemoReplies.answer(to: sent) })
        #expect(await PullRequestRequest.sendBack(project: site.id, number: pull.number, reason: " ").send(through: engine)
            == .failure(PullRequestRefusal(words: "Say why it goes back, in text.")))

        // Merge: merged, and the issue it fixes closed as done.
        let fixes = try #require(pull.work)
        store.send(.merge(project: site.id, number: pull.number), for: key, shown: "Merging", through: engine)
        #expect(try await eventually { listing()?.pull(pull.number)?.state == "merged" })
        #expect(store.problems[key] == nil)
        #expect(listing()?.issues.first { $0.id == fixes }?.state == "done")
        // Merging again changes nothing; a write whose outcome is known is not settled.
        #expect(await PullRequestRequest.merge(project: site.id, number: pull.number).send(through: engine) == .success(.object([:])))
        #expect(await PullRequestRequest.settle(project: site.id, intent: "i-1", happened: true).send(through: engine)
            == .failure(PullRequestRefusal(words: "That write is not waiting to be settled.")))

        // Work opens the closed issue whole, as the recording read it; one GitHub does not have is refused.
        let closed = try #require(listing()?.issues.first { $0.id == 1 })
        #expect(closed.text.isEmpty)
        #expect(await WorkRequests.show(engine, project: site.id, number: 1) == nil)
        #expect(try await eventually { listing()?.issues.first { $0.id == 1 }?.text == "A page for each step, built from Markdown." })
        #expect(await WorkRequests.show(engine, project: site.id, number: 98) == "Unknown work item: #98")
        #expect(await WorkRequests.refresh(engine, project: site.id) == nil)
        // Filing on GitHub: numbered after the pull request, in the listing.
        #expect(await WorkRequests.create(engine, project: site.id, title: "Time each step", text: "") == nil)
        #expect(try await eventually { listing()?.issues.contains { $0.id == pull.number + 1 && $0.title == "Time each step" } == true })
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func theBoardMakesChangesAndRemovesAgents() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let site = try #require(engine.projects.first { $0.name == "Demo site" })
        let agents = { engine.allAgents.filter { $0.projectId == site.id } }

        // A new agent by hand, then one of the same name refused.
        guard case .success(let made) = await BoardRequests.newAgent(engine, project: site.id, named: "Quill") else {
            Issue.record("no agent was made")
            return
        }
        #expect(try await eventually { agents().contains { $0.id == made && $0.name == "Quill" && $0.cwd == site.folder } })
        #expect(await BoardRequests.newAgent(engine, project: site.id, named: "quill") == .failure(BoardFailure("There is already an agent called quill")))

        // Saved with what the page changed; duplicated; deleted.
        var draft = try #require(engine.agent(made))
        let base = draft
        draft.description = "Writes the walkthrough's pages."
        #expect(await BoardRequests.save(engine, draft: draft, edited: BoardAgentDraft.edited(draft, from: base)) == nil)
        #expect(try await eventually { engine.agent(made)?.description == "Writes the walkthrough's pages." })
        guard case .success(let copy) = await BoardRequests.duplicate(engine, agent: made) else {
            Issue.record("no copy was made")
            return
        }
        #expect(try await eventually { engine.agent(copy)?.name == "Quill copy" && engine.agent(copy)?.projectId == site.id })
        #expect(await BoardRequests.delete(engine, agent: copy) == nil)
        #expect(try await eventually { engine.agent(copy) == nil })
        #expect(await BoardRequests.delete(engine, agent: site.orchestratorId)?.hasSuffix("is the project's orchestrator. Make another agent the orchestrator first.") == true)
        #expect(await BoardRequests.restore(engine, agent: made) == nil)

        // A copy of a template changed since: Update from Template says what it brings, then brings it.
        let scout = try #require(agents().first { $0.template != nil })
        guard case .success(let changes) = await BoardRequests.templateChanges(engine, agent: scout.id) else {
            Issue.record("no changes were read")
            return
        }
        #expect(changes.map(\.setting) == ["description"])
        #expect(await BoardRequests.updateFromTemplate(engine, agent: scout.id) == nil)
        #expect(try await eventually { engine.agent(scout.id)?.description == engine.agent("scout")?.description })
        #expect(await BoardRequests.templateChanges(engine, agent: scout.id) == .success([]))
        // And a template copied in now.
        guard case .success(let forge) = await BoardRequests.copyTemplate(engine, project: site.id, template: "forge") else {
            Issue.record("no template was copied")
            return
        }
        #expect(try await eventually { engine.agent(forge)?.template?.id == "forge" })

        // An allowed command, in the project's folder, then taken away.
        let folder = try #require(site.folder)
        #expect(await BoardRequests.allowCommand(engine, agent: made, folder: folder, command: "npm test") == nil)
        let rule = try #require(try await eventuallyValue { engine.agent(made)?.commandRules?.first })
        #expect(rule.words == ["npm", "test"])
        #expect(await BoardRequests.allowCommand(engine, agent: made, folder: "/nowhere", command: "npm test") == "Not a folder: /nowhere")
        #expect(await BoardRequests.allowCommand(engine, agent: made, folder: folder, command: "npm test | tee")?.hasPrefix("“|” is not a plain word") == true)
        #expect(await BoardRequests.removeCommand(engine, agent: made, rule: rule) == nil)
        #expect(try await eventually { engine.agent(made)?.commandRules?.isEmpty == true })
        #expect(await BoardRequests.removeCommand(engine, agent: made, rule: rule) == "That allowed command is already gone")

        // A conversation with the new agent, which answers.
        guard case .success(let conversation) = await BoardRequests.newConversation(engine, agent: made) else {
            Issue.record("no conversation was made")
            return
        }
        #expect(try await eventually { engine.conversations.contains { $0.id == conversation && $0.projectId == site.id } })
        engine.openConversation(conversation)
        #expect(await engine.submit("Draft the first page", to: conversation, steer: false) == .sent)
        #expect(try await eventually { engine.open[conversation]?.items.last?.text == DemoReplies.answer(to: "Draft the first page") })

        // The new agent made orchestrator, with a fresh conversation; the one before is an earlier one.
        let before = try #require(site.conversation)
        #expect(await BoardRequests.makeOrchestrator(engine, project: site.id, agent: made) == nil)
        #expect(try await eventually { engine.hubProject(site.id)?.orchestratorId == made })
        #expect(engine.agent(made)?.role == "orchestrator" && engine.agent(site.orchestratorId)?.role == nil)
        #expect(engine.hubProject(site.id)?.conversation != before)
        #expect(engine.conversations.first { $0.id == before }?.orchestrator == "earlier")
        #expect(await BoardRequests.makeOrchestrator(engine, project: site.id, agent: made)?.hasSuffix("is the project's orchestrator already. To begin again with it, start a fresh conversation.") == true)
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func aConversationGetsAWorktreeOfItsOwnAndGivesItBack() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        let site = try #require(engine.projects.first { $0.name == "Demo site" })
        let id = try #require(site.conversation)
        let main = try #require(engine.branches[id])
        #expect(!main.managed && main.branch == "walkthrough-script")

        let suggested = try #require(await BoardRequests.suggestBranch(engine, conversation: id))
        #expect(suggested.hasPrefix("pi2/"))
        #expect(await BoardRequests.createWorktree(engine, conversation: id, branch: "") == nil)
        #expect(try await eventually { engine.branches[id]?.managed == true })
        let own = try #require(engine.branches[id])
        #expect(own.branch == suggested && own.worktree && own.base == "walkthrough-script" && own.state == "clean")
        #expect(BoardData(engine).branchGroups(site.id).flatMap(\.rows).contains { $0.id == id && $0.status.managed })
        #expect(await BoardRequests.createWorktree(engine, conversation: id, branch: "") == "This conversation already has a worktree of its own")
        #expect(await BoardRequests.removeWorktree(engine, conversation: id, force: false, deleteBranch: true) == .success(nil))
        #expect(try await eventually { engine.branches[id] == main })
        #expect(await BoardRequests.removeWorktree(engine, conversation: id, force: false, deleteBranch: false)
            == .failure(BoardFailure("This conversation has no worktree of its own")))

        // A conversation outside any git repository.
        let other = try #require(engine.projects.first { $0.name == "Demo project" }?.conversation)
        #expect(await BoardRequests.createWorktree(engine, conversation: other, branch: "x") == "This conversation's folder is not in a git repository")
        #expect(transport.world.unanswered.isEmpty)
    }

    @Test func aScheduleRunsNow() async throws {
        let (session, transport) = try await demo()
        let engine = session.engine
        // The recording holds no schedule (the settings' tests count on none): one saved as Schedules saves it.
        let agent = try #require(engine.agents.first { $0.name == "Atlas" }?.id)
        let made = Schedule(id: "", title: "Morning summary", agentId: agent, prompt: "Summarise what changed overnight.",
                            repeat: Repeat(kind: "daily", hour: 9, minute: 0), enabled: true)
        #expect(await SettingsRequest.saveSchedule(made, isNew: true).send(through: engine) == nil)
        #expect(try await eventually { !engine.schedules.isEmpty })
        let schedule = try #require(engine.schedules.first)
        let before = Set(engine.conversations.map(\.id))
        #expect(await SettingsRequest.runSchedule(schedule.id).send(through: engine) == nil)
        let ran = try #require(try await eventuallyValue { engine.conversations.first { !before.contains($0.id) } })
        #expect(ran.title == schedule.title && ran.agentId == schedule.agentId)
        #expect(try await eventually { engine.schedules.first?.lastConversationId == ran.id })
        engine.openConversation(ran.id)
        #expect(try await eventually { engine.open[ran.id]?.items.last?.text == DemoReplies.answer(to: schedule.prompt) })
        #expect(await SettingsRequest.runSchedule("s-none").send(through: engine) == "Unknown schedule: s-none")
        #expect(transport.world.unanswered.isEmpty)
    }
}
