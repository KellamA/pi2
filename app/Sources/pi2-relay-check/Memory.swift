
import Foundation
import RemoteKit
import Synchronization

/// A clock the checks move themselves: `sleep` returns once `advance` has passed its time, so that a wait of an hour
/// takes none, and nothing depends on how fast the computer is.
final class ManualClock: RelayClock, Sendable {
	private struct Sleeper {
		let id: Int
		let deadline: Int64
		let continuation: CheckedContinuation<Void, any Error>
	}

	private struct State {
		var now: Int64
		var sleepers: [Sleeper] = []
		var nextID = 0
		var cancelled: Set<Int> = []
	}

	private let state: Mutex<State>

	init(now: Int64 = 1_800_000_000_000) {
		state = Mutex(State(now: now))
	}

	func now() -> Int64 { state.withLock { $0.now } }

	func sleep(milliseconds: Int64) async throws {
		let id = state.withLock { state in
			state.nextID += 1
			return state.nextID
		}
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
				let ready: Result<Void, any Error>? = state.withLock { state in
					if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
					if milliseconds <= 0 { return .success(()) }
					state.sleepers.append(Sleeper(id: id, deadline: state.now + milliseconds, continuation: continuation))
					return nil
				}
				if let ready { continuation.resume(with: ready) }
			}
		} onCancel: {
			let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
				if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
					return state.sleepers.remove(at: index).continuation
				}
				state.cancelled.insert(id)
				return nil
			}
			continuation?.resume(throwing: CancellationError())
		}
	}

	/// Moves the clock on, and wakes every sleeper whose time has come.
	func advance(_ milliseconds: Int64) {
		let due: [Sleeper] = state.withLock { state in
			state.now += milliseconds
			let now = state.now
			let due = state.sleepers.filter { $0.deadline <= now }
			state.sleepers.removeAll { $0.deadline <= now }
			return due
		}
		for sleeper in due { sleeper.continuation.resume() }
	}

	/// Waits, in real time, until something sleeps until `deadline`: so that moving the clock wakes it.
	func waitForSleeper(until deadline: Int64, seconds: Double = 10) async throws {
		let limit = Date().addingTimeInterval(seconds)
		while !state.withLock({ $0.sleepers.contains { $0.deadline == deadline } }) {
			guard Date() < limit else { throw Timeout(what: "a sleeper until \(deadline)") }
			try await Task.sleep(for: .milliseconds(2))
		}
	}

	/// The times the sleepers wait until.
	var deadlines: [Int64] { state.withLock { $0.sleepers.map(\.deadline) } }
}

/// One socket in memory: the client's end is the `RelaySocket`; the check plays the relay at the other.
final class MemorySocket: RelaySocket {
	let url: URL
	let pairing: PairingID?
	/// What the client sent, in order.
	let sent = Queue<RelayFrame>()
	private let incoming = Queue<RelayFrame>()
	private let closedByClient = Mutex(false)

	init(url: URL, pairing: PairingID?) {
		self.url = url
		self.pairing = pairing
	}

	func send(_ frame: RelayFrame) async throws {
		guard !closedByClient.withLock({ $0 }), !incoming.isEnded else { throw RelaySocketClosed() }
		sent.put(frame)
	}

	func receive() async throws -> RelayFrame { try await incoming.take() }

	func close() {
		closedByClient.withLock { $0 = true }
		incoming.end(RelaySocketClosed())
		sent.end(RelaySocketClosed())
	}

	var isClosedByClient: Bool { closedByClient.withLock { $0 } }

	// The relay's side.

	func say(_ text: String) { incoming.put(.text(text)) }

	func sayBytes(_ bytes: Data) { incoming.put(.binary(bytes)) }

	/// Closes from the relay's side, as the relay does after a refusal or `busy`.
	func hangUp(code: Int? = nil, reason: String? = nil) { incoming.end(RelaySocketClosed(code: code, reason: reason)) }

	/// The next text the client sent.
	func nextText(_ what: String, seconds: Double = 10) async throws -> String {
		guard let frame = try await sent.take(seconds: seconds) else { throw Timeout(what: what) }
		guard case let .text(text) = frame else { throw Timeout(what: "\(what), not bytes") }
		return text
	}

	func nextBytes(_ what: String, seconds: Double = 10) async throws -> Data {
		guard let frame = try await sent.take(seconds: seconds) else { throw Timeout(what: what) }
		guard case let .binary(bytes) = frame else { throw Timeout(what: "\(what), not text") }
		return bytes
	}
}

/// Hands each socket the client opens to the check, or fails the next connections with what it was given.
final class MemoryConnector: RelayConnector {
	let sockets = Queue<MemorySocket>()
	private let failures = Mutex<[RelaySocketClosed]>([])

	func failNext(_ closed: RelaySocketClosed) { failures.withLock { $0.append(closed) } }

	func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
		if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
			sockets.put(MemorySocket(url: url, pairing: pairing))
			throw failure
		}
		let socket = MemorySocket(url: url, pairing: pairing)
		sockets.put(socket)
		return socket
	}

	func next(_ what: String, seconds: Double = 10) async throws -> MemorySocket {
		guard let socket = try await sockets.take(seconds: seconds) else { throw Timeout(what: what) }
		return socket
	}
}
