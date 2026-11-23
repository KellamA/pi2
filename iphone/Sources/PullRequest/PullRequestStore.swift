import EngineKit
import Foundation
import Observation
import PiModels

/// What the pull request's screens keep while the app runs, in memory only (the phone's store is #692's): each pull
/// request's diff as the engine last answered it, read once for its page and its files' pages alike, and what was asked
/// of it and not yet answered. Nothing here is the engine's state: the pull request itself is always read from the
/// session's `github` event.
@MainActor
@Observable
final class PullRequestStore {
    static let shared = PullRequestStore()

    enum DiffState: Equatable {
        case reading
        case read(PullRequestDiff)
        /// The engine's words when it did not send the diff.
        case refused(String)
    }

    /// One pull request, by its project and number.
    struct Key: Hashable {
        let project: String
        let number: Int
    }

    private(set) var diffs: [Key: DiffState] = [:]
    /// What was asked and not answered yet ("Merging", "Sending back"), by pull request: shown at once, and nothing else
    /// is sent for it meanwhile, so a second tap writes nothing twice.
    private(set) var pending: [Key: String] = [:]
    /// The engine's words when it refused what was asked, by pull request, until the next request for it.
    private(set) var problems: [Key: String] = [:]
    /// The writes being settled, by intent.
    private(set) var settling: Set<String> = []
    /// The diffs being read now.
    @ObservationIgnored private var reading: Set<Key> = []

    /// Reads the diff, unless it is being read already. `again` reads it even when it was read before, as the pull
    /// request's page does each time it opens, since a push changes it.
    func readDiff(_ key: Key, through engine: EngineSession<MessageField>, again: Bool = false) {
        guard !reading.contains(key) else { return }
        if case .read? = diffs[key] {
            // A diff read before stays shown while it is read again.
            if !again { return }
        } else {
            diffs[key] = .reading
        }
        reading.insert(key)
        Task {
            defer { reading.remove(key) }
            switch await PullRequestRequest.diff(project: key.project, number: key.number).send(through: engine) {
            case .success(let answer):
                let text = answer["diff"]?.stringValue ?? ""
                // A diff can be 2 MB: read into files away from the main thread.
                let diff = await Task.detached(priority: .userInitiated) { PullRequestDiff(text: text) }.value
                diffs[key] = .read(diff)
            case .failure(let refusal):
                // A diff read before stays: the refusal is of reading it again.
                if case .read? = diffs[key] {
                    problems[key] = "Your Mac did not send the diff again: \(refusal.words)"
                } else {
                    diffs[key] = .refused(refusal.words)
                }
            }
        }
    }

    /// Sends `request` for one pull request, shown as `word` until the engine answers. `failed` runs with the refusal,
    /// after it is kept to show.
    func send(_ request: PullRequestRequest, for key: Key, shown word: String, through engine: EngineSession<MessageField>,
              failed: @escaping @MainActor (String) -> Void = { _ in }) {
        guard pending[key] == nil else { return }
        pending[key] = word
        problems[key] = nil
        Task {
            let outcome = await request.send(through: engine)
            pending[key] = nil
            if case .failure(let refusal) = outcome {
                problems[key] = refusal.words
                failed(refusal.words)
            }
        }
    }

    /// Says whether a write whose outcome was unknown happened.
    func settle(_ intent: String, happened: Bool, for key: Key, through engine: EngineSession<MessageField>) {
        guard !settling.contains(intent) else { return }
        settling.insert(intent)
        problems[key] = nil
        Task {
            let outcome = await PullRequestRequest.settle(project: key.project, intent: intent, happened: happened).send(through: engine)
            settling.remove(intent)
            if case .failure(let refusal) = outcome { problems[key] = refusal.words }
        }
    }

    /// Reads the listing again, quietly: a refusal shows only as the problem line.
    func refresh(_ key: Key, through engine: EngineSession<MessageField>) async {
        if case .failure(let refusal) = await PullRequestRequest.refresh(project: key.project).send(through: engine) {
            problems[key] = "Your Mac did not read GitHub again: \(refusal.words)"
        }
    }

    func clearProblem(_ key: Key) {
        problems[key] = nil
    }
}

