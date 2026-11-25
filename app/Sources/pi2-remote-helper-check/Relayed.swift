import CryptoKit
import Darwin
import Foundation
import Network
import RemoteKit
import pi2_remote

// pi² Remote's relay end (#678's second part), against the relay itself on this computer, which
// `scripts/relay-protocol-test --remote` starts for it as it starts one for the protocol test (loopback, the relay's own
// package scripts, nothing deployed): registering, a join window, pairing over the relay, the device list, a phone's
// channel over the relay carried by the same code as on the home path (the same hostile cases, run over it), the
// mailbox both ways, and the state the engine is told.

/// A value set on one thread and read on another.
final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Value
	init(_ value: Value) { self.value = value }
	func get() -> Value { lock.withLock { value } }
	func set(_ new: Value) { lock.withLock { value = new } }
	func update<T>(_ change: (inout Value) -> T) -> T { lock.withLock { change(&value) } }
}

struct TimedOut: Error {}

/// Runs `work` on Swift's own threads and waits for it here, up to `seconds`: the check's flows are one thread.
func blocking<T: Sendable>(within seconds: Double = 60, _ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
	let box = Locked<Result<T, Error>?>(nil)
	let done = DispatchSemaphore(value: 0)
	Task.detached {
		do {
			box.set(.success(try await work()))
		} catch {
			box.set(.failure(error))
		}
		done.signal()
	}
	guard done.wait(timeout: .now() + seconds) == .success, let result = box.get() else { return .failure(TimedOut()) }
	return result
}

/// A phone's socket at the relay, as the check's phone uses it: a join's link while it pairs, or a listed phone's
/// client after. Each Noise message is one WebSocket message.
final class RelayWire: @unchecked Sendable {
	private let state = Locked<(inbox: [Data], ended: String?, ready: Bool, mail: Int)>(([], nil, false, 0))
	private let arrived = DispatchSemaphore(value: 0)
	let link: RelayJoinLink?
	let client: RelayClient?

	init(link: RelayJoinLink) {
		self.link = link
		client = nil
		let events = link.events
		Task.detached { [self] in
			for await event in events {
				switch event {
				case let .data(bytes): self.push(bytes)
				case .mail: self.state.update { $0.mail += 1 }
				case let .ended(why): self.end("\(why)")
				case .macOnline: break
				}
				self.arrived.signal()
			}
		}
	}

	init(client: RelayClient) {
		link = nil
		self.client = client
		let events = client.events
		Task.detached { [self] in
			for await event in events {
				switch event {
				case let .data(_, bytes): self.push(bytes)
				case .deviceReady: self.state.update { $0.ready = true }
				case .mail: self.state.update { $0.mail += 1 }
				case let .stopped(why): self.end("\(why)")
				case .disconnected: self.state.update { $0.ready = false }
				default: break
				}
				self.arrived.signal()
			}
		}
		Task.detached { await client.start() }
	}

	private func push(_ bytes: Data) { state.update { $0.inbox.append(bytes) } }
	private func end(_ why: String) { state.update { $0.ended = why } }

	/// What came on a channel before this one is not this one's.
	func clear() { state.update { $0.inbox = [] } }

	var isClosed: Bool { state.get().ended != nil }
	var endedBecause: String? { state.get().ended }
	var mailNotices: Int { state.get().mail }

	@discardableResult
	func send(_ message: Data) -> Bool {
		let (link, client) = (self.link, self.client)
		let sent = blocking(within: 30) {
			if let link { try await link.send(message) } else if let client { try await client.send(message) }
		}
		if case .success = sent { return true }
		return false
	}

	func next(within seconds: Double) -> Data? {
		let deadline = Date().addingTimeInterval(seconds)
		while true {
			let taken: Data? = state.update { $0.inbox.isEmpty ? nil : $0.inbox.removeFirst() }
			if let taken { return taken }
			if isClosed { return nil }
			guard deadline.timeIntervalSinceNow > 0, arrived.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .success else {
				return state.update { $0.inbox.isEmpty ? nil : $0.inbox.removeFirst() }
			}
		}
	}

	/// Waits for the client's socket to be proved, up to `seconds`.
	func ready(within seconds: Double = 30) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while !state.get().ready {
			guard !isClosed, deadline.timeIntervalSinceNow > 0 else { return false }
			_ = arrived.wait(timeout: .now() + min(0.2, deadline.timeIntervalSinceNow))
		}
		return true
	}

	/// Waits until the socket ends, up to `seconds`; why, as the relay or the client said.
	func ended(within seconds: Double) -> String? {
		let deadline = Date().addingTimeInterval(seconds)
		while !isClosed, deadline.timeIntervalSinceNow > 0 { _ = arrived.wait(timeout: .now() + min(0.2, deadline.timeIntervalSinceNow)) }
		return endedBecause
	}

	func close() {
		let (link, client) = (self.link, self.client)
		_ = blocking(within: 10) {
			await link?.close()
			await client?.stop()
		}
	}
}

enum Relayed {
	static let team = Flows.team
	static let phoneBuild = RelayBuild("7")!

	struct Mac {
		let pairing: PairingID
		let port: UInt16
		let identity: P256.Signing.PublicKey
		let channel: Curve25519.KeyAgreement.PublicKey
		let record: P256.KeyAgreement.PublicKey
		var flows: Flows.Mac { Flows.Mac(pairing: pairing, port: port, identity: identity, channel: channel, record: record) }
	}

