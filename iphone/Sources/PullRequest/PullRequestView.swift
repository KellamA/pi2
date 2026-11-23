import SwiftUI

/// A pull request, opened from Work: its checks, what a reviewing agent found, and its files; one file's diff at a time,
/// lines wrapped, additions and removals coloured; Merge, and Send back, which asks why (docs/design/iphone.md, "The
/// Work tab, and a pull request with its diff"). #695 builds it: replace this body, keep the type and its initialiser,
/// and add files beside it in `PullRequest/`. A file's diff opens with `openRoute(.pullRequest(project:number:file:))`.
struct PullRequestView: View {
    /// The project's id, as `ProjectRow.id`.
    let projectID: String
    /// The pull request's number.
    let number: Int
    /// The file whose diff it shows, by its path in the repository; nil for the pull request itself.
    let file: String?

    init(projectID: String, number: Int, file: String? = nil) {
        self.projectID = projectID
        self.number = number
        self.file = file
    }

    var body: some View {
        FeaturePlaceholder(screen: file == nil ? "Pull request" : "A file's diff", issue: 695,
                           details: ["project \(projectID)", "pull request #\(number)"] + (file.map { [$0] } ?? []))
    }
}
