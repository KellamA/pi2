@preconcurrency import ActivityKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import pi2

/// A followed project's Live Activity (#700, `iphone/Widgets/LiveActivity/`): the numbers it holds and nothing else,
/// the relay's push read as iOS reads it, the link a tap opens, the words it draws, and every form drawn to a picture:
/// the Lock Screen and the Dynamic Island's compact, minimal and expanded forms, light and dark, with none, some and many
/// of each number. The island is drawn here on a black shape of its size, since iOS draws its own outline; to keep the
/// pictures, make `app/build/shots/700/` in the checkout and run this suite.
@MainActor
struct LiveActivityTests {
    typealias State = ProjectActivityAttributes.ContentState

    /// ActivityKit applies an update a moment after `update` returns.
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The payloads the relay posts to Apple for an update and an end, exactly as `relay/test/push.test.ts` checks
    /// them ("a Live Activity's push"): if either side changes, both tests must.
    static let relayUpdate = #"{"aps":{"timestamp":1764150000,"event":"update","content-state":{"working":3,"needs":1,"finished":2,"at":1764149990000}}}"#
    static let relayEnd = #"{"aps":{"timestamp":1764150000,"event":"end","content-state":{"working":0,"needs":0,"finished":5,"at":1764149990000},"dismissal-date":1764150900}}"#

    // MARK: - Numbers only

    @Test func theContentStateIsFourNumbers() throws {
        let state = State(working: 3, needs: 1, finished: 2, at: 1_764_149_990_000)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(Set(json.keys) == ["working", "needs", "finished", "at"])
        #expect(json.values.allSatisfy { $0 is NSNumber })
        #expect(state.date == Date(timeIntervalSince1970: 1_764_149_990))
        #expect(State(working: 0, needs: 0, finished: 9, at: Date()).isIdle)
        #expect(!State(working: 0, needs: 1, finished: 0, at: Date()).isIdle)
    }

    @Test func theRelaysPushIsReadAsIOSReadsIt() throws {
        let update = try ProjectActivityPush(payload: Data(Self.relayUpdate.utf8))
        #expect(update.event == .update)
        #expect(update.timestamp == Date(timeIntervalSince1970: 1_764_150_000))
        #expect(update.state == State(working: 3, needs: 1, finished: 2, at: 1_764_149_990_000))
        #expect(update.dismissal == nil)

        let end = try ProjectActivityPush(payload: Data(Self.relayEnd.utf8))
        #expect(end.event == .end)
        #expect(end.state.finished == 5 && end.state.isIdle)
        #expect(end.dismissal == Date(timeIntervalSince1970: 1_764_150_900))
    }

    @Test func aPushWithMoreThanNumbersIsRefused() {
        let refused = [
            #"{"aps":{"timestamp":1,"event":"update","content-state":{"working":3,"needs":1,"finished":2,"at":1},"alert":{"title":"pi2"}}}"#,
            #"{"aps":{"timestamp":1,"event":"update","content-state":{"working":3,"needs":1,"finished":2,"at":1}},"sealed":"x"}"#,
            #"{"aps":{"timestamp":1,"event":"start","content-state":{"working":3,"needs":1,"finished":2,"at":1}}}"#,
            #"{"aps":{"timestamp":1,"event":"update","content-state":{"working":"three","needs":1,"finished":2,"at":1}}}"#,
            #"{"aps":{"event":"update","content-state":{"working":3,"needs":1,"finished":2,"at":1}}}"#,
            #"{"aps":{"timestamp":1,"event":"update","content-state":{"working":3,"needs":1,"finished":2,"at":1},"dismissal-date":2}}"#,
            "not json",
        ]
        for payload in refused {
            #expect(throws: ProjectActivityPush.Refused.self, "\(payload)") { try ProjectActivityPush(payload: Data(payload.utf8)) }
        }
    }

