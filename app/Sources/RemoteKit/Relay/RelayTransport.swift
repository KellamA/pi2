
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

/// The system's WebSocket, `URLSessionWebSocketTask`, in an ephemeral session: no cookies, no cache, no credentials.
/// Its headers are the pairing's and fixed ones in place of those URLSession adds of itself: a `User-Agent` that names
/// no program or system version, and an `Accept-Language` that names no locale (URLSession sends one whatever is set,
/// so it is `*`). It sends no `Origin`, which the relay refuses with 403 (a web page's, relay/README.md), and follows
/// no redirect: a 3xx answer to the upgrade ends the connection with its status, so that a relay cannot send the
/// pairing's id, a join's token or the traffic elsewhere. The protocol test connects through it to the real relay to
/// show both.
///
/// The session lives as long as the connector or any socket it opened, whichever is last: a join's socket outlives the
/// connector `join` made by default.
public final class URLSessionRelayConnector: RelayConnector {
	private let session: RelaySession

	public init() {
		session = RelaySession()
	}

	public func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
		guard RelayEndpoint.isAllowed(url) else { throw RelaySocketClosed() }
		var request = URLRequest(url: url)
		if let pairing { request.setValue(pairing.text, forHTTPHeaderField: "Pi2-Pairing") }
		let task = session.session.webSocketTask(with: request)
		// Room for the largest message either way; the client checks each against the protocol's own limits.
		task.maximumMessageSize = RelayLimits.maxBinary + 1024
		task.resume()
		return URLSessionRelaySocket(task, session: session)
	}
}

/// The session behind a connector and its sockets, cancelled once none of them holds it.
final class RelaySession: Sendable {
	let session: URLSession

	init() {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieAcceptPolicy = .never
		configuration.httpShouldSetCookies = false
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = 20
		configuration.httpAdditionalHeaders = ["User-Agent": RelaySession.userAgent, "Accept-Language": "*"]
		session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
	}

	static let userAgent = "pi2-relay-client"

	deinit { session.invalidateAndCancel() }
}

/// Answers every redirect with none: the 3xx is the connection's answer.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
		nil
	}
}

/// Where a relay may be: `wss://` to any host, or `ws://` to this computer's own loopback address, for a relay run here
/// in tests (iphone.md 10), as the pairing payload's `u` (remotekit.md). Nothing else, so that no setting can point
/// the client at a relay in clear.
public enum RelayEndpoint {
	public static func isAllowed(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
		guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
		switch scheme {
		case "wss": return true
		case "ws": return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
		default: return false
		}
	}
}

final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
	// URLSessionWebSocketTask is safe to use from any thread; the session is held only to keep it alive.
	private let task: URLSessionWebSocketTask
	private let session: RelaySession

	init(_ task: URLSessionWebSocketTask, session: RelaySession) {
		self.task = task
		self.session = session
	}

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
