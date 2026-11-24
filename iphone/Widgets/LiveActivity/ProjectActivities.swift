// ActivityKit's `Activity` is not marked `Sendable`, though its methods are `async` and run off the main actor: the
// app's calls from the main actor are what ActivityKit is made for.
@preconcurrency import ActivityKit
import Foundation

/// Starting, updating and ending a followed project's Live Activity (docs/iphone.md 7): plain functions the app calls
/// (docs/iphone-app.md, "The Live Activity"). The app starts it, since only the app in the foreground may, and the
/// static part (the project's name) is set only here; while the app is closed the relay updates and ends it with pushes
/// that carry numbers only, to the push token this activity gives (`pushTokens(of:)`).
///
/// One activity for each project at most: starting a project's activity again updates the one that runs.
@MainActor
enum ProjectActivities {
    typealias State = ProjectActivityAttributes.ContentState
    typealias Running = Activity<ProjectActivityAttributes>

    /// How long an activity ended on the phone stays on the Lock Screen when it ended because the project went idle,
    /// with its last numbers, as the relay's end push leaves it (relay/src/apns.ts): long enough to see what finished.
    static let shownAfterIdle: TimeInterval = 15 * 60

    /// Whether the person allows pi²'s Live Activities in iOS's Settings (Settings › pi² › Live Activities). When they
    /// do not, the switch for each project says so and starts nothing.
    nonisolated static var areAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Every pi² Live Activity that has not ended, of any project.
    static var running: [Running] {
        Running.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// The project's activity, if one runs.
    static func running(projectID: String) -> Running? {
        running.first { $0.attributes.projectID == projectID }
    }

    /// Starts the project's activity with its numbers, or updates the one that runs. `throughRelay` asks iOS for a push
    /// token, so that the relay can update the activity while the app is closed: on in every real use; a simulator build
    /// that is not signed has no push, and asks for none. Throws `ProjectActivityRefusal` with the words to show.
    @discardableResult
    static func start(projectID: String, projectName: String, state: State, throughRelay: Bool = true) async throws -> Running {
        if let activity = running(projectID: projectID) {
            await update(activity, to: state)
            return activity
        }
        guard areAllowed else { throw ProjectActivityRefusal.notAllowed }
        let attributes = ProjectActivityAttributes(projectID: projectID, projectName: projectName)
        do {
            return try Running.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: throughRelay ? .token : nil
            )
        } catch {
            throw ProjectActivityRefusal(error)
        }
    }

    /// Updates the project's activity with newer numbers, while the app is open; the relay does it while it is closed.
    /// Numbers older than the ones shown are left out, so that a late answer never takes the activity back in time.
    static func update(projectID: String, to state: State) async {
        guard let activity = running(projectID: projectID) else { return }
        await update(activity, to: state)
    }

    static func update(_ activity: Running, to state: State) async {
        guard state.at >= activity.content.state.at, state != activity.content.state else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Ends the project's activity. `.turnedOff` (the person's switch, unpairing) takes it away at once; `.idle` (the
    /// project has nothing working and nothing waiting) leaves its last numbers on the Lock Screen for a while.
    static func end(projectID: String, final state: State? = nil, because reason: EndReason = .turnedOff) async {
        for activity in Running.activities where activity.attributes.projectID == projectID {
            await end(activity, final: state, because: reason)
        }
    }

    static func end(_ activity: Running, final state: State? = nil, because reason: EndReason = .turnedOff) async {
        let last = state.flatMap { $0.at >= activity.content.state.at ? $0 : nil } ?? activity.content.state
        let policy: ActivityUIDismissalPolicy = switch reason {
        case .turnedOff: .immediate
        case .idle: .after(Date(timeIntervalSinceNow: shownAfterIdle))
        }
        await activity.end(ActivityContent(state: last, staleDate: nil), dismissalPolicy: policy)
    }

    /// Ends every pi² activity at once: when the phone is unpaired, leaves, or wipes what it keeps (docs/iphone.md 3.6:
    /// "every Live Activity (ended)").
    static func endAll() async {
        for activity in Running.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Brings the activities in line with what the person follows, when the app comes to the foreground with the Mac's
    /// numbers in hand: starts one for each followed project that has something going on and none running (iOS ended it
    /// after eight hours, or the project went idle and is busy again), updates the others, ends any for a project no
    /// longer followed, and ends a followed one whose project went idle. `state(for:)` gives a project's numbers, or nil
    /// if the Mac's are not known yet, which leaves its activity as it is. Says which projects could not be started.
    @discardableResult
    static func reconcile(
        followed: [(id: String, name: String)],
        state: (String) -> State?,
        throughRelay: Bool = true
    ) async -> [String: ProjectActivityRefusal] {
        let ids = Set(followed.map(\.id))
        for activity in running where !ids.contains(activity.attributes.projectID) {
            await end(activity)
        }
        var refused: [String: ProjectActivityRefusal] = [:]
        for project in followed {
            guard let numbers = state(project.id) else { continue }
            if let activity = running(projectID: project.id) {
                if numbers.isIdle {
                    await end(activity, final: numbers, because: .idle)
                } else {
                    await update(activity, to: numbers)
                }
            } else if !numbers.isIdle {
                do {
                    try await start(projectID: project.id, projectName: project.name, state: numbers, throughRelay: throughRelay)
                } catch let refusal as ProjectActivityRefusal {
                    refused[project.id] = refusal
                } catch {}
            }
        }
        return refused
    }

    /// The push tokens iOS gives this activity, each as the hexadecimal text the relay takes (`activityToken`), as they
    /// come: the first soon after the start, a new one whenever iOS changes it. The app hands each to the relay with the
    /// activity's id (`relayID(of:)`), and tells the Mac which project that id follows (docs/iphone-app.md).
    static func pushTokens(of activity: Running) -> AsyncMapSequence<Activity<ProjectActivityAttributes>.PushTokenUpdates, String> {
        activity.pushTokenUpdates.map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// The activity's id as the relay and the Mac know it: the 16 bytes of the UUID iOS gave it, in base64url without
    /// padding. It says nothing of the project; only the phone and the Mac tie the two.
    static func relayID(of activity: Running) -> String {
        relayID(activityID: activity.id)
    }

    nonisolated static func relayID(activityID: String) -> String {
        let bytes: [UInt8] = UUID(uuidString: activityID).map { uuid in withUnsafeBytes(of: uuid.uuid) { Array($0) } }
            ?? Array(activityID.utf8.prefix(16))
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum EndReason: Sendable {
        case turnedOff
        case idle
    }
}

/// Why a project's Live Activity was not started, in words for the switch that asked.
struct ProjectActivityRefusal: Error, Equatable, Sendable {
    let words: String

    static let notAllowed = ProjectActivityRefusal(words: "Live Activities are off for pi². Turn them on in Settings › pi² › Live Activities.")

    init(words: String) {
        self.words = words
    }

    init(_ error: any Error) {
        if let refusal = error as? ProjectActivityRefusal {
            self = refusal
            return
        }
        if let error = error as? ActivityAuthorizationError {
            switch error {
            case .denied, .globalMaximumExceeded, .targetMaximumExceeded:
                self = error == .denied ? .notAllowed : ProjectActivityRefusal(words: "iOS shows too many Live Activities already. End one, then try again.")
                return
            case .visibility:
                self = ProjectActivityRefusal(words: "A Live Activity can be started only while pi² is open.")
                return
            default:
                break
            }
        }
        self = ProjectActivityRefusal(words: "iOS did not start the Live Activity: \(error.localizedDescription)")
    }
}