	/// A join with the relay's stand-in for App Attest (relay/test/protocol/worker.ts): the client data hash, then the key id.
	static func join(_ relay: URL, pairing: PairingID, secret: Data, keys: PhoneKeys, token: Data? = nil) -> RelayJoinLink? {
		let attestKey = AttestKeyID(bytes: Bytes.random(32))!
		let attest: @Sendable (Data) async throws -> RelayAttestation = { hash in
			RelayAttestation(attestation: hash + Data(base64Encoded: attestKey.text)!, keyId: attestKey)
		}
		let deviceKey = keys.device.publicKey
		let token = token ?? PairingSecrets.joinToken(secret: secret, pairing: pairing)
		// The Mac's openJoin reaches the relay a moment after the engine's: a join refused as no window is tried again.
		for _ in 0 ..< 20 {
			switch blocking(within: 30, { try await RelayClient.join(relay: relay, pairing: pairing, build: phoneBuild, deviceKey: deviceKey, token: token, attest: attest) }) {
			case let .success(link): return link
			case .failure(RelayClientError.refused(.windowClosed)): usleep(250_000)
			case .failure: return nil
			}
		}
		return nil
	}

	/// A listed phone's socket at the relay, proved with its device key.
	static func connect(_ relay: URL, pairing: PairingID, device: DeviceID, keys: PhoneKeys) -> RelayWire? {
		guard let client = try? RelayClient(relay: relay, role: .device(pairing, device), build: phoneBuild, signer: RelaySigner(keys.device)) else { return nil }
		let wire = RelayWire(client: client)
		return wire.ready() ? wire : nil
	}

