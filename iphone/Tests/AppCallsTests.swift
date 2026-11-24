
import Foundation
import Testing
@testable import pi2

/// The calls `App/` makes for the parts built as units (#901, `App/PhoneSurfaces.swift`): the widgets' file kept in step
/// with the session and their links opened as routes, with stand-ins for the app group's folders, WidgetKit and iOS.
@MainActor
@Suite(.serialized)
struct AppCallsTests {
    nonisolated static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session on the recording, as connected, once its library has come.
    static func replay(as connection: AppSession.Connection = .connected(.home)) async throws -> AppSession {
        let session = AppSession()
        session.macName = "Recorded Mac"
        session.start(try #require(ReplayTransport.recording()), as: connection)
        #expect(await Wait.until { session.engine.hasLoadedLibrary && !session.engine.projects.isEmpty })
        return session
    }

    /// The widgets' publisher on a folder of the test's own, counting WidgetKit's reloads.
    @MainActor
    final class Widgets {
        let file: WidgetsFile
        var reloads = 0
        lazy var publisher = WidgetsPublisher(file: file, reload: { [weak self] in self?.reloads += 1 })

        init() throws {
            file = WidgetsFile(folder: try AppCallsTests.folder("widgets"))
        }
    }

    // MARK: - Widgets (#699)

    @Test func theWidgetsFollowThePairedSession() async throws {
        let session = try await Self.replay()
        let widgets = try Widgets()
        var paired = true
        let surfaces = PhoneSurfaces(session: session, widgets: widgets.publisher, paired: { paired }, lastHeard: { nil })

        #expect(await Wait.until {
            surfaces.movedToBackground()
            return widgets.file.read() != nil
        }, "written once the client holds the Mac's state, at the latest when the app leaves the foreground")
        let written = try #require(widgets.file.read())
        #expect(written.needs.count == session.engine.needs.count)
        #expect(written.macName == "Recorded Mac")
        #expect(widgets.reloads >= 1)

        // The pairing ends: the file goes, and nothing more is written.
        surfaces.forgetTheMac()
        #expect(widgets.file.read() == nil)
        paired = false
        session.connection = .outOfReach(lastSeen: nil)
        try await Task.sleep(for: .milliseconds(100))
        surfaces.movedToBackground()
        #expect(widgets.file.read() == nil)
    }

    @Test func nothingIsWrittenBeforePairingNorInTheDemo() async throws {
        let session = try await Self.replay()
        let widgets = try Widgets()
        let surfaces = PhoneSurfaces(session: session, widgets: widgets.publisher, paired: { false }, lastHeard: { nil })
        try await Task.sleep(for: .milliseconds(100))
        surfaces.movedToBackground()
        #expect(widgets.file.read() == nil, "not paired")

        // Paired, then the demo: its values are not the Mac's, and the file goes.
        let paired = try await Self.replay()
        let file = try Widgets()
        let following = PhoneSurfaces(session: paired, widgets: file.publisher, paired: { true }, lastHeard: { nil })
        #expect(await Wait.until { following.movedToBackground(); return file.file.read() != nil })
        paired.connection = .demo
        #expect(await Wait.until { file.file.read() == nil })
    }

    @Test func outOfReachTheWidgetsSayWhenTheMacWasLastHeard() async throws {
        let heard = Date(timeIntervalSinceNow: -3_600)
        let session = try await Self.replay(as: .outOfReach(lastSeen: heard))
        let widgets = try Widgets()
        let surfaces = PhoneSurfaces(session: session, widgets: widgets.publisher, paired: { true }, lastHeard: { heard })
        #expect(await Wait.until { surfaces.movedToBackground(); return widgets.file.read() != nil })
        let written = try #require(widgets.file.read())
        #expect(abs(written.heardAt.timeIntervalSince(heard)) < 0.01)
    }

    @Test func aSweepThatWipesTheMacsStateClearsTheWidgets() async throws {
        let session = try await Self.replay()
        let widgets = try Widgets()
        let surfaces = PhoneSurfaces(session: session, widgets: widgets.publisher, paired: { true }, lastHeard: { nil })
        #expect(await Wait.until { surfaces.movedToBackground(); return widgets.file.read() != nil })
        surfaces.swept([.outbox])
        #expect(widgets.file.read() != nil, "the Outbox alone going leaves the Mac's state")
        surfaces.swept([.cache])
        #expect(widgets.file.read() == nil)
    }

    @Test func aWidgetsLinkOpensItsRoute() throws {
        let links: [(WidgetsLink, Route)] = [
            (.needs(), .needs()),
            (.needs(project: "p-1", need: "n-2"), .needs(project: "p-1")),
            (.conversation(139), .conversation(139)),
            (.dashboard(), .dashboard()),
            (.dashboard(project: "p-1"), .dashboard(project: "p-1")),
            (.usage, .usage),
        ]
        for (link, route) in links {
            #expect(link.route == route)
            #expect(PhoneSurfaces.route(for: link.url) == route, "\(link.url)")
        }
        #expect(PhoneSurfaces.route(for: try #require(URL(string: "https://example.com/needs"))) == nil)
        #expect(PhoneSurfaces.route(for: try #require(URL(string: "pi2-widget://elsewhere"))) == nil)
    }

    @Test func aTapWaitsAsTheRouteToOpen() async throws {
        let session = AppSession()
        let surfaces = PhoneSurfaces(session: session, widgets: try Widgets().publisher, paired: { false }, lastHeard: { nil })
        #expect(!surfaces.open(try #require(URL(string: "pi2://pair?x=1"))))
        #expect(surfaces.pendingRoute == nil)
        #expect(surfaces.open(WidgetsLink.usage.url))
        #expect(surfaces.pendingRoute == .usage)
    }
}
