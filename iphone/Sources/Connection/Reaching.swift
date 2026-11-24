
import CryptoKit
import Foundation
import Network
import RemoteKit
import Synchronization

/// What each path is made of. The app's are the system's; a test gives its own (a relay on this Mac, a Mac listening on
/// loopback, a finder that finds it).
struct Routes: Sendable {
    var relayConnector: any RelayConnector = URLSessionRelayConnector()
    var relayOptions = RelayOptions()
    /// Bonjour; nil to look for no Mac on the network (a test, or the person's choice).
    var homeFinder: (any HomeFinder)? = BonjourHomeFinder()
    var dialer: any Dialer = TCPDialer()
    /// How long one TCP connection may take to open.
    var dialWithin: Duration = .seconds(4)
    /// How long the network is looked through for the Mac before the home path gives up for this attempt.
    var findWithin: Duration = .seconds(6)
    /// How long the relay may take to be ready, or a join to be answered.
    var relayWithin: Duration = .seconds(30)
}

/// A link and the path it came by.
struct Reached: Sendable {
    let link: any MessageLink
    let path: AppSession.Path
}

/// The home path (5.4), as one attempt: every address given, dialled at once (`direct`), and the network looked through
/// for a service with this pairing's tag (`home`); the first to connect is kept, the rest closed.
enum HomeReach {
    static func attempts(addresses: [String], homeKey: HomeKey?, pairing: PairingID, routes: Routes) -> [@Sendable () async throws -> Reached] {
        var attempts: [@Sendable () async throws -> Reached] = []
        for endpoint in addresses.compactMap(MacAddress.endpoint) {
            attempts.append {
                Reached(link: try await routes.dialer.dial(endpoint, within: routes.dialWithin), path: .direct)
            }
        }
        // Bonjour needs the home key, which only `paired` gives: while pairing, the payload's addresses alone.
        if let finder = routes.homeFinder, let homeKey {
            attempts.append {
                let found = finder.find(homeKey: homeKey, pairing: pairing)
                defer { found.finish() }
                let deadline = ContinuousClock.now + routes.findWithin
                while true {
                    let left = deadline - .now
                    guard left > .zero, let endpoint = try await found.next(within: left) else { throw LinkError.nowhere }
                    if let link = try? await routes.dialer.dial(endpoint, within: routes.dialWithin) { return Reached(link: link, path: .home) }
                }
            }
        }
        return attempts
    }
}

/// Tries several paths at once and keeps the first to come (5.1: "the phone tries both when it connects and keeps
/// whichever comes first"): a link, while pairing; once paired, a channel whose Mac proved itself, since the relay's
/// link comes at once whether or not the Mac answers through it (#898). The others are cancelled, and what one gives
/// after is closed; when every attempt fails, the most telling failure is thrown: the relay's word before a timeout, a
/// timeout before "nowhere".
enum Race {
    static func first(_ attempts: [@Sendable () async throws -> Reached]) async throws -> Reached {
        try await first(attempts, closing: { $0.link.close() })
    }

    static func first<Won: Sendable>(_ attempts: [@Sendable () async throws -> Won], closing: @escaping @Sendable (Won) -> Void) async throws -> Won {
        guard !attempts.isEmpty else { throw LinkError.nowhere }
        let state = Mutex(State<Won>())
        let total = attempts.count

        @Sendable func won(_ reached: Won) {
            let (continuation, losers): (CheckedContinuation<Won, any Error>?, [Task<Void, Never>]) = state.withLock { state in
                guard !state.settled else { return (nil, []) }
                state.settled = true
                defer { state.continuation = nil }
                return (state.continuation, state.tasks)
            }
            guard let continuation else {
                closing(reached)
                return
            }
            continuation.resume(returning: reached)
            for task in losers { task.cancel() }
        }

        @Sendable func lost(_ error: any Error) {
            let (continuation, failures): (CheckedContinuation<Won, any Error>?, [any Error]) = state.withLock { state in
                state.failures.append(error)
                guard !state.settled, state.failures.count == total else { return (nil, []) }
                state.settled = true
                defer { state.continuation = nil }
                return (state.continuation, state.failures)
            }
            continuation?.resume(throwing: telling(failures))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                let tasks = attempts.map { attempt in
                    Task {
                        do { won(try await attempt()) } catch { lost(error) }
                    }
                }
                state.withLock { $0.tasks = tasks }
            }
        } onCancel: {
            let (continuation, tasks) = state.withLock { state in
                state.settled = true
                defer { state.continuation = nil }
                return (state.continuation, state.tasks)
            }
            for task in tasks { task.cancel() }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private struct State<Won: Sendable> {
        var settled = false
        var failures: [any Error] = []
        var continuation: CheckedContinuation<Won, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    static func telling(_ failures: [any Error]) -> any Error {
        func rank(_ error: any Error) -> Int {
            switch error as? LinkError {
            case .relay?: 5
            case .noAppAttest?: 4
            case .timedOut?: 2
            case .closed?: 1
            case .nowhere?: 0
            case nil: 3
            }
        }
        return failures.max { rank($0) < rank($1) } ?? LinkError.nowhere
    }
}
