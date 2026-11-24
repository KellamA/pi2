import CryptoKit
import Dispatch
import Foundation
import RemoteKit

// Pushes (docs/iphone.md 7 and 7.1, #689): the engine chooses what to push and sends pi² Remote one `remote` event of
// kind `push` for each device; pi² Remote seals it for that device and asks the relay to send it; the relay posts it to
// Apple. This is pi² Remote's part, between the engine's event and the relay's client:
//
// - **Read strictly.** `{"event":"remote","kind":"push","push":…}`, exactly the members 7.1 gives each kind. One that is
//   not is answered `malformed` (if its id can be read) and goes no further.
// - **Only to a device on pi² Remote's own list**, as it stands when the push arrives: the engine's `revoke` comes on the
//   same connection, in order, and drops the device first, so a push that arrives after it finds no device and is
//   dropped. One handed over and still waiting behind others is dropped too (`forget`); the one already being asked of
//   the relay, at most one, which may be waiting in the relay client's queue of requests, may still go after it.
// - **Sealed** (`alert`, `background`) with RemoteKit's `PushSealing`: the engine's body as it wrote it, signed by the
//   identity key, sealed to the device's record key with the Mac's, padded to 696, 1,464 or 3,000 bytes (an alert to
//   1,464 at least). A body that
//   does not fit the largest is refused back to the engine (`too-large`), never cut. Nothing of the body, its title or
//   its `collapse` is ever logged.
// - **The collapse id** (alerts alone) is HMAC-SHA256 of the engine's `collapse`, keyed per pairing and per device
//   (`PushSealing.collapse`): the relay never sees the engine's id, nor anything that names a project or conversation.
// - **A Live Activity's numbers** pass unsealed, as the system reads them, held again to exactly their four members, each
//   in range, and the activity's id to its shape (`ActivityNumbers`, `RelayOutgoing.validate`): one that is not would
//   close the relay's socket as `malformed`.
// - **No queue of its own.** While there is no relay to ask (not connected, or none yet), a push is answered
//   `push-later` at once and the engine asks again when it sees fit; so is one past `maxInFlight` waiting on the relay.
//   Pushes go to the relay in the order they came, each once.
// - **The relay's refusal, as it is.** For a push the relay refused, `remote.pushRefused { id, why }`, once, with the
//   relay's word (`no-token`, `token-dead`, `unknown-device`, `push-limit`, `push-later`, `unavailable`, `clock`, or a
//   word this build does not know); the engine holds back what each says (engine/src/pushes.ts). Nothing is sent again
//   here. A push sent is not answered.

/// How the relay answered a push: sent, or refused with a word.
package enum PushOutcome: Equatable, Sendable {
	case sent
	case refused(String)
}

/// The seam to the relay: send this push for its device now, or say why not. Answered `push-later` when the relay is not
/// connected; never held to be sent later.
package protocol PushRelay: Sendable {
	func send(_ push: RelayPush) async -> PushOutcome
}

/// RemoteKit's relay client as the seam: its answer as it is, and `push-later` when the push could not be asked (not
/// connected, the socket dropped, the client stopped or busy), since the engine asks again. A client that can never
/// send a push, one of the phone's (`wrongEnd`) or one stopped, is a mis-wiring the engine cannot see: it is said in the
/// log once each time the client comes to it, not once a push.
package struct RelayClientPushes: PushRelay {
	let client: RelayClient
	private let said = SaidOnce()

	package init(client: RelayClient) { self.client = client }

	package func send(_ push: RelayPush) async -> PushOutcome {
		do {
			let answer = try await client.push(push)
			said.clear()
			switch answer {
			case .sent: return .sent
			case let .refused(why): return .refused(why.word)
			}
		} catch RelayClientError.invalid {
			// The client refused its form before sending it: the relay would have closed the socket.
			return .refused(PushHandOver.malformed)
		} catch RelayClientError.wrongEnd {
			said.once("wrong-end", "pushes are handed to a relay client that is not the Mac's: none can be sent, and each is answered push-later")
			return .refused(PushHandOver.later)
		} catch RelayClientError.stopped {
			said.once("stopped", "pushes are handed to a relay client that has stopped: none can be sent, and each is answered push-later")
			return .refused(PushHandOver.later)
		} catch {
			return .refused(PushHandOver.later)
		}
	}
}

/// Says a state once when it begins, and again only after another answer ended it.
private final class SaidOnce: @unchecked Sendable {
	private let lock = NSLock()
	private var last: String?

	func once(_ state: String, _ text: String) {
		let new = lock.withLock {
			defer { last = state }
			return last != state
		}
		if new { log(text) }
	}