    @Test func theAppCountsAsTheMacDoes() async throws {
        let transport = try #require(DemoTransport.recorded(), "the demo's recording is in the app's bundle")
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        #expect(try await eventually { !session.engine.projects.isEmpty && !session.engine.activity.isEmpty && !session.engine.needs.isEmpty })
        let engine = session.engine
        let project = try #require(engine.projects.first { project in engine.activity.contains { $0.projectId == project.id } })
        let at = Date()
        let state = State.counted(projectID: project.id, activity: engine.activity, needs: engine.needs, finished: 7, at: at)
        #expect(state.working == engine.activity.filter { $0.projectId == project.id && $0.chat != true }.count)
        #expect(state.working > 0)
        #expect(state.needs == engine.needs.filter { $0.projectId == project.id }.count)
        #expect(state.finished == 7)
        #expect(state.at == Int64((at.timeIntervalSince1970 * 1000).rounded()))
        let none = State.counted(projectID: "no-such-project", activity: engine.activity, needs: engine.needs, finished: 0, at: at)
        #expect(none.isIdle)
    }

    // MARK: - The link, the words

    @Test func aTapOpensTheProjectsHub() throws {
        let link = ProjectActivityLink(projectID: "proj_1a2b")
        #expect(link.url.absoluteString == "pi2-widget://project?id=proj_1a2b")
        #expect(ProjectActivityLink(link.url) == link)
        // The widgets' own links are not the activity's, and the activity's is not theirs.
        #expect(WidgetsLink(link.url) == nil)
        #expect(ProjectActivityLink(WidgetsLink.dashboard(project: "proj_1a2b").url) == nil)
        for text in ["pi2-widget://project", "pi2-widget://project?id=", "pi2-widget://project?id=a&id=b", "pi2-widget://project?id=a&x=1",
                     "pi2-widget://project?id=a%20b", "pi2://project?id=a", "pi2-widget://project/more?id=a"] {
            #expect(ProjectActivityLink(try #require(URL(string: text))) == nil, "\(text)")
        }
    }

