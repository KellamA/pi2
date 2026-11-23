
import Foundation
import RemoteKit
import Synchronization

/// A small harness: each failed check prints a line, and the program exits non-zero if any failed. The checks run one
/// after another, never side by side, so the counts need no lock.
enum Check {
	nonisolated(unsafe) static var passed = 0
	nonisolated(unsafe) static var failed: [String] = []

	static func that(_ condition: @autoclosure () throws -> Bool, _ name: String) {
		do {
			if try condition() {
				passed += 1
			} else {
				failed.append(name)
				print("FAIL \(name)")
			}
		} catch {
			failed.append("\(name): \(error)")
			print("FAIL \(name): threw \(error)")
		}
	}

	/// As `that`, for a condition worked out before, where it needed `await`.
	static func holds(_ condition: Bool, _ name: String) { that(condition, name) }

	/// That two values are equal, printing both when they are not.
	static func equal<T: Equatable>(_ actual: T?, _ expected: T, _ name: String) {
		if actual == expected {
			passed += 1
		} else {
			failed.append(name)
			print("FAIL \(name):\n  got      \(actual.map { String(describing: $0) } ?? "nothing")\n  expected \(expected)")
		}
	}

	/// That `body` throws RemoteKit's own error.
	static func refuses(_ name: String, _ body: () throws -> Void) {
		do {
			try body()
			failed.append(name)
			print("FAIL \(name): was taken")
		} catch is RemoteKitError {
			passed += 1
			if verbose { print("ok   refused \(name)") }
		} catch {
			failed.append(name)
			print("FAIL \(name): threw something other than RemoteKitError: \(error)")
		}
	}

	/// That an asynchronous call throws the relay client's error `expected`.
	static func throwsError<T>(_ name: String, _ expected: RelayClientError, _ body: () async throws -> T) async {
		do {
			_ = try await body()
			failed.append(name)
			print("FAIL \(name): did not throw")
		} catch let error as RelayClientError {
			equal(error, expected, name)
		} catch {
			failed.append(name)
			print("FAIL \(name): threw \(error)")
		}
	}

	/// Runs `body`, counting a throw as a failure.
	static func runs(_ name: String, _ body: () async throws -> Void) async {
		do {
			try await body()
			passed += 1
		} catch {
			failed.append("\(name): \(error)")
			print("FAIL \(name): \(error)")
		}
	}

	static func section(_ title: String) { print("== \(title)") }

	static let verbose = CommandLine.arguments.contains("--verbose")
}

/// A check that waited too long for something that did not come.
struct Timeout: Error, CustomStringConvertible {
	let what: String
	var description: String { "nothing came: \(what)" }
}

/// A queue one side puts into and the other takes from, waiting, with an end that, once every item is taken, throws.
final class Queue<T: Sendable>: Sendable {
	private struct State {
		var items: [T] = []
		var ended: (any Error)?
		var waiter: (id: Int, continuation: CheckedContinuation<T?, any Error>)?
		var nextID = 0
	}

	private let state = Mutex(State())

	init() {}

	func put(_ item: T) {
		let waiter: CheckedContinuation<T?, any Error>? = state.withLock { state in
			guard state.ended == nil else { return nil }
			if let waiter = state.waiter {
				state.waiter = nil
				return waiter.continuation
			}
			state.items.append(item)
			return nil
		}
		waiter?.resume(returning: item)
	}

	func end(_ error: any Error) {
		let waiter: CheckedContinuation<T?, any Error>? = state.withLock { state in
			guard state.ended == nil else { return nil }
			state.ended = error
			guard state.items.isEmpty, let waiter = state.waiter else { return nil }
			state.waiter = nil
			return waiter.continuation
		}
		waiter?.resume(throwing: error)
	}

	var isEnded: Bool { state.withLock { $0.ended != nil } }

	/// The next item, waiting as long as it takes; throws the end's error once the items are gone.
	func take() async throws -> T {
		guard let item = try await take(seconds: nil) else { throw CancellationError() }
		return item
	}

	/// The next item, or nil if none came within `seconds` of real time.
	func take(seconds: Double?) async throws -> T? {
		let id = state.withLock { state in
			state.nextID += 1
			return state.nextID
		}
		if let seconds {
			Task {
				try? await Task.sleep(for: .seconds(seconds))
				let waiter: CheckedContinuation<T?, any Error>? = self.state.withLock { state in
					guard let waiter = state.waiter, waiter.id == id else { return nil }
					state.waiter = nil
					return waiter.continuation
				}
				waiter?.resume(returning: nil)
			}
		}
		return try await withCheckedThrowingContinuation { continuation in
			let ready: Result<T?, any Error>? = state.withLock { state in
				if !state.items.isEmpty { return .success(state.items.removeFirst()) }
				if let ended = state.ended { return .failure(ended) }
				state.waiter = (id, continuation)
				return nil
			}
			if let ready { continuation.resume(with: ready) }
		}
	}

	/// What waits without being taken.
	var waiting: [T] { state.withLock { $0.items } }
}

/// Reads an async stream into a queue, so that a check can wait for its next element with a limit.
final class Inbox<T: Sendable>: Sendable {
	let queue = Queue<T>()
	private let seen = Locked<[T]>([])

	init(_ stream: AsyncStream<T>) {
		let queue = queue
		let seen = seen
		Task {
			for await element in stream {
				seen.withLock { $0.append(element) }
				queue.put(element)
			}
			queue.end(CancellationError())
		}
	}

	/// Every element so far, taken or not.
	var all: [T] { seen.withLock { $0 } }

	func next(_ what: String, seconds: Double = 10) async throws -> T {
		guard let element = try await queue.take(seconds: seconds) else { throw Timeout(what: what) }
		return element
	}

	/// The next element for which `match` gives a value, skipping the others; at most `seconds` of real time.
	func next<U>(_ what: String, seconds: Double = 10, _ match: (T) -> U?) async throws -> U {
		let deadline = Date().addingTimeInterval(seconds)
		while true {
			let left = deadline.timeIntervalSinceNow
			guard left > 0, let element = try await queue.take(seconds: left) else { throw Timeout(what: what) }
			if let value = match(element) { return value }
		}
	}
}

extension Data {
	init?(hex: String) {
		let characters = Array(hex.utf8)
		guard characters.count % 2 == 0 else { return nil }
		var bytes = [UInt8]()
		var index = 0
		while index < characters.count {
			guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else { return nil }
			bytes.append(high << 4 | low)
			index += 2
		}
		self.init(bytes)
	}

	private static func nibble(_ character: UInt8) -> UInt8? {
		switch character {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
		case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
		default: nil
		}
	}

	var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// A value behind a lock, held by reference so that a task can share it.
final class Locked<Value: Sendable>: Sendable {
	private let mutex: Mutex<Value>

	init(_ value: Value) { mutex = Mutex(value) }

	func withLock<R>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}
