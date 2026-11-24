import Foundation
import SwiftUI
import Testing
@testable import pi2

/// The seam the screens are built on (docs/iphone-app.md): the session over the debug build's replay of the recorded
/// session, and the routes.
@MainActor
struct AppSeamTests {
    /// Waits for `condition`, polling, for at most `seconds`: the replay hands the client its lines on the main actor, a
    /// little after it is started.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func replayListsTheRecordingsProjects() async throws {
        let transport = try #require(ReplayTransport.recording(), "the recording is copied into a debug build's bundle")
        let session = AppSession()
        session.start(transport, as: .connected(.relay))
        #expect(session.connection == .connected(.relay))

        #expect(try await eventually { !session.engine.projects.isEmpty })
        #expect(session.engine.status == .connected)
        #expect(session.engine.projects.map(\.name).sorted() == ["Demo project", "Demo project 2"])
        #expect(!session.engine.needs.isEmpty)
        #expect(!session.engine.rootConversations.isEmpty)

        // A conversation's entries come when it is opened, as from the engine.
        let orchestrator = try #require(session.engine.projects.first { $0.name == "Demo project" }?.conversation)
        session.engine.openConversation(orchestrator)
        #expect(try await eventually { session.engine.open[orchestrator]?.items.isEmpty == false })

