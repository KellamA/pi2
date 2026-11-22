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
        ]
        for (route, expected) in routes {
            let view = RouteView.view(for: route)
            #expect(ObjectIdentifier(type(of: view)) == ObjectIdentifier(expected), "\(route)")
        }
        let hub = RouteView.view(for: .project("p-1", tab: .now)) as? HubView
        #expect(hub?.projectID == "p-1")
        #expect(hub?.tab == .now)
        #expect((RouteView.view(for: .conversation(9)) as? ConversationView)?.conversationID == 9)
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
    }
}
