import Dispatch
import Foundation
import RemoteKit

/// The path a phone's channel runs on (docs/iphone.md 5.1, "one channel, two paths"): a TCP connection on the home or
/// direct path (`TCPLink`), or a device's slot at the relay (`RelayLink`, in `Relay/`). A link carries whole Noise
/// messages and nothing else. What a message holds, and every check made of it (the first message's length and limits,
/// the handshake, the Mac's proof, the claim or the attach, a session's lines, the line limits, the budgets), is
/// `PhoneConnection`'s alone, one code path for both: a link cannot read, refuse or pass on a line.
protocol PhoneLink: AnyObject {
	/// A whole Noise message, in order. The first is given only once `acceptsFirst` took its length.
	var onMessage: (Data) -> Void { get set }
	/// Whether a first message of this length is taken, asked before its bytes are held where the path allows (TCP
	/// says the length first); a length it refuses ends the link.
	var acceptsFirst: (Int) -> Bool { get set }
	/// What came cannot be read as messages, or as a first message this length: the channel ends (`bye`, then closed).
	var onBroken: () -> Void { get set }
	/// The link ended, from either side. Called once, on pi² Remote's queue.
	var onClose: () -> Void { get set }
	func start()
	/// One Noise message to the phone, in order.
	func send(_ message: Data)
	/// Ends the link once what is queued has gone, as far as it can go at once: the channel's `bye` with it.
	func finish()
	/// What waits to be written to the phone, in bytes.
	var pending: Int { get }
	/// How long what waits has waited without a byte going, or zero when nothing waits.
	var stalledFor: Duration { get }
	var isClosed: Bool { get }
	/// Stops handing on the phone's messages until `resumeReading`: TCP then holds the phone back, the relay's link
	/// holds what comes, within a bound.
	func pauseReading()
	func resumeReading()
}

/// A phone's TCP connection on the home or direct path: each Noise message preceded by its length in two bytes
/// (remotekit.md, "Framing"). The first message's length is read and judged before any of its bytes are held, and it
/// must then be exactly that many bytes: the initiator waits for the answer before it sends anything more.
final class TCPLink: PhoneLink {
	private let io: SocketIO
	private var framing = LengthFraming()
	private var firstBytes = Data()
	private var firstDone = false

	var onMessage: (Data) -> Void = { _ in }
	var acceptsFirst: (Int) -> Bool = { _ in false }
	var onBroken: () -> Void = {}
	var onClose: () -> Void = {}

	init(descriptor: Int32, queue: DispatchQueue) {
		io = SocketIO(descriptor: descriptor, queue: queue)
	}

	func start() {
		io.onBytes = { [unowned self] in self.take($0) }
		io.onClose = { [unowned self] in self.onClose() }
		io.start()
	}

	private func take(_ bytes: Data) {
		if !firstDone {
			firstBytes.append(bytes)
			guard firstBytes.count >= 2 else { return }
			let length = Int(firstBytes[firstBytes.startIndex]) << 8 | Int(firstBytes[firstBytes.startIndex + 1])
			guard acceptsFirst(length) else { return onBroken() }
			guard firstBytes.count >= 2 + length else { return }
			guard firstBytes.count == 2 + length else { return onBroken() }
			firstDone = true
			let message = Data(firstBytes[(firstBytes.startIndex + 2)...])
			firstBytes = Data()
			onMessage(message)
			return
		}
		do {
			for message in try framing.push(bytes) {
				onMessage(message)
				if io.isClosed { return }
			}
		} catch {
			onBroken()
		}
	}

	func send(_ message: Data) {
		guard let framed = try? LengthFraming.encode(message) else { return finish() }
		io.send(framed)
	}

	func finish() { io.finish() }
	var pending: Int { io.pending }
	var stalledFor: Duration { io.stalledFor }
	var isClosed: Bool { io.isClosed }
	func pauseReading() { io.pauseReading() }
	func resumeReading() { io.resumeReading() }
}

/// Where a phone's connection came from: a TCP peer on the home or direct path, with the interface it came by when that
/// matters (a peer in the shared address space, D2); or the slot the relay named, whose word it is until the channel's
/// handshake proves the device (remotekit.md, "What a caller must and must not do").
enum PhoneRoute {
	case tcp(IPAddress, arrivedOn: String?)
	case relay(DeviceID)
}