        // A request the recording cannot answer fails, rather than waiting.
        await #expect(throws: (any Error).self) { try await session.engine.call("project.rename", ["id": "x", "name": "y"]) }
    }

    @Test func everyRouteResolvesToItsFeaturesView() {
        let routes: [(Route, any View.Type)] = [
            (.home, HomeView.self),
            (.project("p-1", tab: .now), HubView.self),
            (.dashboard(), DashboardView.self),
            (.dashboard(project: "p-1"), DashboardView.self),
            (.conversation(9), ConversationView.self),
            (.needs(), NeedsView.self),
            (.needs(project: "p-1"), NeedsView.self),
            (.work(project: "p-1"), WorkView.self),
            (.work(project: "p-1", item: 12), WorkView.self),
            (.pullRequest(project: "p-1", number: 7), PullRequestView.self),
            (.pullRequest(project: "p-1", number: 7, file: "a/b.swift"), PullRequestView.self),
            (.board(project: "p-1", page: .rules), BoardView.self),
            (.agent("forge", project: "p-1"), BoardAgentView.self),
            (.agent("forge"), BoardAgentView.self),
            (.templates, BoardTemplatesView.self),
            (.projectSettings("p-1"), ProjectSettingsView.self),
            (.settings, SettingsView.self),
            (.schedules, SchedulesView.self),
            (.usage, UsageView.self),
            (.conversations(), ConversationsView.self),
            (.conversations(project: "p-1"), ConversationsView.self),
            (.archive, ArchiveView.self),
            (.backgroundCommands(), BackgroundCommandsView.self),
            (.backgroundCommands(output: "bg-1"), BackgroundCommandsView.self),
            (.newProject, NewProjectView.self),
            (.outbox, OutboxView.self),
        ]
        for (route, expected) in routes {
            let view = RouteView.view(for: route)
            #expect(ObjectIdentifier(type(of: view)) == ObjectIdentifier(expected), "\(route)")
        }
        let hub = RouteView.view(for: .project("p-1", tab: .now)) as? HubView
        #expect(hub?.projectID == "p-1")
        #expect(hub?.tab == .now)
        #expect((RouteView.view(for: .conversation(9)) as? ConversationView)?.conversationID == 9)

        // What each route carries reaches its view's initialiser.
        let work = RouteView.view(for: .work(project: "p-1", item: 12)) as? WorkView
        #expect(work?.projectID == "p-1" && work?.itemID == 12)
        let pull = RouteView.view(for: .pullRequest(project: "p-1", number: 7, file: "a/b.swift")) as? PullRequestView
        #expect(pull?.projectID == "p-1" && pull?.number == 7 && pull?.file == "a/b.swift")
        let board = RouteView.view(for: .board(project: "p-1", page: .rules)) as? BoardView
        #expect(board?.projectID == "p-1" && board?.page == .rules)
        let agent = RouteView.view(for: .agent("forge", project: "p-1")) as? BoardAgentView
        #expect(agent?.agentID == "forge" && agent?.projectID == "p-1")
        #expect((RouteView.view(for: .agent("forge")) as? BoardAgentView)?.projectID == nil)
        #expect((RouteView.view(for: .projectSettings("p-1")) as? ProjectSettingsView)?.projectID == "p-1")
        #expect((RouteView.view(for: .conversations(project: "p-1")) as? ConversationsView)?.projectID == "p-1")
        #expect((RouteView.view(for: .backgroundCommands(output: "bg-1")) as? BackgroundCommandsView)?.commandID == "bg-1")
    }

    @Test func openingRoutesMovesThePath() {
        let navigator = Navigator()
        navigator.open(.project("p-1"))
        navigator.open(.project("p-1", tab: .now))
        #expect(navigator.path == [.project("p-1", tab: .now)])
        navigator.open(.conversation(9))
        navigator.open(.project("p-1", tab: .work))
        #expect(navigator.path == [.project("p-1", tab: .now), .conversation(9), .project("p-1", tab: .work)])
        navigator.open(.home)
        #expect(navigator.path.isEmpty)
    }

    @Test func showNamesARouteByProjectNameOrID() async throws {
        let transport = try #require(ReplayTransport.recording())
        let session = AppSession()
        session.start(transport, as: .connected(.home))
        #expect(try await eventually { session.engine.projects.count == 2 })
        let projects = session.engine.projects
        let id = try #require(projects.first { $0.name == "Demo project 2" }?.id)
        #expect(DebugLaunch.route("project:Demo project 2#now", projects: projects) == .project(id, tab: .now))
        #expect(DebugLaunch.route("project:\(id)", projects: projects) == .project(id, tab: .chat))
        #expect(DebugLaunch.route("project:Nowhere", projects: projects) == nil)
        #expect(DebugLaunch.route("dashboard", projects: []) == .dashboard())
        #expect(DebugLaunch.route("conversation:9", projects: []) == .conversation(9))
        #expect(DebugLaunch.route("needs:Demo project 2", projects: projects) == .needs(project: id))
        #expect(DebugLaunch.connection(named: "home-relay-down") == .connected(.home, relayReachable: false))

        // The next screens' words.
        let shown: [(String, Route?)] = [
            ("work:Demo project 2", .work(project: id)),
            ("work:Demo project 2#12", .work(project: id, item: 12)),
            ("work:Demo project 2#twelve", nil),
            ("work:Nowhere", nil),
            ("pull-request:Demo project 2#7", .pullRequest(project: id, number: 7)),
            ("pull-request:\(id)#7:app/Sources/a b.swift", .pullRequest(project: id, number: 7, file: "app/Sources/a b.swift")),
            ("pull-request:Demo project 2", nil),
            ("board:Demo project 2", .board(project: id, page: .agents)),
            ("board:Demo project 2#branches", .board(project: id, page: .branches)),
            ("board:Demo project 2#settings", nil),
            ("agent:forge", .agent("forge")),
            ("agent:Demo project 2#forge", .agent("forge", project: id)),
            ("agent:Nowhere#forge", nil),
            ("agent:", nil),
            ("templates", .templates),
            ("project-settings:Demo project 2", .projectSettings(id)),
            ("project-settings", nil),
            ("settings", .settings),
            ("schedules", .schedules),
            ("usage", .usage),
            ("usage:x", nil),
            ("conversations", .conversations()),
            ("conversations:Demo project 2", .conversations(project: id)),
            ("archive", .archive),
            ("background-commands", .backgroundCommands()),
            ("background-commands:bg-1", .backgroundCommands(output: "bg-1")),
            ("new-project", .newProject),
            ("nothing", nil),
        ]
        for (text, route) in shown {
            #expect(DebugLaunch.route(text, projects: projects) == route, "\(text)")
        }
    }
}
