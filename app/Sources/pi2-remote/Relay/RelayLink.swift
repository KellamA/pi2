import Dispatch
import Foundation
import RemoteKit

/// A phone's connection on the relay path, as `PhoneConnection` sees it (docs/iphone.md 5.1, 5.3): the Noise messages
/// that came under one slot of the relay's, each one binary WebSocket message, and the Mac's to it, which `RelayEnd`
/// sends in order on its one socket. It reads nothing of what it carries: every check is `PhoneConnection`'s, as on
/// TCP. The slot is the relay's word until the channel's handshake proves the device (its prologue names it).
///
/// What a phone sends while phones are paused (the engine's backlog, #675's security read B, M2) is held here, as TCP's
/// buffer holds it on the home path, up to `heldLimit`; past it the channel ends, and its session keeps what a resume
/// needs.
final class RelayLink: PhoneLink, @unchecked Sendable {
	private unowned let relay: RelayEnd
	/// The slot its messages come under, and its own go to: the joined phone's until the Mac adds it under the engine's
	/// id (`moved`), which the relay then carries the same socket under.
	private(set) var slot: DeviceID
	private var firstDone = false
	private var paused = false
	private var held: [Data] = []
	private var heldBytes = 0
	private var lastProgress = ContinuousClock.now
	private(set) var pending = 0
	private(set) var isClosed = false

	/// The most held while paused: what a TCP connection's buffers hold, about.
	static let heldLimit = 4 * 1024 * 1024

	var onMessage: (Data) -> Void = { _ in }
	var acceptsFirst: (Int) -> Bool = { _ in false }
	var onBroken: () -> Void = {}
	var onClose: () -> Void = {}

	init(relay: RelayEnd, slot: DeviceID) {
		self.relay = relay
		self.slot = slot
	}

	func start() {}

	/// A message the relay passed on under this link's slot.
	func received(_ message: Data) {
		guard !isClosed else { return }
		if !firstDone {
			firstDone = true
			guard acceptsFirst(message.count) else { return onBroken() }
			return onMessage(message)
		}
		if paused {
			guard heldBytes + message.count <= Self.heldLimit else {
				log("a phone on the relay sent more than \(Self.heldLimit / 1024 / 1024) MB while phones were held back; its channel is closed")
				return onBroken()
			}
			held.append(message)
			heldBytes += message.count
			return
		}
		onMessage(message)
	}

	func send(_ message: Data) {
		guard !isClosed else { return }
		if pending == 0 { lastProgress = .now }
		pending += message.count
		relay.send(message, from: self)
	}

	/// What `send` queued went to the relay's socket (or was let go with the socket).
	func sent(_ count: Int) {
		pending = max(0, pending - count)
		lastProgress = .now
	}

	var stalledFor: Duration { pending == 0 ? .zero : ContinuousClock.now - lastProgress }

	func pauseReading() { paused = true }

	func resumeReading() {
		guard paused else { return }
		paused = false
		while !paused, !isClosed, !held.isEmpty {
			let next = held.removeFirst()
			heldBytes -= next.count
			onMessage(next)
		}
	}

	/// The Mac ends the channel: what it queued (its `bye` among it) still goes, in order; nothing more does.
	func finish() { close() }

	/// The link is gone: the relay's socket dropped, a new channel came under the same slot, or the channel ended. What
	/// the Mac queued and was not yet handed to the socket still goes in order if the socket lasts, and is let go if not.
	func close() {
		guard !isClosed else { return }
		isClosed = true
		held.removeAll()
		heldBytes = 0
		relay.closed(self)
		let closing = onClose
		onClose = {}
		onMessage = { _ in }
		closing()
	}

	/// The Mac added the joined phone under the engine's id: the same socket at the relay, now under `device`.
	func moved(to device: DeviceID) { slot = device }
}
