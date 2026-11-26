
import Foundation
import Synchronization

/// What a path brought, in order, for one reader: a queue with a single waiting reader, closed once. A link's messages
/// come here as its network gives them; the channel reads them one at a time.
final class Inbox<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var waiter: CheckedContinuation<Element?, Never>?
        var closed = false
    }

    private let state = Mutex(State())

    init() {}

    /// Adds one, or hands it to the reader waiting. Nothing is taken once the inbox is closed.
    func push(_ element: Element) {
        let waiter: CheckedContinuation<Element?, Never>? = state.withLock { state in
            guard !state.closed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.items.append(element)
            return nil
        }
        waiter?.resume(returning: element)
    }

    /// Closes it: the reader gets what is left, then nil.
    func finish() {
        let waiter = state.withLock { state in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// Whether `finish` was called, whatever is left to read.
    var isFinished: Bool { state.withLock { $0.closed } }

    /// The next one, or nil once it is closed and empty, or the task is cancelled.
    func next() async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now: Element?? = state.withLock { state in
                    if !state.items.isEmpty { return .some(state.items.removeFirst()) }
                    if state.closed || Task.isCancelled { return .some(nil) }
                    state.waiter = continuation
                    return .none
                }
                if case let .some(element) = now { continuation.resume(returning: element) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    /// The next one within `limit`: nil once closed, `LinkError.timedOut` when nothing came in time.
    func next(within limit: Duration) async throws -> Element? {
        let outcome = await withTaskGroup(of: InboxOutcome<Element>.self) { group in
            group.addTask { .element(await self.next()) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch outcome {
        case let .element(element): return element
        case .timedOut: throw LinkError.timedOut
        }
    }
}

private enum InboxOutcome<Element: Sendable>: Sendable {
    case element(Element?)
    case timedOut
}

/// Why a path gave no link, or a link stopped.
enum LinkError: Error, Equatable, Sendable {
    /// Nothing came in time.
    case timedOut
    /// The other end, or the network, closed it.
    case closed
    /// No address to try, and nothing found on the network.
    case nowhere
    /// The relay refused, or stopped, with its word.
    case relay(RelayWord)
    /// A build without App Attest cannot join at the relay (docs/iphone.md 10).
    case noAppAttest
}

/// A relay's word, kept as its text so that `LinkError` stays simple to compare.
struct RelayWord: Equatable, Sendable, CustomStringConvertible {
    let word: String
    var description: String { word }
}
