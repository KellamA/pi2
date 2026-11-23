import Foundation

// An attached GitHub repository's issues and pull requests (docs/projects.md, 3.11 and 4.3): what the app reads of the
// engine's `github` event, with the issues read as the `work` event's work is (`Work.swift`). The Mac's Work tab reads it
// (ProjectWorkGitHub.swift, #480); the iPhone app's Work screens (#694) and its pull request screen (#695) are to read
// the same.

/// A pull request of the attached repository, as the `github` event sends it (docs/projects.md, 3.11): its branches, its
/// checks as one state, what reviewing agents found, and whether GitHub would merge it.
public struct GitHubPull: Identifiable, Equatable, Sendable {
    /// One finding a reviewing agent posted through `work` `review`: the verdict, who gave it and when, and the
    /// finding's own words, the summary the reviewing agent wrote (#573).
    public struct Finding: Equatable, Identifiable, Sendable {
        public let agentName: String
        /// "approve", "changes" or "comment".
        public let verdict: String
        public let at: Date
        public let url: String
        /// The finding's own words, as the reviewing agent wrote them.
        public let text: String
        public var id: String { "\(agentName)|\(at.timeIntervalSince1970)|\(url)" }
    }

    /// One of the pull request's checks that failed, with its page on GitHub (#573).
    public struct FailingCheck: Equatable, Identifiable, Sendable {
        public let name: String
        public let url: String
        public var id: String { "\(name)|\(url)" }
    }

    public let number: Int
    public let title: String
    public let url: String
    /// The head branch as GitHub names it: "branch", or "owner:branch" from a fork.
    public let head: String
    public let base: String
    public let author: String
    /// "open", "merged" or "closed".
    public let state: String
    public let draft: Bool
    /// "passing", "failing", "pending" or "none".
    public let checks: String
    /// The checks that failed, each with its page on GitHub; empty when none fail (#573).
    public let failingChecks: [FailingCheck]
    /// "yes", "no" or "unknown".
    public let mergeable: String
    public let findings: [Finding]
    /// The sub-chat that opened it through pi², which Send back hands it to; nil when nobody opened it here.
    public let openedBy: Int?
    /// The work item it fixes, from "Fixes #N" in its text.
    public let work: Int?
    /// Only what its row shows was read: a closed one, until it is opened (`github.show`, #599).
    public let partial: Bool

    public var id: Int { number }

    public init?(_ value: JSONValue?) {
        guard let value, let number = value["number"]?.intValue, let title = value["title"]?.stringValue else { return nil }
        var draft = false
        if case .bool(let isDraft)? = value["draft"] { draft = isDraft }
        self.number = number
        self.title = title
        url = value["url"]?.stringValue ?? ""
        head = value["head"]?.stringValue ?? ""
        base = value["base"]?.stringValue ?? ""
        author = value["author"]?.stringValue ?? ""
        state = value["state"]?.stringValue ?? "open"
        self.draft = draft
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

    /// The newest finding, which is what the pull request's row says about what a reviewing agent found.
    public var newestFinding: Finding? { findings.max { $0.at < $1.at } }

    /// "approved", "asked for changes" or "left a finding": the words for a verdict.
    public static func verdictWords(_ verdict: String) -> String {
        switch verdict {
        case "approve": "approved"
        case "changes": "asked for changes"
        default: "left a finding"
        }
    }

    /// "2 checks failing", "1 check failing", "Checks passing", "Checks running", "No checks": the pull request's
    /// checks, the failing ones counted (#573).
    public var checksWords: String {
        switch checks {
        case "passing": "Checks passing"
        case "failing": "\(failingChecks.count) \(failingChecks.count == 1 ? "check" : "checks") failing"
        case "pending": "Checks running"
        default: "No checks"
        }
    }
}

/// A write of pi²'s whose outcome GitHub could not be told (`unknown`, docs/projects.md, 3.11): `gh` was cut off while
/// it was writing, so the person looks at the repository and says whether it happened (`github.settle`).
public struct GitHubUnknownWrite: Identifiable, Equatable, Sendable {
    public let intent: String
    public let summary: String
    public let at: Date

    public var id: String { intent }

    public init?(_ value: JSONValue?) {
        guard let value, let intent = value["intent"]?.stringValue else { return nil }
        var at = 0.0
        if case .number(let milliseconds)? = value["at"] { at = milliseconds }
        self.intent = intent
        summary = value["summary"]?.stringValue ?? "a write"
        self.at = Date(timeIntervalSince1970: at / 1000)
    }
}

/// The open project's repository, from the `github` event's `projects` (docs/projects.md, 4.3): the issues as work, the
/// pull requests, how the last read went, and the writes whose outcome pi² could not tell.
public struct GitHubWork: Sendable {
    /// "ok", "loading", "signed_out", "unreachable" or "rate_limited".
    public let state: String
    public let error: String?
    public let readAt: Date?
    /// A read under way behind the list, which stays as it was until the read lands (#599).
    public let reading: Bool
    public let issues: [WorkPiece]
    public let pulls: [GitHubPull]
    public let unknown: [GitHubUnknownWrite]
    /// The issues in the order the state table lists them (3.11), in the groups that have something in them, each
    /// newest-changed first, as the list kept by pi² groups its work. Worked out once, with the rest.
    public let grouped: [(state: String, name: String, items: [WorkPiece])]
    /// The open pull requests, and those merged or closed in the last seven days, newest first.
    public let openPulls: [GitHubPull]
    public let closedPulls: [GitHubPull]

    public init(_ value: JSONValue?) {
        state = value?["state"]?.stringValue ?? "loading"
        error = value?["error"]?.stringValue
        var read = 0.0
        if case .number(let milliseconds)? = value?["readAt"] { read = milliseconds }
        readAt = read > 0 ? Date(timeIntervalSince1970: read / 1000) : nil
        reading = value?["reading"] == .bool(true)
        issues = (value?["issues"]?.arrayValue ?? []).compactMap(WorkPiece.init)
        pulls = (value?["pulls"]?.arrayValue ?? []).compactMap(GitHubPull.init)
        unknown = (value?["unknown"]?.arrayValue ?? []).compactMap(GitHubUnknownWrite.init)
        grouped = ProjectWork(pieces: issues).grouped
        let newest = pulls.sorted { $0.number > $1.number }
        openPulls = newest.filter { $0.state == "open" }
        closedPulls = newest.filter { $0.state != "open" }
    }

    /// GitHub's last read left something wrong: the list stays as it was read, and nothing can be changed until it is
    /// read again.
    public var troubled: Bool { state == "signed_out" || state == "unreachable" || state == "rate_limited" }

    /// Nothing has been read yet, and the first read is under way: the page shows its frame, calmly, until it lands.
    public var firstRead: Bool { readAt == nil && !troubled }
}
