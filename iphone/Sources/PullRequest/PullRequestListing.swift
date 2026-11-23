import Foundation
import PiModels

/// A pull request of a project's repository, as the engine's `github` event sends it (docs/projects.md, 3.11): its
/// branches, its checks as one state with the failing ones named, what reviewing agents found, and whether GitHub would
/// merge it. Read as the Mac reads it (`GitHubPull` in app/Sources/pi2/ProjectWorkGitHub.swift), field for field; that
/// type lives in the Mac's app target, so the phone reads the same JSON here until it moves to `PiModels`.
struct PullRequestInfo: Identifiable, Equatable {
    /// One finding a reviewing agent posted through `work` `review`: its verdict, who gave it and when, and its words.
    struct Finding: Equatable, Identifiable {
        let agentName: String
        /// "approve", "changes" or "comment".
        let verdict: String
        let at: Date
        let url: String
        let text: String
        var id: String { "\(agentName)|\(at.timeIntervalSince1970)|\(url)" }
    }

    /// One of the checks that failed, with its page on GitHub.
    struct FailingCheck: Equatable, Identifiable {
        let name: String
        let url: String
        var id: String { "\(name)|\(url)" }
    }

    let number: Int
    let title: String
    let url: String
    /// The head branch as GitHub names it: "branch", or "owner:branch" from a fork.
    let head: String
    let base: String
    let author: String
    /// "open", "merged" or "closed".
    let state: String
    let draft: Bool
    /// "passing", "failing", "pending" or "none".
    let checks: String
    let failingChecks: [FailingCheck]
    /// "yes", "no" or "unknown".
    let mergeable: String
    let findings: [Finding]
    /// The conversation that opened it through pi², which Send back hands the reason to; nil when nobody did.
    let openedBy: Int?
    /// The work item it fixes, from "Fixes #N" in its text.
    let work: Int?
    /// Only what its row shows was read (a closed one): no checks or findings.
    let partial: Bool

    var id: Int { number }

    init?(_ value: JSONValue?) {
        guard let value, let number = value["number"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        self.number = number
        self.title = title
        url = value["url"]?.stringValue ?? ""
        head = value["head"]?.stringValue ?? ""
        base = value["base"]?.stringValue ?? ""
        author = value["author"]?.stringValue ?? ""
        state = value["state"]?.stringValue ?? "open"
        draft = value["draft"] == .bool(true)
        checks = value["checks"]?.stringValue ?? "none"
        failingChecks = (value["failingChecks"]?.arrayValue ?? []).compactMap { check in
            guard let name = check["name"]?.stringValue else { return nil }
            return FailingCheck(name: name, url: check["url"]?.stringValue ?? "")
        }
        mergeable = value["mergeable"]?.stringValue ?? "unknown"
        findings = (value["findings"]?.arrayValue ?? []).compactMap { finding in
            guard let agentName = finding["agentName"]?.stringValue else { return nil }
            var at = 0.0
            if case .number(let milliseconds)? = finding["at"] { at = milliseconds }
            return Finding(
                agentName: agentName,
                verdict: finding["verdict"]?.stringValue ?? "comment",
                at: Date(timeIntervalSince1970: at / 1000),
                url: finding["url"]?.stringValue ?? "",
                text: finding["text"]?.stringValue ?? ""
            )
        }
        openedBy = value["openedBy"]?["conversationId"]?.intValue
        work = value["work"]?.intValue
        partial = value["partial"] == .bool(true)
    }

    var isOpen: Bool { state == "open" }

    /// The findings newest first, as the Mac lists them.
    var findingsNewestFirst: [Finding] { findings.sorted { $0.at > $1.at } }

    /// "Open", "Draft", "Merged" or "Closed".
    var stateWords: String {
        switch state {
        case "merged": "Merged"
        case "closed": "Closed"
        default: draft ? "Draft" : "Open"
        }
    }

    /// "Checks passing", "2 checks failing", "Checks running" or "No checks", as the Mac says it.
    var checksWords: String {
        switch checks {
        case "passing": "Checks passing"
        case "failing": failingChecks.isEmpty ? "Checks failing" : "\(failingChecks.count) \(failingChecks.count == 1 ? "check" : "checks") failing"
        case "pending": "Checks running"
        default: "No checks"
        }
    }

    /// "approved", "asked for changes" or "left a finding".
    static func verdictWords(_ verdict: String) -> String {
        switch verdict {
        case "approve": "approved"
        case "changes": "asked for changes"
        default: "left a finding"
        }
    }
}

/// A write of pi²'s whose outcome GitHub could not tell (`unknown`, docs/projects.md, 3.11): the person looks at the
/// repository and says whether it happened (`github.settle`), as on the Mac (`GitHubUnknownWrite`).
struct PullRequestUnknownWrite: Identifiable, Equatable {
    let intent: String
    let summary: String
    let at: Date

    var id: String { intent }

    init?(_ value: JSONValue?) {
        guard let value, let intent = value["intent"]?.stringValue else { return nil }
        var at = 0.0
        if case .number(let milliseconds)? = value["at"] { at = milliseconds }
        self.intent = intent
        summary = value["summary"]?.stringValue ?? "a write"
        self.at = Date(timeIntervalSince1970: at / 1000)
    }
}

/// What the Mac last read of a project's repository, from the `github` event's `projects` (docs/projects.md, 4.3): how
/// the read went, its pull requests, and the writes whose outcome pi² could not tell. The Mac's `GitHubWork`, less the
/// issues, which are the Work tab's (#694).
struct PullRequestListing: Equatable {
    /// "ok", "loading", "signed_out", "unreachable" or "rate_limited".
    let state: String
    let error: String?
    let readAt: Date?
    /// A read under way behind what is shown.
    let reading: Bool
    let pulls: [PullRequestInfo]
    let unknown: [PullRequestUnknownWrite]

    init(_ value: JSONValue?) {
        state = value?["state"]?.stringValue ?? "loading"
        error = value?["error"]?.stringValue
        var read = 0.0
        if case .number(let milliseconds)? = value?["readAt"] { read = milliseconds }
        readAt = read > 0 ? Date(timeIntervalSince1970: read / 1000) : nil
        reading = value?["reading"] == .bool(true)
        pulls = (value?["pulls"]?.arrayValue ?? []).compactMap(PullRequestInfo.init)
        unknown = (value?["unknown"]?.arrayValue ?? []).compactMap(PullRequestUnknownWrite.init)
    }

    /// The project's listing in the session's latest `github` event; nil when the event has none for it yet.
    @MainActor
    static func of(_ github: JSONValue?, project: String) -> PullRequestListing? {
        guard let value = github?["projects"]?[project] else { return nil }
        return PullRequestListing(value)
    }

    func pull(_ number: Int) -> PullRequestInfo? { pulls.first { $0.number == number } }

    /// GitHub's last read left something wrong: what is shown is the last listing read, and nothing can change.
    var troubled: Bool { state == "signed_out" || state == "unreachable" || state == "rate_limited" }

    /// Nothing has been read yet, and the first read is under way.
    var firstRead: Bool { readAt == nil && !troubled }

    /// What went wrong, as the Mac's Work tab says it (`ProjectWorkGitHub.troubleWords`), for a phone.
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
