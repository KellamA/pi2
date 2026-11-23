import Foundation
import PiModels

// What the pull request's screens read of the engine's `github` event is the shared reading in `PiModels` (#828): a
// pull request as `GitHubPull`, the project's listing as `GitHubWork` and a write whose outcome is not known as
// `GitHubUnknownWrite`, each field for field as this folder read them. What stays here is only the phone's own: which
// pull request a listing holds and the words of a listing that went wrong, on `GitHubWork`; and a pull request's state,
// checks and findings as this screen says them, on `GitHubPull`.

extension GitHubWork {
    /// The project's listing in the session's latest `github` event, or nil when the event has none for it yet. Nil is
    /// what the screens show a wait for; a listing the event does name is never nil, even when nothing has been read.
    static func of(_ github: JSONValue?, project: String) -> GitHubWork? {
        github?["projects"]?[project].map(GitHubWork.init)
    }

    func pull(_ number: Int) -> GitHubPull? { pulls.first { $0.number == number } }

    /// What went wrong with GitHub's last read, and what the screen under it holds, for a phone; nil when nothing did.
    func troubleWords(now: Date = Date()) -> String? {
        guard troubled else { return nil }
        let read = readAt.map { "What your Mac last read, \($0.formatted(.relative(presentation: .named, unitsStyle: .wide))), is shown" }
            ?? "Nothing has been read yet"
        switch state {
        case "unreachable":
            return "GitHub cannot be reached from your Mac. \(read); nothing here can change until it answers."
        case "signed_out":
            return (error ?? "").localizedCaseInsensitiveContains("not found")
                ? "GitHub's command-line tool gh is not installed on your Mac. \(read); nothing here can change until it is."
                : "gh is not signed in to GitHub on your Mac. \(read); nothing here can change until it is."
        default:
            return "GitHub's rate limit is reached. \(read); nothing here can change until the hour is up."
        }
    }
}

extension GitHubPull {
    var isOpen: Bool { state == "open" }

    /// "Open", "Draft", "Merged" or "Closed".
    var stateWords: String {
        switch state {
        case "merged": "Merged"
        case "closed": "Closed"
        default: draft ? "Draft" : "Open"
        }
    }

    /// The findings newest first, as the Mac lists them.
    var findingsNewestFirst: [Finding] { findings.sorted { $0.at > $1.at } }

    /// "Checks passing", "2 checks failing", "Checks running" or "No checks", as this screen says it: a read that knows
    /// only that some checks failed says "Checks failing", where the shared `checksWords` would count the none it
    /// knows. Named apart from the shared member, which stays reachable from the test module too.
    var pageChecksWords: String {
        switch checks {
        case "passing": "Checks passing"
        case "failing": failingChecks.isEmpty ? "Checks failing" : "\(failingChecks.count) \(failingChecks.count == 1 ? "check" : "checks") failing"
        case "pending": "Checks running"
        default: "No checks"
        }
    }
}
