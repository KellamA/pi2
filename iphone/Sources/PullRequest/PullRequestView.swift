import EngineKit
import PiModels
import SwiftUI

/// A pull request, opened from Work: its state, checks, what reviewing agents found, and its files, with Merge and Send
/// back; and, with `file`, one file's diff, lines wrapped, additions and removals coloured (docs/design/iphone.md, "The
/// Work tab, and a pull request with its diff"). Everything is read from the session's `github` event, as the Mac's Work
/// tab reads it, and the diff from `github.diff`; a file's diff opens with `openRoute(.pullRequest(project:number:file:))`.
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

    @Environment(AppSession.self) private var session

    var body: some View {
        let source = PullRequestSource(session.engine, project: projectID, number: number)
        Group {
            switch source.state {
            case .waiting:
                ProgressView("Waiting for your Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noProject:
                PullRequestUnavailable {
                    ContentUnavailableView(
                        "No such project", systemImage: "questionmark.folder",
                        description: Text("Your Mac has no project by this name now. It may have been deleted.")
                    )
                }
            case .noRepository(let name):
                PullRequestUnavailable {
                    ContentUnavailableView(
                        "No pull requests here", systemImage: "arrow.triangle.pull",
                        description: Text("\(name)'s work is kept by pi², not in a GitHub repository, so it has no pull requests. A repository is attached to a project on the Mac.")
                    )
                }
            case .firstRead(let repository):
                ProgressView("Reading \(repository) on GitHub…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notListed(let repository, let trouble):
                PullRequestNotListed(number: number, repository: repository, trouble: trouble)
            case .listed(let pull, let listing):
                if let file {
                    PullRequestFilePage(key: source.key, number: number, path: file, diff: source.diff, sample: source.sample)
                } else {
                    PullRequestPage(key: source.key, pull: pull, listing: listing, diff: source.diff, sample: source.sample)
                }
            }
        }
        .navigationTitle(file.map { PullRequestDiff.File.name(of: $0) } ?? "#\(number)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source.readsDiff) {
            // The page lists the files, so it reads the diff each time it opens (a push changes it); a file's page reads it
            // only if nothing has.
            guard source.readsDiff else { return }
            PullRequestStore.shared.readDiff(source.key, through: session.engine, again: file == nil)
        }
    }
}

/// What the screen shows of one pull request, worked out from the session: whether the Mac has answered yet, whether
/// the project has a repository, and the pull request as the last read of it lists it (`GitHubPull` in `GitHubWork`),
/// with its diff as read.
@MainActor
struct PullRequestSource {
    /// Not `Equatable`: `GitHubWork` cannot be (its `grouped` tuples), and nothing compares a state; the screens
    /// switch over it.
    enum State {
        /// The engine's lists have not come yet.
        case waiting
        case noProject
        /// The project's work is kept by pi²: it has no pull requests. Its name.
        case noRepository(String)
        /// The repository is attached and nothing has been read of it yet. "owner/name".
        case firstRead(String)
        /// The last read does not list it: "owner/name", and what went wrong with the read, if anything.
        case notListed(String, trouble: String?)
        case listed(GitHubPull, GitHubWork)
    }

    let key: PullRequestStore.Key
    let state: State
    let diff: PullRequestStore.DiffState?
    /// A debug build's sample, drawn in place of what the Mac sent (`PullRequestSamples`); false in a release build.
    let sample: Bool

    init(_ engine: EngineSession<MessageField>, project id: String, number: Int, store: PullRequestStore = .shared) {
        key = PullRequestStore.Key(project: id, number: number)
        #if DEBUG
        if let sample = PullRequestSamples.current, let pull = sample.listing.pull(number) {
            state = .listed(pull, sample.listing)
            diff = sample.diff.map { .read($0) } ?? store.diffs[key]
            self.sample = true
            return
        }
        #endif
        sample = false
        diff = store.diffs[key]
        guard let project = engine.projects.first(where: { $0.id == id }) else {
            state = engine.status != .connected || !engine.hasLoadedLibrary ? .waiting : .noProject
            return
        }
        guard let repository = project.repository else {
            state = .noRepository(project.name)
            return
        }
        let name = "\(repository.owner)/\(repository.name)"
        let listing = GitHubWork.of(engine.extras["github"], project: id)
        if let listing, let pull = listing.pull(number) {
            state = .listed(pull, listing)
        } else if listing?.firstRead != false {
            state = .firstRead(name)
        } else {
            state = .notListed(name, trouble: listing?.troubleWords())
        }
    }

    /// Whether the diff is to be read: only for a pull request the Mac lists, and never for a sample's own diff.
    var readsDiff: Bool {
        guard case .listed = state else { return false }
        #if DEBUG
        if sample, PullRequestSamples.current?.diff != nil { return false }
        #endif
        return true
    }
}

/// The pull request is not in what the Mac last read: the Mac lists the open ones, and those merged or closed in the
/// last week. GitHub has it all.
private struct PullRequestNotListed: View {
    let number: Int
    let repository: String
    let trouble: String?

    var body: some View {
        PullRequestUnavailable { unavailable }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Pull request #\(number) is not listed", systemImage: "arrow.triangle.pull")
        } description: {
            Text(trouble ?? "Your Mac lists \(repository)'s open pull requests, and those merged or closed in the last week. This one is not among them.")
        } actions: {
            if let url = URL(string: "https://github.com/\(repository)/pull/\(number)") {
                Link("Open on GitHub", destination: url)
            }
        }
    }
}

/// What a screen says in place of its content, scrolling when its words are taller than the screen, as at the largest
/// text sizes, and in the middle of it otherwise.
struct PullRequestUnavailable<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

extension PullRequestDiff.File {
    /// A path's last part, for a title.
    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
