import ActivityKit
import Foundation

/// A followed project's Live Activity (docs/iphone.md 7; docs/design/iphone.md, "What a phone adds"): on the Lock Screen
/// and in the Dynamic Island, how many of the project's agents are working, what needs the person, and what finished.
///
/// **What is set where.** The static part, the project's id and name, is set on the phone when the app starts the
/// activity (`ProjectActivities.start`) and never travels: no push carries it. The content state is numbers only, so
/// that the relay can send it while the app is closed in a push the system reads, which cannot be sealed: the relay can
/// read these numbers, and the person turns each project's activity on knowing it (question 7, answered yes).
///
/// This file is built into the app and the widgets extension alike (`iphone/Widgets/LiveActivity/`): the app starts,
/// updates and ends the activity with it, the extension draws it.
struct ProjectActivityAttributes: ActivityAttributes {
    /// The numbers, exactly as a Live Activity push carries them in `aps.content-state` (relay/src/apns.ts):
    /// `{ "working": 3, "needs": 1, "finished": 2, "at": 1764150000000 }`. Nothing else may ever be added here that is not
    /// a number: whatever is here, the relay and Apple read.
    struct ContentState: Codable, Hashable, Sendable {
        /// The project's agents at work now: its orchestrator and its agents with a run going.
        var working: Int
        /// What waits for the person in the project: its items in Needs you.
        var needs: Int
        /// The project's runs finished since the activity was started.
        var finished: Int
        /// When the Mac counted these, in milliseconds since 1970, as the contract writes every time. Not a `Date`:
        /// ActivityKit decodes a push's content state with `JSONDecoder`'s default, which reads a date as seconds since
        /// 2001, and the relay writes the contract's milliseconds.
        var at: Int64

        init(working: Int, needs: Int, finished: Int, at: Int64) {
            self.working = working
            self.needs = needs
            self.finished = finished
            self.at = at
        }

        init(working: Int, needs: Int, finished: Int, at date: Date) {
            self.init(working: working, needs: needs, finished: finished, at: Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }

        /// When the Mac counted them.
        var date: Date { Date(timeIntervalSince1970: TimeInterval(at) / 1000) }

        /// Whether nothing is going on: no agent working and nothing waiting.
        var isIdle: Bool { working == 0 && needs == 0 }
    }

    /// The project's id (`ProjectRow.id`), for the link a tap opens. Only on the phone.
    var projectID: String
    /// The project's name, as the Lock Screen and the expanded island show it. Only on the phone.
    var projectName: String
}

/// Where a tap on a project's Live Activity opens the app: the project's hub, on its Now tab, which says who works and
/// what waits. `pi2-widget://project?id=<id>`, in the widgets' own scheme beside `WidgetsLink`'s places, which knows no
/// hub: `App/` reads `WidgetsLink(url)` first, then `ProjectActivityLink(url)`, and opens `.project(id, tab: .now)`
/// once Face ID has opened the session (docs/iphone.md 4.5).
struct ProjectActivityLink: Hashable, Sendable {
    var projectID: String

    static let host = "project"

    var url: URL {
        var parts = URLComponents()
        parts.scheme = WidgetsLink.scheme
        parts.host = Self.host
        parts.queryItems = [URLQueryItem(name: "id", value: projectID)]
        return parts.url!
    }

    init(projectID: String) {
        self.projectID = projectID
    }

    /// The link a URL names, or nil for any other URL: another scheme or place, an id that is not one, anything more.
    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == WidgetsLink.scheme,
              parts.host == Self.host, parts.path.isEmpty || parts.path == "/",
              let items = parts.queryItems, items.count == 1, items[0].name == "id",
              let id = items[0].value, Self.isID(id) else { return nil }
        projectID = id
    }

    /// A project's id as the engine makes them: short, of letters, digits and `-_.:`.
    private static func isID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.:".unicodeScalars.contains($0) }
    }
}