	func clear() { lock.withLock { last = nil } }
}

/// pi² Remote's part of a push: the engine's event read, the device checked, sealed or checked again, handed to the relay,
/// and a refusal told to the engine. Its methods are called on pi² Remote's queue, as the engine's events are.
package final class PushHandOver: @unchecked Sendable {
	/// pi² Remote's own words for a push it did not hand to the relay. The engine knows `push-later`; the others it takes
	/// as `push-later` too (engine/src/pushes.ts, "Any other `why`").
	package static let later = "push-later"
	package static let malformed = "malformed"
	package static let tooLarge = "too-large"
	/// The most pushes waiting on the relay at once, as the relay itself keeps at most 16 of a pairing's waiting: past
	/// them, `push-later`, so that nothing piles up here.
	package static let maxInFlight = 16

	private let queue: DispatchQueue
	private let keys: MacKeys
	private let answer: (_ id: String, _ why: String) -> Void
	/// The relay's client, once there is one connected to send through (#678); none, and every push is `push-later`.
	package var relay: (any PushRelay)?
	private var inFlight = 0
	private var tail: Task<Void, Never>?
	/// Devices revoked since a push for them was handed over: dropped rather than sent.
	private let lock = NSLock()
	private var forgotten = Set<DeviceID>()

	/// `answer` tells the engine of a push refused (`remote.pushRefused`); it is called on `queue`.
	package init(queue: DispatchQueue, keys: MacKeys, answer: @escaping (_ id: String, _ why: String) -> Void) {
		self.queue = queue
		self.keys = keys
		self.answer = answer
	}

	/// A push the engine read as 7.1 gives it.
	package struct Asked: Equatable, Sendable {
		package enum What: Equatable, Sendable {
			case sealed(PushSealing.Kind, collapse: String?, body: JSONValue)
			case activity(ItemID, ActivityEvent, ActivityNumbers)
		}

		package let id: String
		package let device: DeviceID
		package let what: What
	}

	/// The engine's push event, read strictly: nil for anything that is not exactly one of 7.1's three shapes.
	package static func read(_ event: JSONValue) -> Asked? {
		guard let keys = event.keys, keys.count == 3, Set(keys) == ["event", "kind", "push"], event["event"]?.stringValue == "remote",
		      event["kind"]?.stringValue == "push", let push = event["push"], let fields = push.keys,
		      let id = pushID(push), let device = push["device"]?.stringValue.flatMap(DeviceID.init), let kind = push["kind"]?.stringValue
		else { return nil }
		switch kind {
		case "alert":
			guard fields.count == 5, Set(fields) == ["id", "device", "kind", "collapse", "body"], let collapse = push["collapse"]?.stringValue,
			      isCollapseSource(collapse), let body = push["body"], bodyIs(body, ["need", "limit", "answer"])
			else { return nil }
			return Asked(id: id, device: device, what: .sealed(.alert, collapse: collapse, body: body))
		case "background":
			guard fields.count == 4, Set(fields) == ["id", "device", "kind", "body"], let body = push["body"], bodyIs(body, ["gone"]) else { return nil }
			return Asked(id: id, device: device, what: .sealed(.background, collapse: nil, body: body))
		case "activity":
			guard fields.count == 6, Set(fields) == ["id", "device", "kind", "activity", "event", "state"],
			      let activity = push["activity"]?.stringValue.flatMap(ItemID.init), let event = push["event"]?.stringValue.flatMap(ActivityEvent.init),
			      let numbers = push["state"].flatMap(ActivityNumbers.init(json:))
			else { return nil }
			return Asked(id: id, device: device, what: .activity(activity, event, numbers))
		default:
			return nil
		}
	}

	/// The engine's own id for a push: `p` and a number (pushes.ts, `#send`).
	package static func pushID(_ push: JSONValue) -> String? {
		guard let id = push["id"]?.stringValue else { return nil }
		let digits = id.utf8.dropFirst()
		guard id.utf8.first == UInt8(ascii: "p"), (1 ... 15).contains(digits.count), digits.first != UInt8(ascii: "0"),
		      digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
		else { return nil }
		return id
	}

	/// The engine's id for what an alert is about (`need:n12`): a short text with no control character.
	static func isCollapseSource(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= PushSealing.maxCollapseSource && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
	}

	/// A body of version 1 and one of these types: an alert's for an alert, `gone` for a background push.
	static func bodyIs(_ body: JSONValue, _ types: [String]) -> Bool {
		guard case .object = body, body["v"]?.integerValue == 1, let type = body["type"]?.stringValue else { return false }
		return types.contains(type)
	}

	/// The engine's `push` event, as it came, with the pairing and pi² Remote's own list as they stand now.
	package func take(_ event: JSONValue, pairing: PairingID?, devices: [ListedDevice]) {
		guard let asked = Self.read(event) else {
			if let id = event["push"].flatMap(Self.pushID) {
				log("push \(id): not a push as the engine writes one; refused, not sent")
				answer(id, Self.malformed)
			} else {
				log("a push event pi² Remote cannot read; left")
			}
			return
		}
		guard let device = devices.first(where: { $0.id == asked.device }) else {
			// Revoked, or never paired through pi² Remote: never sent, and nothing to tell the engine (7.1: nothing is
			// pushed to a device revoked).
			log("push \(asked.id): for a device not on pi² Remote's own list; dropped")
			return
		}
		guard let relay, let pairing else { return answer(asked.id, Self.later) }
		guard inFlight < Self.maxInFlight else {
			Seldom.shared.say("pushes-waiting", "\(Self.maxInFlight) pushes wait on the relay already: the next are answered push-later")
			return answer(asked.id, Self.later)
		}
		let push: RelayPush
		switch asked.what {
		case let .sealed(kind, subject, body):
			do {
				let sealed = try keys.record.sealPush(body, kind: kind, pairing: pairing, device: device, identity: keys.identity)
				let collapse = try subject.map { try keys.record.collapse($0, pairing: pairing, device: device) }
				push = .sealed(device: device.id, kind: kind, sealed: sealed, collapse: collapse)
			} catch let error as RemoteKitError where error == PushSealing.tooLarge {
				log("push \(asked.id): too large to seal in the largest push; refused, not cut")
				return answer(asked.id, Self.tooLarge)
			} catch {
				log("push \(asked.id): could not be sealed (\(error)); push-later")
				return answer(asked.id, Self.later)
			}
		case let .activity(activity, event, numbers):
			push = .activity(device: device.id, activity: activity, event: event, numbers: numbers)
		}
		inFlight += 1
		let previous = tail
		let id = asked.id
		tail = Task { [self] in
			// In the order they came, one after another, as the relay answers them.
			await previous?.value
			let gone = lock.withLock { forgotten.contains(push.device) }
			let outcome: PushOutcome? = gone ? nil : await relay.send(push)
			queue.async { [self] in
				inFlight -= 1
				guard let outcome else { return log("push \(id): its device was revoked before it went; dropped") }
				settle(id, device: push.device, outcome)
			}
		}
	}

	/// The device was revoked: a push for it still waiting behind others is dropped; the one already being asked of the
	/// relay, at most one, may still go.
	package func forget(_ device: DeviceID) {
		lock.withLock { _ = forgotten.insert(device) }
	}

	/// Waits until every push handed to the relay so far has had its answer (for the checks).
	package func settled() async {
		await tail?.value
	}

	private func settle(_ id: String, device: DeviceID, _ outcome: PushOutcome) {
		guard case let .refused(why) = outcome else { return }
		// A word, never text: the relay's words are lower-case letters and hyphens (RelayWhy); anything else is passed as
		// push-later, which the engine takes for any word it does not know.
		let word = RelayWhy(word: why)?.word ?? Self.later
		log("push \(id) to \(device): refused, \(word)")
		if word == "clock" {
			Seldom.shared.say("clock", "the relay refuses Live Activity numbers dated far from its own clock (clock): this Mac's clock may be wrong; the engine is told, and sends fresh numbers when it asks again")
		}
		answer(id, word)
	}
}

extension RecordKey {
	func sealPush(_ body: JSONValue, kind: PushSealing.Kind, pairing: PairingID, device: ListedDevice, identity: SigningKey) throws -> Data {
		switch self {
		case let .software(key):
			try PushSealing.seal(body, kind: kind, pairing: pairing, device: device.id, deviceRecordKey: device.recordKey, recordKey: key, identity: identity)
		case let .enclave(key):
			try PushSealing.seal(body, kind: kind, pairing: pairing, device: device.id, deviceRecordKey: device.recordKey, recordKey: key, identity: identity)
		}
	}

	func collapse(_ subject: String, pairing: PairingID, device: ListedDevice) throws -> Data {
		switch self {
		case let .software(key):
			try PushSealing.collapse(subject, pairing: pairing, device: device.id, recordKey: key, deviceRecordKey: device.recordKey)
		case let .enclave(key):
			try PushSealing.collapse(subject, pairing: pairing, device: device.id, recordKey: key, deviceRecordKey: device.recordKey)
		}
	}
}
