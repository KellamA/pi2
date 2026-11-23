import Foundation
import Observation

/// What the phone has written and not yet seen taken by the Mac (docs/iphone.md section 1; docs/design/iphone.md, "The
/// phone when the Mac is asleep or out of reach"): messages, stops and answers written while the Mac was out of reach,
/// kept in the phone's store, sealed with the cache key, until the Mac takes them.
///
/// - **Writing**: `write` takes a request the person made while the Mac is out of reach (`CachedTransport` hands it
///   each), or refuses it with why. It keeps at most 50 items, what the relay's mailbox takes from one device (5.3).
/// - **Sending**: `send(through:)` hands the items to the Mac oldest first, one at a time, through a courier the
///   session gives (`OutboxCourier`). What the Mac takes leaves the Outbox; what it refuses stays, saying why, with its
///   text to send again; what could not reach it stops the round, so nothing written later overtakes it.
/// - **Late**: an item the Mac has not taken within its lifetime (a day; an hour for one that widens reach, 4.3) is not
///   sent, and says so.
@MainActor
@Observable
final class Outbox {
    static let limit = 50

    /// What came of one round of sending.
    struct Report: Equatable, Sendable {
        /// Taken by the Mac, by id.
        var taken: [String] = []
        /// Sealed in the relay's mailbox, by id.
        var inMailbox: [String] = []
        /// Refused by the Mac, or too late, by id.
        var notSent: [String] = []
        /// Why the round stopped before the end, when the Mac could not be reached.
        var stopped: String?
    }

    let store: PhoneStore
    /// Whether a round of sending is under way.
    private(set) var sending = false
    @ObservationIgnored private let now: @MainActor () -> Date

    init(store: PhoneStore, now: @escaping @MainActor () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// The items, oldest first.
    var items: [OutboxItem] { store.outbox }

    /// How many wait to be sent: what a badge or the connection bar counts.
    var waitingCount: Int { items.filter(\.isPending).count }

    // MARK: - Writing

    /// Takes the person's request into the Outbox, or says why not, for `CachedTransport`.
    func write(_ method: String, _ params: [String: Any]) -> CachedTransport.Write {
        do {
            return .kept(try add(method, params).id)
        } catch let error as StoreError {
            return .refused(error.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Adds the request to the Outbox and keeps it on disk at once.
    @discardableResult
    func add(_ method: String, _ params: [String: Any]) throws -> OutboxItem {
        guard store.isOpen else { throw StoreError("Open pi² with Face ID first.") }
        guard items.count < Self.limit else {
            throw StoreError("The Outbox is full: \(Self.limit) things wait for your Mac. Remove one, or wait until your Mac can be reached.")
        }
        switch OutboxItem.make(method, params, at: now()) {
        case .success(let item):
            try store.setOutbox(items + [item])
            return item
        case .failure(.because(let why)):
            throw StoreError(why)
        case .failure(.notKept):
            throw StoreError(CachedTransport.needsTheMac)
        }
    }

    /// Takes an item out of the Outbox, as the person asked. One already handed to the Mac may have reached it.
    func remove(_ id: String) throws {
        try store.setOutbox(items.filter { $0.id != id })
    }

    /// Writes an item that was not sent again, as a new one: a new id and a new date, the same request, at the end.
    @discardableResult
    func sendAgain(_ id: String) throws -> OutboxItem {
        guard let old = items.first(where: { $0.id == id }) else { throw StoreError("That is no longer in the Outbox.") }
        var params = old.parameters
        // A message again is a new message to the engine, so it needs a request id of its own.
        if old.method == "submit" { params["requestId"] = UUID().uuidString }
        let rest = items.filter { $0.id != id }
        switch OutboxItem.make(old.method, params, at: now()) {
        case .success(let item):
            try store.setOutbox(rest + [item])
            return item
        case .failure(.because(let why)):
            throw StoreError(why)
        case .failure(.notKept):
            throw StoreError(CachedTransport.needsTheMac)
        }
    }

    // MARK: - Sending

    /// Sends what waits, oldest first, one at a time, through `courier`; a round already under way is not doubled.
    @discardableResult
    func send(through courier: some OutboxCourier) async -> Report {
        var report = Report()
        guard !sending, store.isOpen else { return report }
        sending = true
        defer { sending = false }
        expire(into: &report)
        var handed: Set<String> = []
        // Read afresh each time: the person may add or remove items while one is on its way.
        while let next = items.first(where: { $0.isPending && !handed.contains($0.id) }) {
            handed.insert(next.id)
            if next.isExpired(at: now()) {
                guard update(next.id, { $0.state = .notSent($0.tooLate) }) else { break }
                report.notSent.append(next.id)
                continue
            }
            // Kept as handed over before it goes, so that if the app stops now it is sent again with the same id.
            guard update(next.id, { $0.state = .sending }) else { break }
            let outcome = await courier.deliver(next)
            switch outcome {
            case .taken:
                guard (try? store.setOutbox(items.filter { $0.id != next.id })) != nil else { return report }
                report.taken.append(next.id)
            case .refused(let why):
                guard update(next.id, { $0.state = .notSent(why) }) else { return report }
                report.notSent.append(next.id)
            case .inMailbox:
                let date = now()
                guard update(next.id, { $0.state = .inMailbox(date) }) else { return report }
                report.inMailbox.append(next.id)
            case .unreachable(let why):
                _ = update(next.id) {
                    $0.state = .waiting
                    $0.tries += 1
                }
                report.stopped = why
                return report
            }
        }
        return report
    }

    /// The Mac's receipt for an item it found in its mailbox (5.3): taken, or refused with why ("This is no longer
    /// waiting…", "Not sent: more than a day passed…").
    func receipt(for id: String, taken: Bool, why: String? = nil) {
        guard items.contains(where: { $0.id == id }) else { return }
        if taken {
            try? store.setOutbox(items.filter { $0.id != id })
        } else {
            _ = update(id) { $0.state = .notSent(why ?? "Your Mac did not take this.") }
        }
    }

    /// Marks as not sent what waited past its lifetime: what was never sent, and what lies in the mailbox with no
    /// receipt once the Mac could no longer take it.
    func expire() {
        var report = Report()
        expire(into: &report)
    }

    private func expire(into report: inout Report) {
        let date = now()
        for item in items where item.isExpired(at: date) {
            switch item.state {
            case .waiting, .sending:
                if update(item.id, { $0.state = .notSent($0.tooLate) }) { report.notSent.append(item.id) }
            case .inMailbox:
                if update(item.id, { $0.state = .notSent("Your Mac did not say whether it took this before it was too late. Check on your Mac before sending it again.") }) {
                    report.notSent.append(item.id)
                }
            case .notSent:
                break
            }
        }
    }

    /// Changes one item and keeps the Outbox on disk; false when it could not be kept (the store closed).
    private func update(_ id: String, _ change: (inout OutboxItem) -> Void) -> Bool {
        var all = items
        guard let index = all.firstIndex(where: { $0.id == id }) else { return true }
        change(&all[index])
        return (try? store.setOutbox(all)) != nil
    }
}
