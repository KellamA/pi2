import Foundation

/// What carries a share's draft to the Mac, for `SharePickup`: the app gives one, which sends `draft.submitParameters`
/// as `submit` through the session's client while the Mac can be reached, and puts a draft of words alone
/// (`mayWaitInMailbox`) into the Outbox while it cannot.
@MainActor
protocol ShareDraftSender {
    func deliver(_ draft: ShareDraft) async -> ShareDelivery
}

/// What came of handing a draft over.
enum ShareDelivery: Equatable, Sendable {
    /// The Mac took the message.
    case taken
    /// It is in the Outbox now, which sends it when the Mac can be reached.
    case kept
    /// The Mac, or the Outbox, refused it, with why in the person's words.
    case refused(String)
    /// Not now: the Mac could not be reached and it cannot wait in the Outbox, or the answer was lost. It stays, to go
    /// again with the same id.
    case unreachable(String)
}

/// Picks up what the share extension left for the app (`ShareDrop`) and hands each draft over, oldest first: what is
/// taken or kept in the Outbox leaves the folder; what is refused, or waited more than a day, stays marked not sent,
/// with why, for the app to show; what cannot go yet stays as it is, and the round stops there so that nothing
/// shared later overtakes it.
@MainActor
enum SharePickup {
    struct Report: Equatable, Sendable {
        var taken: [String] = []
        var kept: [String] = []
        var notSent: [String] = []
        /// Why the round stopped before the end.
        var stopped: String?
    }

    private static var running = false

    @discardableResult
    static func run(_ drop: ShareDrop, through sender: some ShareDraftSender, now: Date = Date()) async -> Report {
        var report = Report()
        guard !running else { return report }
        running = true
        defer { running = false }
        for draft in drop.all() where draft.state == .waiting {
            if draft.isExpired(at: now) {
                mark(draft, .notSent(ShareDraft.tooLate), in: drop)
                report.notSent.append(draft.id)
                continue
            }
            switch await sender.deliver(draft) {
            case .taken:
                drop.remove(draft.id)
                report.taken.append(draft.id)
            case .kept:
                drop.remove(draft.id)
                report.kept.append(draft.id)
            case .refused(let why):
                mark(draft, .notSent(why), in: drop)
                report.notSent.append(draft.id)
            case .unreachable(let why):
                report.stopped = why
                return report
            }
        }
        return report
    }

    private static func mark(_ draft: ShareDraft, _ state: ShareDraft.State, in drop: ShareDrop) {
        var draft = draft
        draft.state = state
        try? drop.write(draft)
    }
}
