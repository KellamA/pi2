#if DEBUG
@preconcurrency import ActivityKit // as in ProjectActivities.swift
import Foundation

/// A Live Activity push as iOS reads it (relay/src/apns.ts makes them): `aps.event` (`update` or `end`), `aps.timestamp`
/// (seconds), `aps.content-state` (the numbers) and, for an end, `aps.dismissal-date` (seconds). On a phone iOS applies
/// it to the activity whose push token it was sent to, with the app closed; a simulator cannot be sent one (`xcrun
/// simctl push` takes an app's alerts only) and an unsigned build has no push token. So in a debug build this reads the
/// payload the relay posted to its stand-in for Apple's service (relay/test/apns.ts) and applies it as iOS would, which
/// shows in the simulator what the relay's push does. It reads it strictly: a payload iOS would not take is refused.
struct ProjectActivityPush: Equatable, Sendable {
    enum Event: String, Sendable { case update, end }

    var event: Event
    var timestamp: Date
    var state: ProjectActivityAttributes.ContentState
    var dismissal: Date?

    struct Refused: Error, Equatable { let why: String }

    init(payload: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              Set(object.keys) == ["aps"], let aps = object["aps"] as? [String: Any] else { throw Refused(why: "not a push") }
        guard let name = aps["event"] as? String, let event = Event(rawValue: name) else { throw Refused(why: "no event") }
        guard let seconds = aps["timestamp"] as? Int else { throw Refused(why: "no timestamp") }
        guard let content = aps["content-state"], JSONSerialization.isValidJSONObject(content),
              let state = try? JSONDecoder().decode(ProjectActivityAttributes.ContentState.self, from: JSONSerialization.data(withJSONObject: content))
        else { throw Refused(why: "no content state") }
        let allowed: Set<String> = event == .end ? ["event", "timestamp", "content-state", "dismissal-date"] : ["event", "timestamp", "content-state"]
        guard Set(aps.keys).isSubset(of: allowed) else { throw Refused(why: "more than numbers") }
        self.event = event
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(seconds))
        self.state = state
        self.dismissal = (aps["dismissal-date"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Applies it to the project's activity, as iOS applies a push to the activity its token belongs to.
    @MainActor
    func apply(to activity: ProjectActivities.Running) async {
        let content = ActivityContent(state: state, staleDate: nil)
        switch event {
        case .update:
            await activity.update(content)
        case .end:
            await activity.end(content, dismissalPolicy: dismissal.map { .after($0) } ?? .default)
        }
    }
}

/// `PI2_LIVE_ACTIVITY`, a debug build's way to show the Live Activity in the simulator without Settings' switch
/// (docs/iphone-app.md, "The Live Activity"):
///
/// - `start:<project name>[:<working>,<needs>,<finished>]`: starts the project's activity, with no push token (the
///   simulator has none), its id the name's;
/// - `push:<payload>`: applies a Live Activity push, the JSON the relay posted to its stand-in, to the one running;
/// - `end`: ends every one at once.
///
/// `App/` calls `ProjectActivityDebug.apply()` once at launch in a debug build; the unit tests call it too.
enum ProjectActivityDebug {
    @MainActor
    static func apply(_ value: String? = ProcessInfo.processInfo.environment["PI2_LIVE_ACTIVITY"]) async throws {
        guard let value else { return }
        if value == "end" {
            await ProjectActivities.endAll()
        } else if value.hasPrefix("start:") {
            let parts = value.dropFirst("start:".count).split(separator: ":", maxSplits: 1).map(String.init)
            let numbers = (parts.count > 1 ? parts[1] : "3,1,2").split(separator: ",").compactMap { Int($0) }
            guard let name = parts.first, !name.isEmpty, numbers.count == 3 else {
                throw ProjectActivityPush.Refused(why: "PI2_LIVE_ACTIVITY=start:<name>[:<working>,<needs>,<finished>]")
            }
            let state = ProjectActivityAttributes.ContentState(working: numbers[0], needs: numbers[1], finished: numbers[2], at: Date())
            try await ProjectActivities.start(projectID: name, projectName: name, state: state, throughRelay: false)
        } else if value.hasPrefix("push:") {
            let push = try ProjectActivityPush(payload: Data(value.dropFirst("push:".count).utf8))
            guard let activity = ProjectActivities.running.first else { throw ProjectActivityPush.Refused(why: "no Live Activity runs") }
            await push.apply(to: activity)
        } else {
            throw ProjectActivityPush.Refused(why: "PI2_LIVE_ACTIVITY takes start:…, push:… or end")
        }
    }
}
#endif
