#if DEBUG
import Foundation
import PiModels

/// A debug build's sample pull request, for drawing and picturing the pull request's states before a Mac with a GitHub
/// repository, or the demo mode (#684), can send one: the recorded session's projects keep their work in pi², so they
/// have no pull requests. None of it is compiled into a release build, and nothing here answers: the sample is the
/// `github` event's JSON and `gh pr diff`'s text as the engine sends them, drawn in place of the Mac's listing for pull
/// request #7, and the page says so. Merge, Send back and the rest send their real requests through the session's
/// client, which the recording refuses, and the page shows that refusal.
///
/// Read from the environment at launch (`xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>` as `<NAME>`):
///
/// - `PI2_PR_SAMPLE=<name>`: `open` (checks passing, findings, four files), `failing` (a draft with failing checks and
///   a conflict), `running`, `merged`, `closed` (closed, listed without its checks and findings), `trouble` (GitHub
///   unreachable on the Mac), `unknown` (a write whose outcome is unknown), `large` (a file of 4,000 lines and a line of
///   5,000 characters), `nodiff` (the diff is asked of the engine, which the recording refuses).
/// - `PI2_PR_PRESS=merge` opens the merge question once the page shows, `send-back` the sheet, `merge-now` sends the
///   merge at once, so that each can be pictured with no tap.
/// - `PI2_PR_WRAP=off` opens a file's diff with long lines scrolling sideways.
struct PullRequestSamples {
    let listing: PullRequestListing
    /// The sample's diff; nil to ask the engine for it.
    let diff: PullRequestDiff?

    static let current: PullRequestSamples? = {
        guard let name = ProcessInfo.processInfo.environment["PI2_PR_SAMPLE"], !name.isEmpty else { return nil }
        return PullRequestSamples(name, now: Date())
    }()

    static let wrap = ProcessInfo.processInfo.environment["PI2_PR_WRAP"] != "off"
    private static let pressing = ProcessInfo.processInfo.environment["PI2_PR_PRESS"]
    @MainActor private static var pressed = false

    /// Does what `PI2_PR_PRESS` names, once a launch.
    @MainActor
    static func press(merge: () -> Void, sendBack: () -> Void, mergeNow: () -> Void) {
        guard !pressed, let pressing else { return }
        pressed = true
        switch pressing {
        case "merge": merge()
        case "send-back": sendBack()
        case "merge-now": mergeNow()
        default: break
        }
    }

    init?(_ name: String, now: Date) {
        let ms = (now.timeIntervalSince1970 * 1000).rounded()
        func ago(_ minutes: Double) -> Double { ms - minutes * 60_000 }
        var pull: [String: Any] = [
            "number": 7, "title": "Hub: fold the board below 900 points", "url": "https://github.com/example/demo/pull/7",
            "head": "pi2/5-hub-fold", "base": "main", "author": "pi2-agent", "state": "open", "draft": false,
            "checks": "passing", "failingChecks": [], "mergeable": "yes", "openedBy": ["conversationId": 31], "work": 5,
            "findings": [
                ["agentName": "Scout", "verdict": "approve", "at": ago(12), "url": "https://github.com/example/demo/pull/7#issuecomment-2",
                 "text": "Folding works at both widths. One nit on the key's name, fixed in `3e1c`."],
                ["agentName": "Forge", "verdict": "comment", "at": ago(95), "url": "https://github.com/example/demo/pull/7#issuecomment-1",
                 "text": "Ready for review. The board folds below 900 points and opens again above 1,000, so a window dragged across one width does not flicker.\n\nTried at 880, 900, 950 and 1,020 points, with the board open and folded, in both appearances.\n\nNot tried: a window on a second display with a different scale, since this Mac has one display.\n\nThe docs say so in projects.md."],
            ],
        ]
        var listing: [String: Any] = ["state": "ok", "readAt": ago(1), "reading": false, "unknown": []]
        var diff: PullRequestDiff? = PullRequestDiff(text: Self.diffText)
        switch name {
        case "open", "nodiff":
            if name == "nodiff" { diff = nil }
        case "failing":
            pull["draft"] = true
            pull["checks"] = "failing"
            pull["mergeable"] = "no"
            pull["failingChecks"] = [
                ["name": "App (build)", "url": "https://github.com/example/demo/actions/runs/1/job/1"],
                ["name": "Engine (type-check and tests)", "url": "https://github.com/example/demo/actions/runs/1/job/2"],
            ]
            pull["findings"] = [
                ["agentName": "Scout", "verdict": "changes", "at": ago(4), "url": "", "text": "The board stays folded after the window grows past 1,000 points again: `boardFolded` is never set back."],
            ]
        case "running":
            pull["checks"] = "pending"
            pull["findings"] = []
        case "merged":
            pull["state"] = "merged"
        case "closed":
            pull["state"] = "closed"
            pull["partial"] = true
            pull["findings"] = []
            pull["openedBy"] = NSNull()
        case "trouble":
            listing["state"] = "unreachable"
            listing["readAt"] = ago(22)
        case "unknown":
            listing["unknown"] = [["intent": "i-1", "summary": "merging pull request #6", "at": ago(30)]]
        case "large":
            diff = PullRequestDiff(text: Self.largeDiffText)
        default:
            return nil
        }
        listing["pulls"] = [pull]
        guard let data = try? JSONSerialization.data(withJSONObject: listing),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self.listing = PullRequestListing(value)
        self.diff = diff
    }