    @Test func theWordsSayHowOldTheNumbersAre() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_764_150_000)
        #expect(ProjectActivityStyle.asOf(now.addingTimeInterval(-60), now: now, calendar: calendar).hasPrefix("as of "))
        #expect(ProjectActivityStyle.short(0) == "0")
        #expect(ProjectActivityStyle.short(99) == "99")
        #expect(ProjectActivityStyle.short(100) == "99+")
        #expect(ProjectActivityStyle.short(-3) == "0")
        #expect(ProjectActivityStyle.spoken(State(working: 3, needs: 1, finished: 2, at: 0)) == "3 working, 1 needs you, 2 finished")
        #expect(ProjectActivityStyle.spoken(State(working: 0, needs: 4, finished: 0, at: 0)) == "0 working, 4 need you, 0 finished")
    }

    @Test func theRelaysIDIsTheActivitysUUIDIn16Bytes() {
        let id = ProjectActivities.relayID(activityID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        #expect(id == "5iHh-MNsSVqT_Awkej5uXw")
        #expect(id.count == 22)
    }

    // MARK: - Started, updated and ended on the phone

    /// The app's three calls against iOS's own ActivityKit, in the simulator that runs the tests: started for a project
    /// with no push token (an unsigned build has none), updated, an older update left out, started again (the same one),
    /// the relay's push applied as iOS applies it, and ended.
    @Test(.enabled(if: ProjectActivities.areAllowed)) func startedUpdatedAndEnded() async throws {
        await ProjectActivities.endAll()
        let first = State(working: 2, needs: 0, finished: 0, at: Date())
        let activity = try await ProjectActivities.start(projectID: "test-700", projectName: "pi2", state: first, throughRelay: false)
        #expect(ProjectActivities.running(projectID: "test-700")?.id == activity.id)
        #expect(activity.attributes.projectName == "pi2")

        let later = State(working: 3, needs: 1, finished: 2, at: first.at + 1000)
        await ProjectActivities.update(projectID: "test-700", to: later)
        #expect(try await eventually { activity.content.state == later })
        await ProjectActivities.update(projectID: "test-700", to: first)
        try await Task.sleep(for: .milliseconds(300))
        #expect(activity.content.state == later, "an older count leaves the newer one")

        let again = try await ProjectActivities.start(projectID: "test-700", projectName: "pi2", state: later, throughRelay: false)
        #expect(again.id == activity.id)
        #expect(ProjectActivities.running.count == 1)

        let push = try ProjectActivityPush(payload: Data(Self.relayUpdate.utf8))
        await push.apply(to: activity)
        #expect(try await eventually { activity.content.state == push.state })

        await ProjectActivities.end(projectID: "test-700")
        #expect(ProjectActivities.running(projectID: "test-700") == nil)
    }

    @Test(.enabled(if: ProjectActivities.areAllowed)) func reconcileFollowsWhatThePersonFollows() async throws {
        await ProjectActivities.endAll()
        let busy = State(working: 1, needs: 2, finished: 0, at: Date())
        let idle = State(working: 0, needs: 0, finished: 4, at: Date())
        var numbers: [String: State] = ["a-700": busy, "b-700": idle]
        await ProjectActivities.reconcile(followed: [("a-700", "Alpha"), ("b-700", "Beta")], state: { numbers[$0] }, throughRelay: false)
        #expect(ProjectActivities.running(projectID: "a-700") != nil)
        #expect(ProjectActivities.running(projectID: "b-700") == nil, "an idle project gets none")

        numbers["a-700"] = idle
        numbers["b-700"] = busy
        await ProjectActivities.reconcile(followed: [("a-700", "Alpha"), ("b-700", "Beta")], state: { numbers[$0] }, throughRelay: false)
        #expect(ProjectActivities.running(projectID: "a-700") == nil, "gone idle, ended")
        #expect(ProjectActivities.running(projectID: "b-700") != nil)

        await ProjectActivities.reconcile(followed: [], state: { numbers[$0] }, throughRelay: false)
        #expect(ProjectActivities.running.isEmpty, "no longer followed, ended")
        // The one ended idle stays on the Lock Screen for a while; the simulator's is taken away at once.
        await ProjectActivities.endAll()
    }

    /// The simulator's steps, one at a time, for pictures of the real Lock Screen and island between them
    /// (docs/iphone-app.md, "The Live Activity"): `TEST_RUNNER_PI2_LIVE_ACTIVITY=start:pi2` (or `push:<payload>`, or
    /// `end`) given to `scripts/iphone-sim test … -only-testing:pi2Tests/LiveActivityTests/simulatorStep`. Off otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI2_LIVE_ACTIVITY"] != nil))
    func simulatorStep() async throws {
        try await ProjectActivityDebug.apply()
    }

    /// The simulator's walk through all three, in one run, since each run of the tests installs the app again, which
    /// ends its activities: `TEST_RUNNER_PI2_LIVE_ACTIVITY_WALK='<update payload>||<end payload>'`, the two pushes the
    /// relay posted to its stand-in. It starts the activity, then waits for the app to be sent to the background (`xcrun
    /// simctl launch <id> com.apple.Preferences`, so that the island shows it) and brought back (`xcrun simctl launch <id>
    /// dev.pi2.ios`) before each next step: the update, then the end. Off otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI2_LIVE_ACTIVITY_WALK"] != nil), .timeLimit(.minutes(10)))
    func simulatorWalk() async throws {
        let pushes = try #require(ProcessInfo.processInfo.environment["PI2_LIVE_ACTIVITY_WALK"]).components(separatedBy: "||")
        try #require(pushes.count == 2)
        let update = try ProjectActivityPush(payload: Data(pushes[0].utf8))
        let end = try ProjectActivityPush(payload: Data(pushes[1].utf8))
        #expect(update.event == .update && end.event == .end)

        await ProjectActivities.endAll()
        let activity = try await ProjectActivities.start(
            projectID: "pi2", projectName: "pi2", state: State(working: 3, needs: 1, finished: 2, at: Date()), throughRelay: false
        )
        try keep(activity, "started")
        try await awayAndBack()
        await update.apply(to: activity)
        #expect(try await eventually { activity.content.state == update.state })
        try keep(activity, "updated")
        try await awayAndBack()
        await end.apply(to: activity)
        // Ended; and dismissed at once when the push's dismissal date has passed.
        #expect(try await eventually { activity.activityState == .ended || activity.activityState == .dismissed })
        #expect(activity.content.state == end.state)
        try keep(activity, "ended")
        try await awayAndBack()
        await ProjectActivities.endAll()
    }

    /// The activity as iOS holds it at this step, drawn on the Lock Screen and compact: the simulator's own picture of
    /// the screen leaves the island and the Lock Screen out.
    private func keep(_ activity: ProjectActivities.Running, _ step: String) throws {
        let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../app/build/shots/700")
        guard FileManager.default.fileExists(atPath: shots.path) else { return }
        let board = ProjectActivityBoard(
            states: [("\(step) (\(String(describing: activity.activityState)))", activity.content.state)], look: .light,
            name: activity.attributes.projectName, now: Date()
        )
        let renderer = ImageRenderer(content: board.environment(\.colorScheme, .light))
        renderer.scale = 2
        try #require(renderer.uiImage?.pngData()).write(to: shots.appending(path: "sim-\(step)-as-ios-holds-it.png"))
    }

    private func awayAndBack() async throws {
        #expect(try await eventually(240) { UIApplication.shared.applicationState == .background }, "sent to the background")
        #expect(try await eventually(240) { UIApplication.shared.applicationState == .active }, "brought back")
    }

    // MARK: - Pictures

    static let states: [(name: String, state: State)] = {
        let at = Date(timeIntervalSince1970: 1_764_149_990)
        return [
            ("none", State(working: 0, needs: 0, finished: 0, at: at)),
            ("some", State(working: 3, needs: 1, finished: 2, at: at)),
            ("many", State(working: 128, needs: 42, finished: 1204, at: at)),
            ("idle", State(working: 0, needs: 0, finished: 5, at: at)),
        ]
    }()

    @Test func everyFormDraws() throws {
        let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../app/build/shots/700")
        let keep = FileManager.default.fileExists(atPath: shots.path)
        for look in [ColorScheme.light, .dark] {
            let board = ProjectActivityBoard(states: Self.states, look: look)
            let renderer = ImageRenderer(content: board.environment(\.colorScheme, look))
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size.width > 700 && image.size.height > 700)
            if keep {
                try #require(image.pngData()).write(to: shots.appending(path: "live-activity-\(look == .dark ? "dark" : "light").png"))
            }
        }
    }
}

