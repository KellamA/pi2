
import Foundation
import PiModels
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

    // MARK: - The share sheet (#702)

    static let orchestrator = ShareDestination(conversation: 9, kind: .orchestrator, title: "Demo project", project: "Demo project")

    @Test func theShareSheetsListIsWrittenWhileConnectedOnly() async throws {
        let session = try await Self.replay()
        let drop = ShareDrop(folder: try Self.folder("share"))
        let surfaces = PhoneSurfaces(session: session, widgets: try Widgets().publisher, share: drop, paired: { true }, lastHeard: { nil })
        #expect(await Wait.until { drop.destinations(at: Date()) != nil })
        let list = try #require(drop.destinations(at: Date()))
        #expect(list.macName == "Recorded Mac")
        #expect(list.destinations.contains { $0.kind == .orchestrator && $0.title == "Demo project" })
        _ = surfaces

        // Not before pairing, nor in the demo, nor out of reach from the store's last state.
        for (connection, paired) in [(AppSession.Connection.connected(.home), false), (.demo, true), (.outOfReach(lastSeen: nil), true)] {
            let other = try await Self.replay(as: connection)
            let none = ShareDrop(folder: try Self.folder("share"))
            let following = PhoneSurfaces(session: other, widgets: try Widgets().publisher, share: none, paired: { paired }, lastHeard: { nil })
            try await Task.sleep(for: .milliseconds(100))
            #expect(none.destinations(at: Date()) == nil, "\(connection), paired: \(paired)")
            _ = following
        }
    }

    @Test func aSharedDraftGoesOnTheChannelAndItsConversationOpens() async throws {
        let drop = ShareDrop(folder: try Self.folder("share"))
        let draft = ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "Look at this", attachments: [])
        try drop.add(draft)
        var sent: [(String, [String: Any])] = []
        var way = AppShareSender.Way.none
        let surfaces = PhoneSurfaces(
            session: AppSession(), widgets: try Widgets().publisher, share: drop, paired: { true }, lastHeard: { nil },
            shareWay: { way }, keep: { _, _ in Issue.record("nothing goes to the Outbox while connected") })
        // Locked: nothing goes, nothing is lost.
        #expect(await surfaces.pickUpShares() == nil)
        #expect(drop.all().map(\.id) == [draft.id])

        way = .channel
        let report = await surfaces.pickUpShares(through: AppShareSender(way: { way }, call: { method, params in sent.append((method, params)) }, keep: { _, _ in }))
        #expect(report?.taken == [draft.id])
        #expect(sent.map(\.0) == ["submit"])
        #expect(sent.first?.1["requestId"] as? String == draft.id, "the draft's id is the message's request id")
        #expect(sent.first?.1["id"] as? Int == 9)
        #expect(drop.all().isEmpty)
        #expect(surfaces.pendingRoute == .conversation(9), "shared moments ago: its conversation opens")
    }

    @Test func outOfReachWordsWaitInTheOutboxAndAPhotoWaitsInTheFolder() async throws {
        let drop = ShareDrop(folder: try Self.folder("share"))
        let old = Date(timeIntervalSinceNow: -3_600)
        let words = ShareDraft(writtenAt: old, destination: Self.orchestrator, text: "On the train", attachments: [])
        let photo = ShareDraft(writtenAt: old.addingTimeInterval(1), destination: Self.orchestrator, text: "This", attachments: [.picture(name: "a.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))])
        try drop.add(words)
        try drop.add(photo)
        var kept: [String] = []
        let sender = AppShareSender(way: { .outbox }, call: { _, _ in Issue.record("nothing goes on the channel out of reach") }, keep: { method, params in
            kept.append(params["requestId"] as? String ?? method)
        })
        let surfaces = PhoneSurfaces(session: AppSession(), widgets: try Widgets().publisher, share: drop, paired: { true }, lastHeard: { nil }, shareWay: { .outbox })
        let report = try #require(await surfaces.pickUpShares(through: sender))
        #expect(report.kept == [words.id])
        #expect(kept == [words.id])
        #expect(report.stopped == AppShareSender.waitsForTheMac)
        #expect(drop.all().map(\.id) == [photo.id], "the photo waits for the Mac")
        #expect(surfaces.pendingRoute == nil, "shared an hour ago: nothing is opened")
    }

    @Test func theSendersAnswersAreTheOutboxCouriers() async throws {
        let draft = ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "Hi", attachments: [])
        let refused = AppShareSender(way: { .channel }, call: { _, _ in throw EngineError(message: "No such conversation.") }, keep: { _, _ in })
        #expect(await refused.deliver(draft) == .refused("No such conversation."))
        let lost = AppShareSender(way: { .channel }, call: { _, _ in throw EngineError(message: "Not connected.", unanswered: true) }, keep: { _, _ in })
        #expect(await lost.deliver(draft) == .unreachable("Not connected."))
        let full = AppShareSender(way: { .outbox }, call: { _, _ in }, keep: { _, _ in throw StoreError("The Outbox is full.") })
        #expect(await full.deliver(draft) == .refused("The Outbox is full."))
        let locked = AppShareSender(way: { .none }, call: { _, _ in }, keep: { _, _ in })
        #expect(await locked.deliver(draft) == .unreachable(AppShareSender.locked))
    }

    @Test func forgettingTheMacWipesTheShareFolder() throws {
        let drop = ShareDrop(folder: try Self.folder("share"))
        try drop.add(ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "Hi", attachments: []))
        let surfaces = PhoneSurfaces(session: AppSession(), widgets: try Widgets().publisher, share: drop, paired: { true }, lastHeard: { nil })
        surfaces.forgetTheMac()
        #expect(!FileManager.default.fileExists(atPath: drop.folder.path))
    }

    // MARK: - Notifications (#690)

    @Test func aNotificationOpensItsCardsScreen() {
        func route(_ info: [AnyHashable: Any], action: String = "com.apple.UNNotificationDefaultActionIdentifier") -> Route {
            PushResponse(action: action, userInfo: info, reply: nil).route
        }
        #expect(route(["need": "n-1", "kind": "approval", "projectId": "p-1", "conversationId": 9]) == .needs(project: "p-1"))
        #expect(route(["need": "n-1", "kind": "question", "projectId": ""], action: "reply") == .needs(), "a card outside projects")
        #expect(route(["kind": "notice", "projectId": "p-1", "conversationId": 9]) == .conversation(9), "an orchestrator's answer")
        #expect(route(["kind": "notice", "projectId": "p-1"]) == .project("p-1", tab: .chat))
        #expect(route([:]) == .needs(), "the placeholder names nothing: all of Needs you")
    }

    @Test func theCategoriesAreSetAtLaunchAndATapWaitsForFaceID() throws {
        let surfaces = PhoneSurfaces(session: AppSession(), widgets: try Widgets().publisher, paired: { false }, lastHeard: { nil })
        surfaces.pushTapped(PushResponse(action: "open", userInfo: ["need": "n-1", "kind": "rule", "projectId": "p-2"], reply: nil))
        #expect(surfaces.pendingRoute == .needs(project: "p-2"))
        // Pi2App.init installs the app's delegate in the test host too.
        #expect(AppNotifications.shared.surfaces != nil)
        #expect(PushCategories.all.count == PushKind.allCases.count + PushKind.allCases.filter(\.hasCutCategory).count)
    }

    @Test func aNeedTheMacNoLongerListsTakesItsNotificationsAway() async throws {
        // The demo answers needs.answer as the engine does; started as a connected Mac for this test.
        let session = AppSession()
        session.start(try #require(DemoTransport.recorded()), as: .connected(.home))
        #expect(await Wait.until { session.engine.hasLoadedLibrary && !session.engine.needs.isEmpty })
        var gone: [Set<String>] = []
        var paired = true
        let surfaces = PhoneSurfaces(
            session: session, widgets: try Widgets().publisher, paired: { paired }, lastHeard: { nil }, takeAway: { gone.append($0) })
        let need = try #require(session.engine.needs.first { $0.kind == "question" })
        _ = try await session.engine.call("needs.answer", ["id": need.id, "answer": ["kind": "question", "text": "Everyone"]])
        #expect(await Wait.until { gone.contains([need.id]) })
        #expect(gone == [[need.id]], "only the need that went")

        // The pairing ends: the extension's notices go too.
        let inbox = PushInbox(folder: try Self.folder("push"))
        let ending = PhoneSurfaces(session: AppSession(), widgets: try Widgets().publisher, paired: { false }, lastHeard: { nil }, pushInbox: inbox)
        try FileManager.default.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
        ending.pairingEnded()
        #expect(!FileManager.default.fileExists(atPath: inbox.folder.path))
        paired = false
        _ = surfaces
    }

    // MARK: - The Live Activity (#700)

    /// ActivityKit standing in: what runs, and every call.
    @MainActor
    final class StandInActivities: ProjectActivityControl {
        var areAllowed = true
        var refusal: ProjectActivityRefusal?
        var running: [String: ProjectActivities.State] = [:]
        var calls: [String] = []

        func shown(projectID: String) -> ProjectActivities.State? { running[projectID] }

        func start(projectID: String, projectName: String, state: ProjectActivities.State) async throws {
            calls.append("start \(projectName)")
            if let refusal { throw refusal }
            running[projectID] = state
        }

        func end(projectID: String) async {
            calls.append("end \(projectID)")
            running[projectID] = nil
        }

        func endAll() async {
            calls.append("endAll")
            running = [:]
        }

        func reconcile(followed: [(id: String, name: String)], state: (String) -> ProjectActivities.State?) async -> [String: ProjectActivityRefusal] {
            calls.append("reconcile \(followed.map(\.name).joined(separator: ","))")
            for project in followed { running[project.id] = state(project.id) }
            return [:]
        }
    }

    @Test func theSwitchStartsAndEndsTheProjectsActivityAndIsKept() async throws {
        let session = try await Self.replay()
        let control = StandInActivities()
        let file = try Self.folder("live").appending(path: "followed.json")
        let surfaces = PhoneSurfaces(session: session, widgets: try Widgets().publisher, paired: { true }, lastHeard: { nil }, activityControl: control, activitiesFile: file)
        let project = try #require(session.engine.projects.first { $0.name == "Demo project" })
        let following = surfaces.activities
        #expect(!following.isOn(project.id), "off by default")

        await following.turnOn(project)
        #expect(control.calls == ["start Demo project"])
        let started = try #require(control.running[project.id])
        let counted = ProjectActivities.State.counted(projectID: project.id, activity: session.engine.activity, needs: session.engine.needs, finished: 0, at: Date())
        #expect((started.working, started.needs, started.finished) == (counted.working, counted.needs, 0), "the project's numbers, as the Mac counts them")
        #expect(following.isOn(project.id))
        #expect(ProjectActivityFollowing(session: session, control: control, file: file, heardAt: { nil }).isOn(project.id), "kept on the phone")

        await following.turnOff(project.id)
        #expect(control.calls.last == "end \(project.id)")
        #expect(!following.isOn(project.id))
        #expect(!ProjectActivityFollowing(session: session, control: control, file: file, heardAt: { nil }).isOn(project.id))
    }

    @Test func aRefusalShowsUnderTheSwitchWhichStaysOff() async throws {
        let session = try await Self.replay()
        let control = StandInActivities()
        let surfaces = PhoneSurfaces(session: session, widgets: try Widgets().publisher, paired: { true }, lastHeard: { nil }, activityControl: control, activitiesFile: nil)
        let project = try #require(session.engine.projects.first)

        control.areAllowed = false
        await surfaces.activities.turnOn(project)
        #expect(!surfaces.activities.allowed)
        #expect(surfaces.activities.problems[project.id] == ProjectActivityRefusal.notAllowed.words)
        #expect(control.calls.isEmpty, "nothing asked of iOS while it has them off")

        control.areAllowed = true
        control.refusal = ProjectActivityRefusal(words: "iOS shows too many Live Activities already. End one, then try again.")
        await surfaces.activities.turnOn(project)
        #expect(surfaces.activities.problems[project.id] == control.refusal?.words)
        #expect(!surfaces.activities.isOn(project.id))
    }

    @Test func theForegroundReconcilesAndTheEndOfThePairingEndsThemAll() async throws {
        let session = try await Self.replay()
        let control = StandInActivities()
        let file = try Self.folder("live").appending(path: "followed.json")
        let surfaces = PhoneSurfaces(session: session, widgets: try Widgets().publisher, paired: { true }, lastHeard: { nil }, activityControl: control, activitiesFile: file)
        let project = try #require(session.engine.projects.first { $0.name == "Demo project 2" })
        await surfaces.activities.turnOn(project)
        control.calls = []
        // iOS ended it meanwhile (eight hours): coming to the foreground brings it back in line.
        control.running = [:]
        surfaces.movedToForeground()
        #expect(await Wait.until { control.calls.contains("reconcile Demo project 2") })
        #expect(control.running[project.id] != nil)
        surfaces.movedToBackground()

        surfaces.pairingEnded()
        #expect(await Wait.until { control.calls.last == "endAll" })
        #expect(surfaces.activities.followed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aLiveActivitysTapOpensTheProjectsHubOnNow() {
        #expect(PhoneSurfaces.route(for: ProjectActivityLink(projectID: "p-1").url) == .project("p-1", tab: .now))
    }

    @Test func theSwitchsWordsAreTheContracts() {
        #expect(ProjectLiveActivitySection.line.contains("can read these three numbers; never the project’s name"))
        #expect(ProjectActivityRefusal.notAllowed.words == "Live Activities are off for pi². Turn them on in Settings › pi² › Live Activities.")
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
