import CryptoKit
import Dispatch
import Foundation
import RemoteKit
import pi2_remote

/// pi² Remote's part of a push (#689, docs/iphone.md 7.1, docs/pi2-remote.md "Pushes"), in this process, with a stand-in
/// for the relay: the engine's event read strictly; each push sealed for its device and opened again as the phone opens
/// it; the collapse id an HMAC keyed per pairing and per device; a Live Activity's numbers checked again; a device not on
/// the list, or revoked while a push waited, never sent; no queue of its own; the relay's refusals passed on as they
/// are; and nothing of a push's text in the log. The security reader's list of what the sealing must not get wrong, on
/// issue #689, point by point.
enum Pushes {
	/// A stand-in for the relay: records what it is asked to send, in order, and answers as it is told (sent unless a
	/// word is given), optionally holding each push until released.
	final class StandInRelay: PushRelay, @unchecked Sendable {
		private let lock = NSLock()
		private var sentPushes: [RelayPush] = []
		private var words: [String?] = []
		private var gate: DispatchSemaphore?

		var pushes: [RelayPush] { lock.withLock { sentPushes } }

		func answer(_ words: [String?]) { lock.withLock { self.words = words } }

		func hold() { lock.withLock { gate = DispatchSemaphore(value: 0) } }

		func release(_ count: Int) {
			let gate = lock.withLock { self.gate }
			for _ in 0 ..< count { gate?.signal() }
		}

		func send(_ push: RelayPush) async -> PushOutcome {
			let gate = lock.withLock { self.gate }
			if let gate { await withCheckedContinuation { done in DispatchQueue.global().async { gate.wait(); done.resume() } } }
			return lock.withLock {
				sentPushes.append(push)
				let word = words.isEmpty ? nil : words.removeFirst()
				return word.map(PushOutcome.refused) ?? .sent
			}
		}
	}

	/// pi² Remote's hand-over, on a queue of its own, with what it told the engine.
	final class Rig: @unchecked Sendable {
		let queue = DispatchQueue(label: "pushes-check")
		let keys: MacKeys
		let pairing = PairingID.random()
		let phone = PhoneKeys()
		let device: ListedDevice
		let handOver: PushHandOver
		let relay = StandInRelay()
		private let lock = NSLock()
		private var told: [(String, String)] = []

		var answers: [(String, String)] { lock.withLock { told } }

		init(keys: MacKeys) {
			self.keys = keys
			device = ListedDevice(json: phone.paired(id: DeviceID.random()))!
			var record: (String, String) -> Void = { _, _ in }
			handOver = PushHandOver(queue: queue, keys: keys) { id, why in record(id, why) }
			record = { [unowned self] id, why in lock.withLock { told.append((id, why)) } }
			handOver.relay = relay
		}

		/// Hands the engine's event over, as pi² Remote's queue does, and waits for every answer.
		func take(_ text: String, devices: [ListedDevice]? = nil, settle: Bool = true) {
			let event = try! JSON.parse(text)
			queue.sync { handOver.take(event, pairing: pairing, devices: devices ?? [device]) }
			if settle { self.settle() }
		}

		func settle() {
			let done = DispatchSemaphore(value: 0)
			Task { [handOver] in
				await handOver.settled()
				done.signal()
			}
			done.wait()
			queue.sync {}
		}

		/// Opens a sealed push as the phone's extension does (RemoteKit's `PushSealing.open`, which the extension calls).
		func open(_ sealed: Data, device: ListedDevice? = nil, record: P256.KeyAgreement.PrivateKey? = nil) -> PushSealing.Opened? {
			try? PushSealing.open(
				sealed, pairing: pairing, device: (device ?? self.device).id, recordKey: record ?? phone.record, macRecordKey: keys.record.publicKey,
				identityKey: keys.identity.publicKey)
		}
	}

	static let approval = #"{"v":1,"type":"need","category":"pi2.approval","title":"Forge needs approval","subtitle":"Demo project","body":"bash: npm test","projectId":"project-demo","need":"n12","conversationId":9,"whole":true,"at":1795392000000}"#