	static func openJoin(_ engine: FakeEngine, pairing: PairingID, secret: Data) -> Int64 {
		let expires = Int64(Date().timeIntervalSince1970) + 300
		let hash = PairingSecrets.joinTokenHash(PairingSecrets.joinToken(secret: secret, pairing: pairing))
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string(Base64URL.encode(hash))), ("expires", .integer(expires * 1000))])
		return expires
	}

	static func payload(_ mac: Mac, relay: URL, secret: Data, expires: Int64) -> PairingPayload {
		try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: secret,
			relay: relay.absoluteString, addresses: [], expires: expires)
	}

	static func kept(_ home: URL) -> KeptDevices? {
		FileManager.default.contents(atPath: home.appendingPathComponent("remote-devices.json").path).flatMap { try? KeptDevices(data: $0) }
	}

	/// `home` is the data folder pi² Remote finds in this check's environment (its engine's, as it reads it).
	static func run(helper: URL, home: URL, relay: URL) {
		Check.section("the relay path (#678): registering at a relay on this computer")
		Flows.home = home
		let (child, engine) = Starts.start(helper: helper, home: home)
		defer { child.stop() }
		engine.answersStates = true
		engine.event("start", [
			("relay", .string(relay.absoluteString)), ("switches", Flows.switches), ("pairing", .null), ("devices", .array([])), ("minimumBuild", .string("1")),
		])
		guard let hello = engine.request("remote.hello") else { Check.stop("pi² Remote said hello") }
		engine.answer(hello.id)
		let keys = hello.params["macKeys"]
		guard let identity = keys?["identity"]?.stringValue.flatMap(PublicKeys.signingKey), let channel = keys?["channel"]?.stringValue.flatMap(PublicKeys.channelKey),
		      let record = keys?["record"]?.stringValue.flatMap(PublicKeys.agreementKey),
		      case let .array(addresses)? = hello.params["addresses"], let address = addresses.first?.stringValue, let port = UInt16(address.split(separator: ":").last ?? "")
		else { Check.stop("remote.hello gave the Mac's keys and an address") }
		let before = engine.relayState("unavailable")
		Check.expect(before?["why"]?.stringValue?.contains("no pairing yet") == true && before?["available"]?.boolValue == false, "before a pairing, the engine is told the relay path waits for one", before.map(JSON.text) ?? "nothing")

		engine.event("register")
		guard let registered = engine.state(where: { $0["pairing"] != nil }), let pairing = registered["pairing"]?.stringValue.flatMap(PairingID.init) else {
			Check.stop("pi² Remote registered a pairing at the relay")
		}
		Check.expect(true, "register: the relay gives a pairing's id, which the engine is told (remote.state)")
		let registration = kept(home)?.registration
		Check.expect(registration == RelayRegistration(pairing: pairing, relay: relay.absoluteString), "the pairing is kept with the relay's address it was registered at, with the list of devices")
		let ready = engine.relayState("ready")
		Check.expect(ready?["available"]?.boolValue == true, "and pi² Remote connects to the relay as the pairing's Mac: the engine is told it is ready", JSON.text(.array(engine.states)))
		let mac = Mac(pairing: pairing, port: port, identity: identity, channel: channel, record: record)

		Check.section("pairing over the relay (3.3): the join window, a wrong try, the claim, addDevice before closeJoin")
		let secret = Bytes.random(32)
		let expires = openJoin(engine, pairing: pairing, secret: secret)
		let payload = payload(mac, relay: relay, secret: secret, expires: expires)
		let keys1 = PhoneKeys()
		// A phone holding a wrong secret joins with the right token (it read another code's token) and fails at psk2.
		if let wrongLink = join(relay, pairing: pairing, secret: secret, keys: PhoneKeys()) {
			let wire = RelayWire(link: wrongLink)
			let phone = Phone(relay: wire)
			let wrong = try! PairingPayload(
				pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: Bytes.random(32),
				relay: relay.absoluteString, addresses: [], expires: expires)
			Check.expect(phone.pair(payload: wrong, keys: PhoneKeys(), team: team) == nil, "a phone with the wrong secret, over the relay, cannot read the Mac's answer")
			Check.expect(engine.request("remote.pairWrong", within: 20) != nil, "and pi² Remote counts a wrong try when it sends nothing more (remote.pairWrong)")
			wire.close()
		} else {
			Check.expect(false, "a phone joins the relay's window")
		}
		guard let link = join(relay, pairing: pairing, secret: secret, keys: keys1) else { Check.stop("a phone joined the relay's window with the token's hash the engine gave") }
		Check.expect(true, "the relay's window was opened with the engine's token hash: a phone joins it")
		let joined = RelayWire(link: link)
		let phone = Phone(relay: joined)
		guard let claimed = phone.pair(payload: payload, keys: keys1, team: team) else { Check.stop("the pairing handshake over the relay") }
		guard let claim = engine.request("remote.pairClaim") else { Check.stop("the claim reached the engine") }
		Check.expect(claim.params["path"]?.stringValue == "relay" && claim.params["challenge"]?.stringValue == Base64URL.encode(claimed.challenge) && claim.params["binding"]?.stringValue == Base64URL.encode(claimed.binding),
		             "remote.pairClaim over the relay: the path relay, the exact challenge, this channel's binding", JSON.text(claim.params))
		engine.answer(claim.id, .object([("claim", .string("claim_r1"))]))
		let device = DeviceID.random()
		engine.event("closeJoin")
		Check.expect(phone.message(within: 1) == nil, "closeJoin leaves the claimed phone's channel open")
		engine.event("paired", [
			("claim", .string("claim_r1")), ("device", keys1.paired(id: device)),
			("paired", .object([("device", .string(device.text)), ("pairing", .string(pairing.text)), ("name", .string("Check Mac")), ("addresses", .array([.string(address)]))])),
		])
		if let line = phone.line(), case let .paired(answer)? = try? ControlLine.parse(line, from: .mac) {
			Check.expect(answer.device == device && answer.homeKey == kept(home)?.homeKey, "the phone is told it is paired over the relay, with its device id and the home key")
		} else {
			Check.expect(false, "the phone is told it is paired over the relay")
		}
		Check.expect(phone.event() == .bye, "then the pairing channel ends")
		joined.close()
		guard let wire = connect(relay, pairing: pairing, device: device, keys: keys1) else {
			Check.stop("the paired phone connects to the relay as a listed device: pi² Remote added it with the engine's keys")
		}
		Check.expect(true, "the relay lists the phone under the engine's id: pi² Remote's addDevice, with the device key of the engine's claim")
		Check.expect(kept(home)?.devices.map(\.id) == [device], "and it is on pi² Remote's own list")

		Check.section("a session over the relay: the same channel, attach and lines as at home (3.4, 5.6, 5.8)")
		let fmac = mac.flows
		guard let (first, attached) = Flows.attach(engine, mac: fmac, device: device, keys: keys1, session: "r_one", path: "relay", make: { Phone(relay: wire) }) else {
			Check.stop("the phone attached over the relay")
		}
		Check.expect(!attached.resume, "the phone is attached over the relay, in a new session")
		for n in 1 ... 3 { engine.toSession("r_one", "{\"event\":\"check\",\"n\":\(n)}") }
		let got = (1 ... 3).compactMap { _ in first.line() }
		Check.expect(got == (1 ... 3).map { Data("{\"event\":\"check\",\"n\":\($0)}".utf8) }, "the engine's lines reach the phone over the relay as they were written")
		first.sendLine(Data(#"{"id":"r1","method":"engine.info","params":{}}"#.utf8))
		Check.expect(engine.sessionLine()?.1 == Data(#"{"session":"r_one","message":{"id":"r1","method":"engine.info","params":{}}}"#.utf8), "the phone's line reaches the engine in its session, as written")
		first.sendAck(2)
		usleep(300_000)
		engine.toSession("r_one", #"{"event":"check","n":4}"#)
		usleep(300_000)
		// A new channel on the same socket: its first message ends the one before at the Mac, whose session waits.
		guard let (second, again) = Flows.attach(engine, mac: fmac, device: device, keys: keys1, session: "r_one", resume: (SessionID("r_one")!, 2), resumed: true, path: "relay", make: { Phone(relay: wire) }) else {
			Check.stop("the phone resumed over the relay")
		}
		let replayed = (3 ... 4).compactMap { _ in second.line() }
		Check.expect(again.resume && replayed == (3 ... 4).map { Data("{\"event\":\"check\",\"n\":\($0)}".utf8) }, "a resume on a new channel over the relay is sent what it had not acknowledged, in order")
		// Moving between paths (5.8): the session resumed at home, then over the relay again.
		second.sendAck(2)
		usleep(300_000)
		guard let (home1, _) = Flows.attach(engine, mac: fmac, device: device, keys: keys1, session: "r_one", resume: (SessionID("r_one")!, 2), resumed: true) else {
			Check.stop("the session moved to the home path")
		}
		home1.sendLine(Data(#"{"id":"h1","method":"engine.info","params":{}}"#.utf8))
		Check.expect(engine.sessionLine()?.1 == Data(#"{"session":"r_one","message":{"id":"h1","method":"engine.info","params":{}}}"#.utf8), "the same session moves to the home path, and its lines go on")
		home1.end()
		usleep(300_000)
		guard let (third, _) = Flows.attach(engine, mac: fmac, device: device, keys: keys1, session: "r_one", resume: (SessionID("r_one")!, 4), resumed: true, path: "relay", make: { Phone(relay: wire) }) else {
			Check.stop("the session moved back to the relay")
		}
		third.sendLine(Data(#"{"sessionEnd":{}}"#.utf8))
		Check.expect(engine.request("remote.sessionEnd")?.params["session"]?.stringValue == "r_one" && third.event() == .bye, "and back to the relay; the phone's sessionEnd ends it in the engine, and its channel")

		hostile(engine, mac: fmac, device: device, keys: keys1, wire: wire)
		mailbox(engine, mac: mac, device: device, keys: keys1, wire: wire, relay: relay)
		RelayedPushes.through(engine, mac: mac, device: device, keys: keys1, wire: wire, relay: relay, home: home)

		Check.section("the relay path off, and the home path on its own (6.5)")
		var count = engine.states.count
		let relayOff = JSONValue.object([("on", .bool(true)), ("relay", .bool(false)), ("home", .bool(true)), ("direct", .bool(false)), ("preview", .bool(true))])
		engine.event("settings", [("relay", .string(relay.absoluteString)), ("switches", relayOff)])
		let off = engine.relayState("off", from: count)
		Check.expect(off?["available"]?.boolValue == false && off?["why"]?.stringValue?.contains("home and private networks only") == true, "Reach through pi²'s relay off: the engine is told the relay path is off, as wanted", off.map(JSON.text) ?? "nothing")
		RelayedPushes.afterStop(engine, device: device, relay: relay, home: home, "the engine's first push again, the relay switch off")
		Check.expect(wire.ended(within: 5) == nil, "the phone's own socket at the relay stays")
		if let (home2, _) = Flows.attach(engine, mac: fmac, device: device, keys: keys1, session: "r_two") {
			Check.expect(true, "the home path attaches with the relay off")
			engine.event("sessionClosed", [("session", .string("r_two")), ("why", .string("check"))])
			_ = home2.event()
		} else {
			Check.expect(false, "the home path attaches with the relay off")
		}
		// On again, with a push in the same write (#935).
		Check.expect(RelayedPushes.beforeReady(engine, device: device, relay: relay, home: home), "on again: the relay path connects and is ready")
		// Another relay's address: the pairing is shown to no relay but its own.
		count = engine.states.count
		engine.event("settings", [("relay", .string("ws://127.0.0.1:9/v1")), ("switches", Flows.switches)])
		if let other = engine.request("remote.hello") { engine.answer(other.id) }
		let elsewhere = engine.relayState("unavailable", from: count)
		Check.expect(elsewhere?["why"]?.stringValue?.contains("not registered at this relay") == true, "another relay's address: the pairing is not shown to it, and the engine is told why", elsewhere.map(JSON.text) ?? "nothing")
		RelayedPushes.afterStop(engine, device: device, relay: relay, home: home, "the same push, at another relay's address")
		count = engine.states.count
		engine.event("settings", [("relay", .string(relay.absoluteString)), ("switches", Flows.switches)])
		if let back = engine.request("remote.hello") { engine.answer(back.id) }
		Check.expect(engine.relayState("ready", from: count) != nil, "back at its own relay: ready again")

		Check.section("revocation over the relay (3.6)")
		guard let (revoked, _) = Flows.attach(engine, mac: fmac, device: device, keys: keys1, session: "r_three", path: "relay", make: { Phone(relay: wire) }) else {
			Check.stop("attached over the relay before the revocation")
		}
		let pushesAfter = RelayedPushes.revokedWhileWaiting(engine, device: device, relay: relay, home: home) {
			engine.event("revoke", [("device", .string(device.text))])
			engine.event("sessionClosed", [("session", .string("r_three")), ("why", .string("revoked"))])
		}
		if let line = revoked.line(), case let .revoked(revocation)? = try? ControlLine.parse(line, from: .mac) {
			Check.expect((try? revocation.verify(identityKey: identity, pairing: pairing, device: device)) != nil && revoked.event() == .bye, "a revoked device is told so over the relay, signed by the identity key, and its channel ends")
		} else {
			Check.expect(false, "a revoked device is told so over the relay")
		}
		let removed = wire.ended(within: 15)
		Check.expect(removed?.contains("removed") == true, "and its slot at the relay is removed: the relay closes its socket", removed ?? "still open")
		pushesAfter()
		Check.expect(kept(home)?.devices.isEmpty == true, "and it is dropped from pi² Remote's own list")
		let log = (try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
		Check.expect(!log.contains(Base64URL.encode(secret)), "pi² Remote's log holds no pairing secret")
		// Last: a write that fails leaves pi² Remote with no home key until the next claim makes one (Remote.keep).
		unkept(engine, mac: mac, relay: relay, home: home, address: address)
	}

	/// A pairing over the relay that pi² Remote cannot keep (#887): the engine is asked to take it back, the phone is told
	/// `unsaved`, and the relay's window closes at once, with the phone's joined slot, not 30 seconds on (#921's third read).
	/// A write fails as in `Flows.homeKeyKept`: the data folder made read-only.
	static func unkept(_ engine: FakeEngine, mac: Mac, relay: URL, home: URL, address: String) {
		Check.section("a pairing over the relay that pi² Remote cannot keep (#887): the relay's window closes at once")
		let secret = Bytes.random(32)
		let expires = openJoin(engine, pairing: mac.pairing, secret: secret)
		let keys = PhoneKeys()
		guard let link = join(relay, pairing: mac.pairing, secret: secret, keys: keys) else { return Check.expect(false, "a second phone joins the relay's window") }
		let joined = RelayWire(link: link)
		defer { joined.close() }
		let phone = Phone(relay: joined)
		guard phone.pair(payload: payload(mac, relay: relay, secret: secret, expires: expires), keys: keys, team: team) != nil, let claim = engine.request("remote.pairClaim") else {
			return Check.expect(false, "the second phone's claim over the relay reached the engine")
		}
		engine.answer(claim.id, .object([("claim", .string("claim_r2"))]))
		engine.event("closeJoin")
		usleep(300_000)
		chmod(home.path, 0o500)
		let device = DeviceID.random()
		let began = Date()
		engine.event("paired", [
			("claim", .string("claim_r2")), ("device", keys.paired(id: device)),
			("paired", .object([("device", .string(device.text)), ("pairing", .string(mac.pairing.text)), ("name", .string("Check Mac")), ("addresses", .array([.string(address)]))])),
		])
		let request = engine.request("remote.pairUnkept")
		Check.expect(request?.params == .object([("device", .string(device.text))]), "the engine is asked to take the pairing back: remote.pairUnkept", request.map { JSON.text($0.params) } ?? "nothing")
		if let request { engine.answer(request.id) }
		if let line = phone.line(within: 10), case let .pairRefused(refusal)? = try? ControlLine.parse(line, from: .mac) {
			Check.expect(refusal.why == .unsaved, "the phone is told pairRefused unsaved over the relay, before its slot goes (#881)")
		} else {
			Check.expect(false, "the phone is told the Mac could not save the pairing, over the relay")
		}
		let ended = joined.ended(within: 10)
		let took = Date().timeIntervalSince(began)
		chmod(home.path, 0o700)
		Check.expect(ended != nil && took < 10, "the relay closes the window and drops the phone's joined slot at once, not 30 seconds on", String(format: "%@ after %.1f s", ended ?? "still open", took))
		let again = blocking(within: 30) {
			try await RelayClient.join(relay: relay, pairing: mac.pairing, build: phoneBuild, deviceKey: keys.device.publicKey, token: PairingSecrets.joinToken(secret: secret, pairing: mac.pairing), attest: { _ in throw TimedOut() })
		}
		if case .failure(RelayClientError.refused(.windowClosed)) = again {
			Check.expect(true, "and a join with that window's token is refused: the window is closed")
		} else {
			Check.expect(false, "a join with that window's token is refused as the window closed", "\(again)")
		}
		Check.expect(kept(home).map { kept in !kept.devices.contains { $0.id == device } } == true, "and the device is not on pi² Remote's own list")
	}

	/// #675's hostile cases, over the relay: each closed by the same code as on the home path, and none reaches the engine.
	static func hostile(_ engine: FakeEngine, mac: Flows.Mac, device: DeviceID, keys: PhoneKeys, wire: RelayWire) {
		Check.section("#675's hostile cases over the relay path: the same refusals, by the same code")
		var phone = Phone(relay: wire)
		phone.send(Bytes.random(96))
		Check.expect(phone.closesWithin(3) && engine.quiet(for: 1), "a pairing's first message with no window open: nothing answers, and the engine hears nothing")
		phone = Phone(relay: wire)
		phone.send(Bytes.random(48))
		Check.expect(phone.closesWithin(3) && engine.quiet(for: 1), "a connection's first message made for no device: nothing answers, and the engine hears nothing")
		phone = Phone(relay: wire)
		phone.send(Bytes.random(100))
		Check.expect(phone.closesWithin(3) && engine.quiet(for: 1), "a first message of another length: nothing answers, and the engine hears nothing")
		func attachAs(_ build: String, challenge given: Data? = nil, signer: P256.Signing.PrivateKey? = nil, _ what: String) {
			let phone = Phone(relay: wire)
			guard let challenge = Flows.beginAttach(phone, engine, mac: mac, device: device, keys: keys) else { return Check.expect(false, "\(what): the attach began") }
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: given ?? challenge, build: build, deviceKey: signer ?? keys.device, presenceKey: keys.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			Check.expect(phone.closesWithin(10), "\(what) is closed over the relay")
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}
		// A device's handshakes are six a minute on the relay path as at home: a fresh minute for these six.
		sleep(61)
		attachAs("7", signer: P256.Signing.PrivateKey(), "an attach not signed by the device key on pi² Remote's own list")
		attachAs("0", "an attach from a build below the minimum")
		attachAs("9a", "an attach whose build is not numbers and dots")
		attachAs("7", challenge: Bytes.random(32), "an attach that names another challenge than its channel's")
		let lines = [
			("[1]", "a line that is not one JSON object"),
			(String(decoding: ControlLine.homeKey(HomeKey.random()).line, as: UTF8.self), "a homeKey line from a phone"),
			(#"{"challenge":"x","mac":{"signed":"y","signature":"z"}}"#, "the Mac's proof from a phone"),
			(#"{"refused":{"reason":"update"}}"#, "a refused line from a phone"),
		]
		func session(_ index: Int) {
			let (line, what) = lines[index]
			guard let (session, attached) = Flows.attach(engine, mac: mac, device: device, keys: keys, session: "r_h\(index)", path: "relay", make: { Phone(relay: wire) }) else {
				return Check.expect(false, "attached over the relay for \(what)")
			}
			session.sendLine(Data(line.utf8))
			Check.expect(session.closesWithin(10), "\(what), in a session over the relay, closes its channel")
			Check.expect(engine.sessionLine(within: 1) == nil, "and never reaches the engine")
			engine.event("sessionClosed", [("session", .string(attached.session.text)), ("why", .string("check"))])
		}
		session(0)
		session(1)
		// The seventh within the minute.
		let seventh = Phone(relay: wire)
		let handshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: device, channelKey: keys.channel, remoteChannelKey: mac.channel)
		seventh.send(try! handshake.writeMessage())
		Check.expect(seventh.closesWithin(3) && engine.quiet(for: 1), "a seventh handshake for the device within a minute is closed before the engine hears of it: the limit the home path has")
		sleep(61)
		session(2)
		session(3)
	}

	/// The mailbox both ways (5.3; #806, #876): what the phone left, opened and handed to the engine, acknowledged only once
	/// the engine took it; what the engine leaves, sealed for the phone.
	static func mailbox(_ engine: FakeEngine, mac: Mac, device: DeviceID, keys: PhoneKeys, wire: RelayWire, relay: URL) {
		Check.section("the mailbox, from the phone: opened, verified, handed to the engine, acknowledged once taken (5.3, #806)")
		guard let client = wire.client else { return Check.expect(false, "the phone has a client at the relay") }
		func sealed(_ method: String, _ params: JSONValue, deviceKey: P256.Signing.PrivateKey? = nil, writer: P256.KeyAgreement.PrivateKey? = nil, at: Date = Date()) -> (ItemID, Data, RequestItem) {
			let id = ItemID.random()
			let request = try! RequestItem.make(method: method, params: params, pairing: mac.pairing, device: device, id: id, at: at, deviceKey: deviceKey ?? keys.device, presenceKey: keys.presence)
			let item = try! SealedItem.seal(request.plaintext, to: ItemAddress(pairing: mac.pairing, reader: .mac, id: id), readerKey: mac.record, writerKey: writer ?? keys.record)
			return (id, item, request)
		}
		func put(_ id: ItemID, _ item: Data) -> Bool {
			if case .success = blocking({ try await client.put(item, id: id, to: .mac) }) { return true }
			return false
		}
		let forged = sealed("abort", .object([("id", .integer(1))]), deviceKey: P256.Signing.PrivateKey())
		let stranger = sealed("abort", .object([("id", .integer(2))]), writer: P256.KeyAgreement.PrivateKey())
		let good = sealed("abort", .object([("id", .integer(3))]))
		Check.expect(put(forged.0, forged.1) && put(stranger.0, stranger.1) && put(good.0, good.1), "the phone leaves three items in the Mac's mailbox")
		guard let first = engine.request("remote.mailboxIn") else { return Check.expect(false, "pi² Remote takes the mailbox and hands an item to the engine") }
		Check.expect(first.params.keys == ["device", "id", "item"] && first.params["id"]?.stringValue == good.0.text && first.params["device"]?.stringValue == device.text,
		             "only the item sealed and signed by the device's keys on pi² Remote's own list reaches the engine (remote.mailboxIn), with its id", JSON.text(first.params))
		Check.expect(first.params["item"] == (try? JSON.parse(good.2.plaintext)), "as the phone wrote it, for the engine to check again")
		// The engine cannot take it now: it is left at the relay, and comes again.
		engine.refuse(first.id, "Reach from an iPhone is off on this Mac.")
		let next = sealed("abort", .object([("id", .integer(4))]))
		_ = put(next.0, next.1)
		guard let again = engine.request("remote.mailboxIn") else { return Check.expect(false, "the next take") }
		Check.expect(again.params["id"]?.stringValue == good.0.text, "an item the engine did not take comes again at the next take, unacknowledged", JSON.text(again.params))
		engine.answer(again.id, .object([("taken", .bool(true)), ("outcome", .string("done"))]))
		guard let then = engine.request("remote.mailboxIn") else { return Check.expect(false, "the item after it") }
		Check.expect(then.params["id"]?.stringValue == next.0.text, "then the one after it")
		engine.answer(then.id, .object([("taken", .bool(true)), ("outcome", .string("done"))]))
		// Genuine, and more than a day old (RelayEnd.itemOldest, the engine's own bound): never handed to the engine, where a
		// relay that kept it could replay it after a new Face ID key (#921's security read).
		let old = sealed("abort", .object([("id", .integer(6))]), at: Date().addingTimeInterval(-2 * 86_400))
		_ = put(old.0, old.1)
		let last = sealed("abort", .object([("id", .integer(5))]))
		_ = put(last.0, last.1)
		let after = engine.request("remote.mailboxIn")
		Check.expect(after?.params["id"]?.stringValue == last.0.text, "what the engine took, and what was not genuine, the relay deleted (took): only a new item comes at the next take; one genuine but two days old is not handed on", after.map { JSON.text($0.params) } ?? "nothing")
		if let after { engine.answer(after.id, .object([("taken", .bool(true)), ("outcome", .string("done"))])) }

		Check.section("the mailbox, to the phone: signed by the identity key, sealed to the device's record key (5.3)")
		let body = JSONValue.object([("nonce", .string(good.0.text)), ("method", .string("abort")), ("outcome", .string("done"))])
		engine.event("mailboxOut", [("device", .string(device.text)), ("item", .object([("kind", .string("receipt")), ("body", body)]))])
		engine.event("mailboxOut", [("device", .string(device.text)), ("item", .object([("kind", .string("state")), ("number", .integer(7)), ("body", .object([("x", .integer(1))]))]))])
		engine.event("mailboxOut", [("device", .string(DeviceID.random().text)), ("item", .object([("kind", .string("receipt")), ("body", body)]))])
		usleep(1_500_000)
		let identity = mac.identity, record = mac.record, pairing = mac.pairing, reader = keys.record
		let taken = blocking { () async throws -> [MacItem] in
			let opened = Locked<[MacItem]>([])
			_ = try await client.take { taken in
				var done = Set<ItemID>()
				for item in taken.items {
					if let mac = try? SealedItem.openMacItem(item.item, at: ItemAddress(pairing: pairing, reader: .device(device), id: item.id), readerKey: reader, writerRecordKey: record, identityKey: identity) {
						opened.update { $0.append(mac) }
						done.insert(item.id)
					}
				}
				if let state = taken.state, let mac = try? SealedItem.openMacItem(state.item, at: ItemAddress(pairing: pairing, reader: .device(device), id: state.id), readerKey: reader, writerRecordKey: record, identityKey: identity) {
					opened.update { $0.append(mac) }
					done.insert(state.id)
				}
				return done
			}
			return opened.get()
		}
		let items = (try? taken.get()) ?? []
		Check.expect(items.contains { $0.kind == "receipt" && $0.body == body }, "the phone takes the receipt the engine left, signed by the Mac's identity key and sealed for it", "\(items.map(\.kind))")
		Check.expect(items.contains { $0.kind == "state" && $0.number == 7 }, "and the state, as the relay keeps a device's latest")
		Check.expect(items.count == 2, "and nothing for a device not on pi² Remote's own list")
	}

	/// A relay that floods (#921's security read, M2 and S2): `LyingRelay` on 127.0.0.1 registers pi² Remote, takes it as
	/// the pairing's Mac, lists 16 devices pi² Remote does not have and refuses each `removeDevice`, then sends 3,000 each
	/// of `anotherMac`, `left`, `joined` and `held` notices and hands over 3,000 items that are not genuine, a `mail` after
	/// every `took`. What that may cost: one `remote.state` (and so one `devices` event to the app) for the `anotherMac`
	/// notices in a minute, one log line for each kind of the relay's word, of its refusals or of the items in a minute,
	/// and a take every five seconds at most; the engine is handed none of the items.
	static func flood(helper: URL, home: URL) {
		Check.section("a relay that floods (#921): bounded in what it costs the engine, the log and the takes")
		// The day pi² Remote keeps a phone's item is the engine's own bound (RelayEnd.itemOldest, devices.ts's DAY).
		let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let engineSource = (try? String(contentsOf: repository.appendingPathComponent("engine/src/devices.ts"), encoding: .utf8)) ?? ""
		let relayEnd = (try? String(contentsOf: repository.appendingPathComponent("app/Sources/pi2-remote/Relay/RelayEnd.swift"), encoding: .utf8)) ?? ""
		Check.expect(engineSource.contains("const DAY = 86_400_000;") && engineSource.contains("if (now - at > DAY) return refuse(ITEM_TOO_OLD);") && relayEnd.contains("static let itemOldest: Int64 = 86_400_000"),
		             "pi² Remote hands on no item older than the engine takes: a day on each side")
		guard let relay = LyingRelay() else { return Check.expect(false, "a lying relay listens on 127.0.0.1") }
		defer { relay.stop() }
		// pi² Remote anew on the same data folder: no pairing, and its devices and keys as the run before left them.
		for file in ["remote-devices.json", "remote-keys.json"] { try? FileManager.default.removeItem(at: home.appendingPathComponent(file)) }
		let (child, engine) = Starts.start(helper: helper, home: home)
		defer { child.stop() }
		engine.answersStates = true
		engine.event("start", [("relay", .string(relay.url.absoluteString)), ("switches", Flows.switches), ("pairing", .null), ("devices", .array([])), ("minimumBuild", .string("1"))])
		guard let hello = engine.request("remote.hello") else { return Check.expect(false, "pi² Remote said hello") }
		engine.answer(hello.id)
		engine.event("register")
		guard engine.state(where: { $0["pairing"]?.stringValue == relay.pairing.text }) != nil, engine.relayState("ready") != nil else {
			return Check.expect(false, "pi² Remote registered at the lying relay and is ready there", JSON.text(.array(engine.states)))
		}
		let logFile = home.appendingPathComponent("remote.log")
		func logLines() -> [Substring] { ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n") }
		let statesBefore = engine.states.count
		let linesBefore = logLines().count
		let began = Date()
		relay.flood(notices: 3_000, items: 3_000)
		// Read the engine's end while the relay floods: pi² Remote waits for no answer it is not given.
		while relay.acknowledged < 3_000, Date().timeIntervalSince(began) < 150 { _ = engine.state(from: Int.max, within: 1) { _ in false } }
		_ = engine.state(from: Int.max, within: 2) { _ in false }
		let minutes = Int(Date().timeIntervalSince(began) / 60) + 1
		let states = engine.states.dropFirst(statesBefore)
		let lines = logLines().dropFirst(linesBefore)
		Check.expect(relay.acknowledged == 3_000, "the 3,000 items that are not genuine are taken and acknowledged (took)", "\(relay.acknowledged) in \(relay.takes.count) takes")
		Check.expect(engine.quiet(for: 1), "and none is handed to the engine")
		let told = states.filter { $0["relay"]?["anotherMacAt"] != nil }.count
		Check.expect(told >= 1 && states.count <= minutes, "3,000 anotherMac notices: the engine is told at most once a minute (\(states.count) remote.state in \(minutes) minute(s) begun), so the app at most one devices event", JSON.text(.array(Array(states))))
		// relay anotherMac, relay left, relay items not genuine, relay ready, relay take, relay joined, relay held, relay listed,
		// relay request removeDevice
		let kinds = 9
		let joinedLines = lines.filter { $0.contains("a phone joined the pairing window") }.count, heldLines = lines.filter { $0.contains("it held device") }.count
		Check.expect(joinedLines >= 1 && joinedLines <= minutes && heldLines >= 1 && heldLines <= minutes, "3,000 joined and 3,000 held notices: each in the log at most once a minute", "\(joinedLines) and \(heldLines) lines in \(minutes) minute(s) begun")
		let refusedLines = logLines().filter { $0.contains("the relay's removeDevice") }.count
		Check.expect(relay.refused == 16 && refusedLines == 1, "16 removeDevice requests the relay refused, all within the minute: one line in the log", "\(relay.refused) refused, \(refusedLines) lines")
		Check.expect(lines.count <= kinds * minutes, "3,000 notices and 3,000 items: \(lines.count) lines in pi² Remote's log, at most one for each of the relay's \(kinds) kinds a minute", lines.joined(separator: "\n"))
		let gaps = zip(relay.takes.dropFirst(), relay.takes).map { $0.timeIntervalSince($1) }
		Check.expect(relay.takes.count >= 15 && gaps.allSatisfy { $0 >= 4.5 }, "a take at most every five seconds, a mail after every took notwithstanding", gaps.map { String(format: "%.1f", $0) }.joined(separator: " "))
	}
}

/// A relay on 127.0.0.1 that lies (#921's security read): the relay's protocol as far as pi² Remote's end needs it to
/// register and be taken as the pairing's Mac (relay/README.md), a take and its `took`, and floods of what a relay may
/// say. A WebSocket listener of the check's own, on loopback alone.
final class LyingRelay: @unchecked Sendable {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "lying relay")
	let pairing = PairingID.random()
	private(set) var url = URL(string: "ws://127.0.0.1/v1")!
	private let state = Locked<(mac: NWConnection?, items: [JSONValue], acknowledged: Int, takes: [Date], refused: Int)>((nil, [], 0, [], 0))
	var acknowledged: Int { state.get().acknowledged }
	var refused: Int { state.get().refused }
	var takes: [Date] { state.get().takes }

	init?() {
		let options = NWProtocolWebSocket.Options()
		options.autoReplyPing = true
		let parameters = NWParameters.tcp
		parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		guard let made = try? NWListener(using: parameters) else { return nil }
		listener = made
		let ready = DispatchSemaphore(value: 0)
		listener.stateUpdateHandler = { state in
			if case .ready = state { ready.signal() }
			if case .failed = state { ready.signal() }
		}
		listener.newConnectionHandler = { [unowned self] connection in self.accept(connection) }
		listener.start(queue: queue)
		guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue, port != 0 else { return nil }
		url = URL(string: "ws://127.0.0.1:\(port)/v1")!
	}

	func stop() {
		listener.cancel()
		state.get().mac?.cancel()
	}

	/// `notices` each of `anotherMac`, `left`, `joined` and `held` to the Mac, then `items` that are not genuine, 200 a take.
	func flood(notices: Int, items: Int) {
		queue.async { [self] in
			guard let mac = state.get().mac else { return }
			let deviceKey = Base64URL.encode(P256.Signing.PrivateKey().publicKey.derRepresentation)
			for _ in 0 ..< notices {
				send(mac, "joined", [("device", .string(DeviceID.random().text)), ("deviceKey", .string(deviceKey)), ("keyId", .string(AttestKeyID(bytes: Bytes.random(32))!.text))])
				send(mac, "held", [("device", .string(DeviceID.random().text)), ("until", .integer(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000))])
				send(mac, "anotherMac", [])
				// As #897's relay writes it: the phone's time and a notice, here 64 bytes no key signed.
				let at = Int64(Date().timeIntervalSince1970 * 1000)
				send(mac, "left", [("device", .string(DeviceID.random().text)), ("at", .integer(at)), ("notice", .string(Base64URL.encode(Bytes.random(64))))])
			}
			let made: [JSONValue] = (0 ..< items).map { _ in
				.object([("from", .string(DeviceID.random().text)), ("id", .string(ItemID.random().text)), ("item", .string(Base64URL.encode(Data([4]) + Bytes.random(100)))), ("presence", .bool(true))])
			}
			state.update { $0.items += made }
			send(mac, "mail", [])
		}
	}

	private func send(_ connection: NWConnection, _ name: String, _ body: [(String, JSONValue)]) {
		send(connection, .object([(name, .object(body))]))
	}

	private func send(_ connection: NWConnection, _ message: JSONValue) {
		let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
		connection.send(content: Data(JSON.text(message).utf8), contentContext: context, isComplete: true, completion: .idempotent)
	}

	private func accept(_ connection: NWConnection) {
		connection.start(queue: queue)
		receive(connection, registering: false)
	}

	private func receive(_ connection: NWConnection, registering: Bool) {
		connection.receiveMessage { [self] content, _, _, error in
			guard error == nil, let content, let message = try? JSON.parse(content), case let .object(members) = message, members.count == 1 else { return connection.cancel() }
			var registering = registering
			switch members[0].0 {
			case "register":
				registering = true
				send(connection, .object([("challenge", .string(Base64URL.encode(Bytes.random(32))))]))
			case "hello":
				send(connection, .object([("challenge", .string(Base64URL.encode(Bytes.random(32))))]))
			case "proof" where registering:
				send(connection, "registered", [("pairing", .string(pairing.text))])
			case "proof":
				state.update { $0.mac = connection }
				// 16 devices pi² Remote's list does not have: it asks to remove each, and is refused.
				let listed: [JSONValue] = (0 ..< 16).map { _ in .object([("device", .string(DeviceID.random().text)), ("online", .bool(false))]) }
				send(connection, "ready", [("devices", .array(listed)), ("left", .array([])), ("pending", .bool(false)), ("mail", .integer(0))])
			case "removeDevice":
				state.update { $0.refused += 1 }
				send(connection, "refused", [("what", .string("removeDevice")), ("why", .string("unavailable"))])
			case "ping":
				send(connection, "pong", [])
			case "take":
				let handed = state.update { held -> [JSONValue] in
					held.takes.append(Date())
					return Array(held.items.prefix(200))
				}
				for item in handed { send(connection, .object([("item", item)])) }
				send(connection, "taken", [("count", .integer(Int64(handed.count)))])
			case "took":
				let ids = Set(message["took"]?["ids"].map { value -> [String] in
					if case let .array(all) = value { return all.compactMap(\.stringValue) }
					return []
				} ?? [])
				let more = state.update { held -> Bool in
					let before = held.items.count
					held.items.removeAll { ids.contains($0["id"]?.stringValue ?? "") }
					held.acknowledged += before - held.items.count
					return !held.items.isEmpty
				}
				send(connection, "ok", [("what", .string("took"))])
				// What a lying relay may do: say there is mail after every took.
				if more { send(connection, "mail", []) }
			default:
				break
			}
			receive(connection, registering: registering)
		}
	}
}