/// Every form for each state on one picture, at an iPhone's sizes in points: the Lock Screen's activity, and the
/// island compact, minimal and expanded. The island is always dark, as iOS draws it; its outline is drawn grey here only
/// so that it shows on the dark picture.
private struct ProjectActivityBoard: View {
    let states: [(name: String, state: ProjectActivityAttributes.ContentState)]
    let look: ColorScheme
    var name = "pi2"
    var now = Date(timeIntervalSince1970: 1_764_150_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Live Activity: \(look == .dark ? "dark" : "light")").font(.headline)
            ForEach(states, id: \.name) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 16) {
                        lock(item.state)
                        VStack(alignment: .leading, spacing: 10) {
                            compact(item.state)
                            HStack(spacing: 10) {
                                minimal(item.state)
                                Text("minimal").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    expanded(item.state)
                }
            }
        }
        .padding(20)
        .frame(width: 820, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func lock(_ state: ProjectActivityAttributes.ContentState) -> some View {
        ProjectActivityLockView(name: name, state: state, now: now)
            .frame(width: 364, alignment: .leading)
            .background(look == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(10)
            .background(
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
    }

    private func compact(_ state: ProjectActivityAttributes.ContentState) -> some View {
        HStack(spacing: 0) {
            ProjectActivityCompactLeading(name: name)
            Spacer(minLength: 126)
            ProjectActivityCompactTrailing(state: state)
        }
        .padding(.horizontal, 10)
        .frame(height: 37)
        .fixedSize()
        .background(.black, in: Capsule())
        .overlay(Capsule().stroke(.gray.opacity(0.5)))
        .environment(\.colorScheme, .dark)
    }

    private func minimal(_ state: ProjectActivityAttributes.ContentState) -> some View {
        ProjectActivityMinimal(state: state)
            .frame(width: 37, height: 37)
            .background(.black, in: Circle())
            .overlay(Circle().stroke(.gray.opacity(0.5)))
            .environment(\.colorScheme, .dark)
    }

    private func expanded(_ state: ProjectActivityAttributes.ContentState) -> some View {
        VStack(spacing: 6) {
            HStack {
                ProjectActivityExpandedLeading(name: name)
                Spacer()
                ProjectActivityExpandedTrailing(state: state, now: now)
                    .fixedSize()
            }
            ProjectActivityExpandedBottom(state: state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 371)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).stroke(.gray.opacity(0.5)))
        .environment(\.colorScheme, .dark)
    }
}