	static func alert(_ id: String, device: DeviceID, collapse: String = "need:n12", body: String = approval) -> String {
		#"{"event":"remote","kind":"push","push":{"id":"\#(id)","device":"\#(device.text)","kind":"alert","collapse":"\#(collapse)","body":\#(body)}}"#
	}

	static func gone(_ id: String, device: DeviceID) -> String {
		#"{"event":"remote","kind":"push","push":{"id":"\#(id)","device":"\#(device.text)","kind":"background","body":{"v":1,"type":"gone","needs":["n12","n13"],"at":1795392000000}}}"#
	}

	static func activity(_ id: String, device: DeviceID, activity: String = "AAECAwQFBgcICQoLDA0ODw", state: String = #"{"working":3,"needs":1,"finished":2,"at":1795392000000}"#) -> String {
		#"{"event":"remote","kind":"push","push":{"id":"\#(id)","device":"\#(device.text)","kind":"activity","activity":"\#(activity)","event":"update","state":\#(state)}}"#
	}

	static func run(home: URL) {
		let folder = home.appendingPathComponent("pushes", isDirectory: true)
		try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		Log.shared.open(folder: folder)
		let keys = try! KeyFiles(folder: folder).macKeys()
		reading()
		sealing(keys: keys)
		collapse(keys: keys)
		activities(keys: keys)
		devices(keys: keys)
		noQueue(keys: keys)
		refusals(keys: keys)
		let log = (try? String(contentsOf: folder.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
		Check.expect(!log.isEmpty && !["Forge", "npm test", "Demo project", "need:n12", "project-demo"].contains(where: log.contains),
		             "the log names pushes by the engine's id and says nothing of their body, title, subtitle or collapse (the reader's list, 1)", log)
	}

	/// The helper as a process, with this check its engine, just after it revoked `revoked` and kept `remaining`: a push
	/// for the device that remains is answered `push-later`, as no relay is connected (a development build has none
	/// yet); one for the revoked device, which comes after its revocation on the same connection, is dropped; one the
	/// engine did not write as 7.1 says is refused `malformed`.
	static func flow(engine: FakeEngine, remaining: DeviceID, revoked: DeviceID) {
		Check.section("pushes in pi² Remote as a process: no relay yet, a revoked device, a malformed push (#689)")
		func send(_ text: String) {
			let value = try! JSON.parse(text)
			engine.event("push", [("push", value["push"]!)])
		}
		send(alert("p1", device: revoked))
		send(alert("p2", device: remaining))
		if let refused = engine.request("remote.pushRefused") {
			engine.answer(refused.id)
			Check.expect(refused.params == (try! JSON.parse(#"{"id":"p2","why":"push-later"}"#)), "with no relay connected, a push is answered push-later at once, and only the remaining device's", JSON.text(refused.params))
		} else {
			Check.expect(false, "a push with no relay connected is answered")
		}
		send(activity("p3", device: remaining, state: #"{"working":1,"needs":1,"finished":1,"at":1795392000000,"name":"Demo"}"#))
		if let refused = engine.request("remote.pushRefused") {
			engine.answer(refused.id)
			Check.expect(refused.params == (try! JSON.parse(#"{"id":"p3","why":"malformed"}"#)), "a Live Activity push with more than its four numbers is refused malformed", JSON.text(refused.params))
		} else {
			Check.expect(false, "a malformed push is answered")
		}
		Check.expect(engine.quiet(for: 0.5), "and nothing more is said")
	}

	static func reading() {
		Check.section("the engine's push event, read strictly (7.1)")
		let device = DeviceID.random()
		Check.expect(PushHandOver.read(try! JSON.parse(alert("p1", device: device)))?.what == .sealed(.alert, collapse: "need:n12", body: try! JSON.parse(approval)), "an alert is read with its collapse and body")
		Check.expect(PushHandOver.read(try! JSON.parse(gone("p2", device: device))) != nil, "a background push is read")
		if case let .activity(id, event, numbers)? = PushHandOver.read(try! JSON.parse(activity("p3", device: device)))?.what {
			Check.expect(id.text == "AAECAwQFBgcICQoLDA0ODw" && event == .update && numbers == ActivityNumbers(working: 3, needs: 1, finished: 2, at: 1_795_392_000_000), "a Live Activity push is read with its four numbers")
		} else {
			Check.expect(false, "a Live Activity push is read")
		}
		let malformed: [(String, String)] = [
			(alert("p1", device: device).replacingOccurrences(of: #""push":{"#, with: #""push":{"extra":1,"#), "a member 7.1 does not give"),
			(alert("p1", device: device).replacingOccurrences(of: #","collapse":"need:n12""#, with: ""), "an alert with no collapse"),
			(alert("p1", device: device, collapse: ""), "an empty collapse"),
			(alert("p1", device: device, collapse: "need:\\n12"), "a collapse with a control character"),
			(alert("p01", device: device), "an id that is not p and a number"),
			(alert("x1", device: device), "an id that is not the engine's"),
			(alert("p1", device: device).replacingOccurrences(of: device.text, with: "dev_short"), "a device that is not a device's id"),
			(alert("p1", device: device, body: #"{"v":2,"type":"need"}"#), "a body of another version"),
			(alert("p1", device: device, body: #"{"v":1,"type":"gone","needs":[],"at":1}"#), "an alert carrying a background push's body"),
			(alert("p1", device: device, body: #""text""#), "a body that is not an object"),
			(gone("p2", device: device).replacingOccurrences(of: #""kind":"background","#, with: #""kind":"background","collapse":"need:n12","#), "a background push with a collapse"),
			(gone("p2", device: device).replacingOccurrences(of: #""type":"gone""#, with: #""type":"need""#), "a background push carrying an alert's body"),
			(activity("p3", device: device, state: #"{"working":3,"needs":1,"finished":2}"#), "three numbers"),
			(activity("p3", device: device, state: #"{"working":3,"needs":1,"finished":2,"at":1795392000000,"project":"Demo"}"#), "a fifth member beside the numbers"),
			(activity("p3", device: device, state: #"{"working":100000,"needs":1,"finished":2,"at":1795392000000}"#), "a count past 99,999"),
			(activity("p3", device: device, state: #"{"working":-1,"needs":1,"finished":2,"at":1795392000000}"#), "a negative count"),
			(activity("p3", device: device, state: #"{"working":1.5,"needs":1,"finished":2,"at":1795392000000}"#), "a count that is not whole"),
			(activity("p3", device: device, state: #"{"working":"3","needs":1,"finished":2,"at":1795392000000}"#), "a count written as text"),
			(activity("p3", device: device, state: #"{"working":3,"needs":1,"finished":2,"at":0}"#), "a time that is not one"),
			(activity("p3", device: device, activity: "AAECAwQFBgcICQoLDA0O"), "an activity id of 15 bytes"),
			(activity("p3", device: device).replacingOccurrences(of: #""event":"update""#, with: #""event":"start""#), "an event other than update and end"),
			(activity("p3", device: device).replacingOccurrences(of: #""kind":"activity""#, with: #""kind":"activity","collapse":"x""#), "a Live Activity push with more than its members"),
		]
		for (text, what) in malformed { Check.expect(PushHandOver.read(try! JSON.parse(text)) == nil, "refused: \(what)") }
	}

	static func sealing(keys: MacKeys) {
		Check.section("each push sealed for its device, as the phone opens it (7, 7.1; the reader's list, 1 and 6)")
		let rig = Rig(keys: keys)
		rig.take(alert("p1", device: rig.device.id))
		rig.take(gone("p2", device: rig.device.id))
		guard rig.relay.pushes.count == 2, case let .sealed(_, kind, sealed, collapse) = rig.relay.pushes[0], case let .sealed(_, goneKind, goneSealed, goneCollapse) = rig.relay.pushes[1] else {
			return Check.expect(false, "both pushes reach the relay sealed", "\(rig.relay.pushes)")
		}
		Check.expect(kind == .alert && goneKind == .background, "as an alert and a background push")
		Check.expect(sealed.count == 696 && goneSealed.count == 696 && sealed.first == 0x04, "each padded to 696 bytes, a sealed item's first byte first, as the relay takes it")
		Check.expect(collapse?.count == 32 && goneCollapse == nil, "an alert's collapse id is 32 bytes, and a background push has none")
		let opened = rig.open(sealed)
		Check.expect(opened?.kind == .alert && opened.map { JSON.text($0.body) } == approval, "opened as the phone opens it: an alert, its body byte for byte as the engine wrote it")
		Check.expect(rig.open(goneSealed)?.kind == .background, "and the background push as one")
		Check.expect(rig.answers.isEmpty, "a push sent is not answered")
		Check.expect(rig.open(sealed, record: P256.KeyAgreement.PrivateKey()) == nil, "it does not open with another device's record key")
		let other = ListedDevice(json: PhoneKeys().paired(id: DeviceID.random()))!
		Check.expect(rig.open(sealed, device: other) == nil, "nor as another device's, its id being in HPKE's info")
		var cut = sealed
		cut[400] ^= 1
		Check.expect(rig.open(cut) == nil && rig.open(sealed.prefix(680)) == nil, "nor with a byte changed, nor cut")
		let text = String(decoding: sealed, as: UTF8.self) + String(decoding: goneSealed, as: UTF8.self)
		Check.expect(!["Forge", "npm test", "need:n12", "n13"].contains(where: text.contains), "nothing of the body is outside the seal")

		// The body exactly as the engine wrote it: JSON.stringify's text, with what it escapes and what it does not.
		let tricky = #"{"v":1,"type":"need","category":"pi2.question","title":"Scribe asks \"which\"?","body":"C:\\path\nline two ✓ é 🎉 \u001f","whole":false,"at":1}"#
		rig.take(alert("p3", device: rig.device.id, body: tricky))
		if case let .sealed(_, _, bytes, _)? = rig.relay.pushes.last, let body = rig.open(bytes)?.body {
			Check.expect(JSON.text(body) == tricky, "a body with quotes, backslashes, a line break, a control character and other scripts is sealed exactly as written")
		} else {
			Check.expect(false, "a body with quotes and other scripts is sealed")
		}

		// Each size, and refused rather than cut past the largest.
		func sized(_ characters: Int) -> Int? {
			let body = #"{"v":1,"type":"limit","category":"pi2.limit","title":"\#(String(repeating: "é", count: characters))","body":"x","whole":false,"at":1}"#
			let before = rig.relay.pushes.count
			rig.take(alert("p9", device: rig.device.id, body: body))
			guard rig.relay.pushes.count == before + 1, case let .sealed(_, _, bytes, _) = rig.relay.pushes.last! else { return nil }
			Check.expect(rig.open(bytes).map { JSON.text($0.body) } == body, "a body of \(body.utf8.count) bytes opens whole")
			return bytes.count
		}
		Check.expect(sized(10) == 696 && sized(300) == 1_464 && sized(600) == 3_000, "the smallest of 696, 1,464 and 3,000 bytes that holds it")
		// The engine keeps a body to 2,000 bytes: the largest body it writes fits.
		Check.expect(sized(940) == 3_000, "a body of the engine's largest, 2,000 bytes, fits the largest push")
		let tooLarge = #"{"v":1,"type":"limit","category":"pi2.limit","title":"\#(String(repeating: "é", count: 1_600))","body":"x","whole":false,"at":1}"#
		let before = rig.relay.pushes.count
		rig.take(alert("p10", device: rig.device.id, body: tooLarge))
		Check.expect(rig.relay.pushes.count == before && rig.answers.last.map { $0 == ("p10", "too-large") } == true, "a body that does not fit is refused back to the engine (too-large), never cut, and nothing goes to the relay", "\(rig.answers)")
	}

	static func collapse(keys: MacKeys) {
		Check.section("the collapse id: an HMAC keyed per pairing and per device (7.1; the reader's list, 2)")
		let rig = Rig(keys: keys)
		let second = ListedDevice(json: PhoneKeys().paired(id: DeviceID.random()))!
		rig.take(alert("p1", device: rig.device.id), devices: [rig.device, second])
		rig.take(alert("p2", device: rig.device.id), devices: [rig.device, second])
		rig.take(alert("p3", device: second.id), devices: [rig.device, second])
		rig.take(alert("p4", device: rig.device.id, collapse: "need:n13"), devices: [rig.device, second])
		let collapses = rig.relay.pushes.map { push -> Data? in if case let .sealed(_, _, _, collapse) = push { collapse } else { nil } }
		guard collapses.count == 4, let first = collapses[0] else { return Check.expect(false, "four alerts reach the relay") }
		Check.expect(collapses[1] == first, "the same item's second alert to a device has the same collapse id, so it replaces the first")
		Check.expect(collapses[2] != first, "the same item to another device has another")
		Check.expect(collapses[3] != first, "another item has another")
		let plain = Data("need:n12".utf8)
		Check.expect(!first.contains(plain) && Base64URL.encode(first) != Base64URL.encode(plain), "and none is the engine's id")
		let expected = Data(HMAC<SHA256>.authenticationCode(
			for: plain,
			using: try! rig.phone.record.sharedSecretFromKeyAgreement(with: keys.record.publicKey).hkdfDerivedSymmetricKey(
				using: SHA256.self, salt: Data("pi2-collapse-v1".utf8),
				sharedInfo: Data([0]) + Data(rig.pairing.text.utf8) + Data([0]) + Data(rig.device.id.text.utf8), outputByteCount: 32)))
		Check.expect(first == expected, "it is HMAC-SHA256 of the item's id under the key the two record keys agree, the pairing and the device")
		let otherPairing = try! PushSealing.collapse("need:n12", pairing: PairingID.random(), device: rig.device.id, recordKey: rig.phone.record, deviceRecordKey: keys.record.publicKey)
		Check.expect(otherPairing != first, "another pairing gives another")
	}

	static func activities(keys: MacKeys) {
		Check.section("a Live Activity's numbers, passed unsealed and checked again (7; the reader's list, 4)")
		let rig = Rig(keys: keys)
		rig.take(activity("p1", device: rig.device.id))
		guard case let .activity(device, id, event, numbers)? = rig.relay.pushes.first else { return Check.expect(false, "a Live Activity push reaches the relay") }
		Check.expect(device == rig.device.id && id.text == "AAECAwQFBgcICQoLDA0ODw" && event == .update && numbers.json == (try! JSON.parse(#"{"working":3,"needs":1,"finished":2,"at":1795392000000}"#)), "exactly its device, activity, event and four numbers")
		let message = RelayOutgoing.push(rig.relay.pushes[0]).text
		Check.expect(message == #"{"push":{"device":"\#(device.text)","kind":"activity","activity":"AAECAwQFBgcICQoLDA0ODw","event":"update","state":{"working":3,"needs":1,"finished":2,"at":1795392000000}}}"#, "and the relay is sent the five members and the four numbers, nothing else", message)
		rig.take(activity("p2", device: rig.device.id, state: #"{"working":100000,"needs":1,"finished":2,"at":1795392000000}"#))
		Check.expect(rig.relay.pushes.count == 1 && rig.answers.map(\.1) == ["malformed"], "one out of range never reaches the relay (it would close the socket): refused back as malformed")
		Check.expect(ActivityNumbers(working: 0, needs: 99_999, finished: 0, at: 1) != nil && ActivityNumbers(working: 0, needs: 100_000, finished: 0, at: 1) == nil && ActivityNumbers(working: 0, needs: 0, finished: 0, at: 10_000_000_000_000) == nil, "counts from 0 to 99,999, and a time before the year 2286")
		let sealed = Data([0x04]) + Data(count: 695)
		Check.expect((try? RelayOutgoing.push(.sealed(device: device, kind: .alert, sealed: sealed, collapse: Data(count: 32))).validate()) != nil, "the relay client takes a sealed push of a push's size")
		Check.expect((try? RelayOutgoing.push(.sealed(device: device, kind: .alert, sealed: sealed.prefix(695), collapse: Data(count: 32))).validate()) == nil, "and refuses one of another size")
		Check.expect((try? RelayOutgoing.push(.sealed(device: device, kind: .background, sealed: sealed, collapse: Data(count: 32))).validate()) == nil, "a background push with a collapse id")
		Check.expect((try? RelayOutgoing.push(.sealed(device: device, kind: .alert, sealed: sealed, collapse: Data(count: 31))).validate()) == nil, "and a collapse id that is not 32 bytes")
	}

	static func devices(keys: MacKeys) {
		Check.section("only to a device on pi² Remote's own list, and none after its revocation (the reader's list, 3)")
		let rig = Rig(keys: keys)
		rig.take(alert("p1", device: DeviceID.random()))
		Check.expect(rig.relay.pushes.isEmpty && rig.answers.isEmpty, "a push for a device not on the list is dropped: nothing sent, nothing to answer")
		rig.take(alert("p2", device: rig.device.id), devices: [])
		Check.expect(rig.relay.pushes.isEmpty && rig.answers.isEmpty, "a push that comes after the device's revocation finds it gone, and is dropped")
		// Revoked while a push waits on the relay.
		rig.relay.hold()
		rig.take(alert("p3", device: rig.device.id), settle: false)
		rig.take(alert("p4", device: rig.device.id), settle: false)
		rig.queue.sync { rig.handOver.forget(rig.device.id) }
		rig.relay.release(2)
		rig.settle()
		Check.expect(rig.relay.pushes.count <= 1 && rig.answers.isEmpty, "a push still waiting when its device is revoked is dropped, not sent", "\(rig.relay.pushes.count) sent")
	}

	static func noQueue(keys: MacKeys) {
		Check.section("no queue of its own (the reader's list, 3)")
		let rig = Rig(keys: keys)
		rig.handOver.relay = nil
		rig.take(alert("p1", device: rig.device.id))
		Check.expect(rig.answers.map(\.0) == ["p1"] && rig.answers.map(\.1) == ["push-later"], "with no relay to ask, push-later at once")
		rig.handOver.relay = rig.relay
		rig.relay.hold()
		for index in 2 ... 18 { rig.take(alert("p\(index)", device: rig.device.id), settle: false) }
		rig.queue.sync {}
		Check.expect(rig.answers.map(\.0) == ["p1", "p18"] && rig.answers.last?.1 == "push-later", "past \(PushHandOver.maxInFlight) waiting on the relay, push-later at once", "\(rig.answers)")
		rig.relay.release(16)
		rig.settle()
		let order = rig.relay.pushes.compactMap { push -> Data? in if case let .sealed(_, _, sealed, _) = push { sealed } else { nil } }
		Check.expect(order.count == 16, "the sixteen go to the relay once each")
		let opened = order.compactMap { rig.open($0)?.id }
		Check.expect(Set(opened.map(\.text)).count == 16, "each a seal of its own, with an id of its own")
	}

	static func refusals(keys: MacKeys) {
		Check.section("the relay's refusals, passed to the engine as they are (7.1; the reader's list, 5 and 7)")
		let rig = Rig(keys: keys)
		let words = ["no-token", "token-dead", "unknown-device", "push-limit", "push-later", "unavailable", "clock", "a-newer-word"]
		rig.relay.answer(words + ["Not A Word"])
		for (index, _) in words.enumerated() { rig.take(alert("p\(index + 1)", device: rig.device.id)) }
		rig.take(activity("p20", device: rig.device.id))
		Check.expect(rig.answers.map(\.0) == (1 ... words.count).map { "p\($0)" } + ["p20"], "each push refused is named once, by the engine's id", "\(rig.answers)")
		Check.expect(rig.answers.map(\.1) == words + ["push-later"], "with the relay's word as it is, clock among them; anything not a word is push-later", "\(rig.answers)")
		Check.expect(rig.relay.pushes.count == words.count + 1, "and nothing is sent again by pi² Remote")
	}
}
