
import Foundation

// What the relay's client runs over: a WebSocket it opens and reads, with nothing else of the network's. The client is
// pure protocol over these two small protocols, so that its checks run it in memory, and the phone and the Mac give it
// the system's WebSocket (`URLSessionRelayConnector`).

/// One WebSocket message.
public enum RelayFrame: Equatable, Sendable {
	case text(String)
	case binary(Data)
}

/// How a socket to the relay ended: the close code and reason the relay gave, or the HTTP status it answered the upgrade
/// with, where there was one. The relay closes with a fixed word of its own as the reason (`RelayWhy`).
public struct RelaySocketClosed: Error, Equatable, Sendable {
	public let code: Int?
	public let reason: String?
	public let httpStatus: Int?

	public init(code: Int? = nil, reason: String? = nil, httpStatus: Int? = nil) {
		self.code = code
		self.reason = reason
		self.httpStatus = httpStatus
	}
}

/// A socket to the relay.
public protocol RelaySocket: AnyObject, Sendable {
	func send(_ frame: RelayFrame) async throws
	/// The next message; throws `RelaySocketClosed` once the socket has closed, or could not be opened.
	func receive() async throws -> RelayFrame
	/// Closes it; a `receive` waiting then throws.
	func close()
}

/// Opens sockets to the relay. The pairing, where there is one, goes in the `Pi2-Pairing` header (relay/README.md, "The
/// protocol"); a connection without it is a Mac registering.
public protocol RelayConnector: Sendable {
	func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket
}

/// Milliseconds since 1970 by this end's clock, and waiting. The checks give a clock they move themselves.
public protocol RelayClock: Sendable {
	func now() -> Int64
	/// Waits `milliseconds`, or throws `CancellationError` once its task is cancelled.
	func sleep(milliseconds: Int64) async throws
}

public struct SystemRelayClock: RelayClock {
	public init() {}

	public func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

	public func sleep(milliseconds: Int64) async throws {
		try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
	}
}

/// The system's WebSocket, `URLSessionWebSocketTask`, in an ephemeral session: no cookies, no cache, no credentials, and
/// no header but the pairing's. It sends no `Origin`, which the relay refuses with 403 (a web page's, relay/README.md),
/// and the protocol test connects through it to the real relay to show so.
public final class URLSessionRelayConnector: RelayConnector {
	private let session: URLSession

	public init() {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieAcceptPolicy = .never
		configuration.httpShouldSetCookies = false
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = 20
		session = URLSession(configuration: configuration)
	}

	public func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
		var request = URLRequest(url: url)
		if let pairing { request.setValue(pairing.text, forHTTPHeaderField: "Pi2-Pairing") }
		let task = session.webSocketTask(with: request)
		// Room for the largest message either way; the client checks each against the protocol's own limits.
		task.maximumMessageSize = RelayLimits.maxBinary + 1024
		task.resume()
		return URLSessionRelaySocket(task)
	}

	deinit { session.invalidateAndCancel() }
}

final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
	// URLSessionWebSocketTask is safe to use from any thread; nothing else is held.
	private let task: URLSessionWebSocketTask

	init(_ task: URLSessionWebSocketTask) { self.task = task }

	func send(_ frame: RelayFrame) async throws {
		do {
			switch frame {
			case let .text(text): try await task.send(.string(text))
			case let .binary(data): try await task.send(.data(data))
			}
		} catch {
			throw closed()
		}
	}

	func receive() async throws -> RelayFrame {
		let message: URLSessionWebSocketTask.Message
		do {
			message = try await task.receive()
		} catch {
			throw closed()
		}
		switch message {
		case let .string(text): return .text(text)
		case let .data(data): return .binary(data)
		@unknown default: throw closed()
		}
	}

	func close() { task.cancel(with: .normalClosure, reason: nil) }

	private func closed() -> RelaySocketClosed {
		let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
		let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { RelayWhy(word: $0)?.word }
		let status = (task.response as? HTTPURLResponse)?.statusCode
		return RelaySocketClosed(code: code, reason: reason, httpStatus: status == 101 ? nil : status)
	}
}