    /// Four files as `gh pr diff` prints them: one changed, with a line far longer than a phone is wide; one added; one
    /// renamed with no change; one binary.
    static let diffText = """
    diff --git a/app/Sources/pi2/ProjectHub.swift b/app/Sources/pi2/ProjectHub.swift
    index 3e1c0a2..9b7f4d1 100644
    --- a/app/Sources/pi2/ProjectHub.swift
    +++ b/app/Sources/pi2/ProjectHub.swift
    @@ -88,12 +88,19 @@ struct ProjectHub: View {
         var body: some View {
    -        HStack { conversation; board }
    +        HStack(spacing: 0) {
    +            conversation
    +            if !boardFolded { board }
    +        }
    +        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
    +            // Folds below 900 points and opens again above 1,000, so a window dragged across one width does not flicker.
    +            if width < 900 { boardFolded = true } else if width > 1000 { boardFolded = false }
    +        }
         }
     
         private var conversation: some View {
    @@ -140,6 +147,8 @@ struct ProjectHub: View {
         private var board: some View {
             ProjectBoard(project: project)
    +            .frame(minWidth: 320)
    +            .transition(.move(edge: .trailing))
         }
     }
    \\ No newline at end of file
    diff --git a/docs/projects.md b/docs/projects.md
    new file mode 100644
    index 0000000..5d2a1c3
    --- /dev/null
    +++ b/docs/projects.md
    @@ -0,0 +1,3 @@
    +## The board, folded
    +
    +Below 900 points the board folds under the conversation, and a tab at the window's edge opens it again.
    diff --git a/changelog.d/5.md b/changelog.d/5-hub.md
    similarity index 100%
    rename from changelog.d/5.md
    rename to changelog.d/5-hub.md
    diff --git a/docs/pictures/hub-folded.png b/docs/pictures/hub-folded.png
    index 1a2b3c4..5d6e7f8 100644
    Binary files a/docs/pictures/hub-folded.png and b/docs/pictures/hub-folded.png differ
    """

    /// One file of 4,000 added lines, the second of them 5,000 characters long, as a generated file's diff is.
    static let largeDiffText: String = {
        var lines = [
            "diff --git a/engine/test/fixtures/listing.json b/engine/test/fixtures/listing.json",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/engine/test/fixtures/listing.json",
            "@@ -0,0 +1,4000 @@",
            "+[",
            "+" + String(repeating: "{\"n\":1,\"title\":\"A long generated line\"},", count: 120),
        ]
        for index in 3...4_000 { lines.append("+  {\"number\": \(index), \"title\": \"Issue \(index)\"},") }
        return lines.joined(separator: "\n")
    }()
}
#endif
