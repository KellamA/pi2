import CryptoKit
import Darwin
import Dispatch
import Foundation
import RemoteKit

/// The switches the engine gives pi² Remote (`start`, `settings`; docs/iphone.md 3.2's `remote`).
package struct Switches: Sendable, Equatable {
	package var on = false
	package var relay = true
	package var home = true
	package var direct = false
	package var preview = false

	package init() {}

	init(_ value: JSONValue?) {
		on = value?["on"]?.boolValue ?? false
		relay = value?["relay"]?.boolValue ?? true
		home = value?["home"]?.boolValue ?? true
		direct = value?["direct"]?.boolValue ?? false
		preview = value?["preview"]?.boolValue ?? false
	}
}

/// An open pairing window, as the engine opened it (`openJoin`): the pairing's secret `s` and when it closes.
struct JoinWindow {
	let secret: Data
	let expires: TimeInterval
}

/// pi² Remote once its start-up checks have passed: the Mac's keys, its own list of devices, the home path's listener,
/// the pairing windows and the device sessions, all on one queue, steered by the engine alone over the control
/// connection (docs/iphone.md 5.5, docs/pi2-remote.md).
package final class Remote: @unchecked Sendable {
	package let queue: DispatchQueue
	package let kind: BuildKind
	package let keys: MacKeys
	let vault: any KeyVault
	let engine: EngineLink
	let advertiser: (any Advertiser)?

	/// How long a session waits for its phone after its channel drops (5.8).
	package var resumeWindow: TimeInterval = 60
	/// How long a new connection has to attach, or a pairing claimer to send its first transport message (3.4).
	package var attachWithin: TimeInterval = 10
	/// The most lines a session keeps that its phone has not acknowledged, in bytes (5.8).
	package var sessionBufferLimit = 4 * 1024 * 1024

	package private(set) var devices: [ListedDevice]
	private var started = false
	var switches = Switches()
	var relay = ""
	/// The relay key of the relay in use (`relay`): one for each relay address, never shown to another relay.
	package private(set) var relayKey: SigningKey?
	package private(set) var pairing: PairingID?
	var minimumBuild = "1"
	var window: JoinWindow?
	package private(set) var listener: Listener?
	let admission = Admission()
	var connections: [ObjectIdentifier: PhoneConnection] = [:]
	/// Pairing channels whose claim waits for the person's digits, by the claim's id.
	var claims: [String: PhoneConnection] = [:]
	package private(set) var sessions: [String: Session] = [:]
	private var addresses: [String] = []
	private var addressTimer: DispatchSourceTimer?
	private var advertised: String?

	package init(kind: BuildKind, keys: MacKeys, vault: any KeyVault, engine: EngineLink, queue: DispatchQueue) throws {
		self.kind = kind
		self.keys = keys
		self.vault = vault
		self.engine = engine
		self.queue = queue
		advertiser = Advertisers.forBuild(kind, queue: queue)
		devices = try vault.devices()
		engine.onEvent = { [unowned self] in self.heard($0) }
		engine.onSessionLine = { [unowned self] in self.fromEngine(session: $0, message: $1) }
	}

	/// Seconds since 1970.
	var now: TimeInterval { Date().timeIntervalSince1970 }

	// ---- The engine's `remote` events

	private func heard(_ event: JSONValue) {
		guard let kind = event["kind"]?.stringValue else { return }
		switch kind {
		case "start": start(event)
		case "settings": settings(event)
		case "register": register(event)
		case "openJoin":
			guard let secret = event["secret"]?.stringValue.flatMap({ Base64URL.decode($0, count: 32) }), let expires = event["expires"]?.integerValue else {
				log("openJoin: not a pairing window; left")
				return
			}
			window = JoinWindow(secret: secret, expires: TimeInterval(expires) / 1000)
			log("a pairing window is open until \(Date(timeIntervalSince1970: TimeInterval(expires) / 1000))")
		case "closeJoin":
			// Only channels with no claim yet: the engine says `closeJoin` before `paired` (devices.ts, pairConfirm).
			window = nil
			for connection in connections.values where connection.isPairingBeforeClaim { connection.windowClosed() }
			log("the pairing window closed")
		case "paired": paired(event)
		case "pairRefused":
			if let claim = event["claim"]?.stringValue, let connection = claims.removeValue(forKey: claim) {
				log("a claim was refused on the Mac; its channel is closed")
				connection.end()
			}
		case "revoke":
			if let text = event["device"]?.stringValue, let device = DeviceID(text) { revoke(device) }
		case "sessionClosed":
			// The engine closes a revoked device's sessions before it says `revoke` (remote.ts, devices.ts): the channel
			// is kept two seconds more, so that the phone can be told it was revoked before the channel ends (5.6, 3.6).
			if let id = event["session"]?.stringValue, let session = sessions.removeValue(forKey: id) {
				session.closed(grace: 2)
				log("the engine closed session \(id)")
			}
		default:
			break
		}
	}

	/// The first event: what the engine has of the pairing and the switches. pi² Remote's own list of devices loses any
	/// device `start` does not list (revoked while pi² Remote was not running, 3.6), and gains none: a device is added
	/// to it only when the engine pairs it (`paired`), so a device written into the engine's store by hand is never
	/// attached (5.5).
	private func start(_ event: JSONValue) {
		guard !started else { return }
		started = true
		relay = event["relay"]?.stringValue ?? ""
		switches = Switches(event["switches"])
		pairing = event["pairing"]?.stringValue.flatMap(PairingID.init)
		if let build = event["minimumBuild"]?.stringValue, Self.isBuild(build) { minimumBuild = build }
		var listed = Set<String>()
		if case let .array(items)? = event["devices"] { for item in items { if let id = item["id"]?.stringValue { listed.insert(id) } } }
		let kept = devices.filter { listed.contains($0.id.text) }
		if kept.count != devices.count {
			log("\(devices.count - kept.count) device(s) the engine no longer lists were dropped from pi² Remote's own list")
			devices = kept
			saveDevices()
		}
		applySwitches()
		hello()
	}

	/// `remote.hello`: the Mac's public keys, with the relay key of the relay in use, the pairing and the addresses. Said
	/// again when the relay's address changes, since each relay has a key of its own; the engine takes the new one.
	private func hello() {
		do {
			relayKey = try vault.relayKey(for: relay)
		} catch {
			log("the relay key could not be read or made: \(error); stopping")
			exit(1)
		}
		let hello: [(String, JSONValue)] = [
			("macKeys", keys.report(relay: relayKey!)), ("pairing", pairing.map { .string($0.text) } ?? .null), ("addresses", .array(addresses.map(JSONValue.string))),
		]
		engine.request("remote.hello", .object(hello)) { result in
			if case let .failure(refusal) = result {
				log("the engine refused remote.hello: \(refusal); stopping")
				exit(1)
			}
			log("said hello: \(self.devices.count) device(s) on pi² Remote's own list, keys in \(self.vault.name)")
		}
	}

	private func settings(_ event: JSONValue) {
		let before = relay
		relay = event["relay"]?.stringValue ?? relay
		switches = Switches(event["switches"])
		applySwitches()
		if relay.utf8.elementsEqual(before.utf8) {
			reportAddresses()
		} else {
			log("the relay's address changed: its own relay key is told to the engine")
			addresses = listener?.addresses ?? []
			hello()
		}
	}

	/// The relay's `register`. The relay's client is #678's (P10, `Relay/`); until it is here, a development build gives
	/// itself a pairing's id, as a local relay would, so that pairing and attaching on the home path can be tried in a
	/// throwaway copy with no relay at all. A release build has no relay to register with yet, and says so.
	private func register(_ event: JSONValue) {
		#if PI2_DEVELOPMENT
		if pairing == nil {
			let made = PairingID.random()
			pairing = made
			log("register: no relay client yet (#678); a development build made its own pairing's id")
			engine.request("remote.state", .object([("pairing", .string(made.text))]))
		}
		#else
		log("register: this build has no relay client yet (#678)")
		#endif
	}

	// ---- The home path

	/// Starts or stops the listener as the switches say: while **Find on this network** is on (5.4).
	private func applySwitches() {
		if switches.home, listener == nil {
			do {
				let made = try Listener(loopbackOnly: kind == .development, queue: queue)
				made.onAccept = { [unowned self] in self.accepted($0, from: $1) }
				made.start()
				listener = made
				log("listening on \(made.loopbackOnly ? "127.0.0.1" : "every address"), port \(made.port)")
			} catch {
				log("the home listener could not start: \(error)")
			}
		} else if !switches.home, let current = listener {
			current.stop()
			listener = nil
			for connection in connections.values { connection.end() }
			log("stopped listening: Find on this network is off")
		}
		addresses = listener?.addresses ?? []
		advertise()
		if kind == .release, addressTimer == nil {
			let timer = DispatchSource.makeTimerSource(queue: queue)
			timer.schedule(deadline: .now() + 30, repeating: 30)
			timer.setEventHandler { [unowned self] in self.reportAddresses() }
			timer.resume()
			addressTimer = timer
		}
	}

	/// Tells the engine the Mac's addresses when they changed, and the phone with them (5.4, the `device` event).
	private func reportAddresses() {
		let now = listener?.addresses ?? []
		advertise()
		guard now != addresses else { return }
		addresses = now
		engine.request("remote.state", .object([("addresses", .array(now.map(JSONValue.string)))]))
	}

	/// Bonjour, in a release build with the listener on and a pairing to make a tag from.
	private func advertise() {
		guard let advertiser else { return }
		guard let listener, let pairing else {
			advertiser.stop()
			advertised = nil
			return
		}
		let tag = HomeTag.tag(channelKey: keys.channel.publicKey, pairing: pairing, date: Date())
		let key = "\(listener.port) \(tag)"
		guard key != advertised else { return }
		advertised = key
		advertiser.advertise(port: listener.port, txt: HomeTag.txtRecord(tag: tag))
	}

	private func accepted(_ descriptor: Int32, from peer: IPAddress) {
		// Direct from any address off: only local and private ranges (5.4, decision 32). In loopback mode the listener is
		// on 127.0.0.1 alone, so nothing else reaches it.
		if kind == .release, !switches.direct, !peer.isLocalOrPrivate {
			Seldom.shared.say("public", "a connection from an address outside the local and private ranges refused (Direct from any address is off)")
			close(descriptor)
			return
		}
		guard admission.admit(peer) else {
			Seldom.shared.say("pending", "a connection from \(peer) refused: \(admission.pendingCount) wait to authenticate already")
			close(descriptor)
			return
		}
		let connection = PhoneConnection(remote: self, descriptor: descriptor, peer: peer)
		connections[ObjectIdentifier(connection)] = connection
		connection.start()
	}

	func forget(_ connection: PhoneConnection) {
		connections.removeValue(forKey: ObjectIdentifier(connection))
	}

	/// The paired devices' channel keys, for finding which one sent a connection's first message.
	var channelKeys: [(DeviceID, Curve25519.KeyAgreement.PublicKey)] { devices.map { ($0.id, $0.channelKey) } }

	func listed(_ device: DeviceID) -> ListedDevice? { devices.first { $0.id == device } }

	/// The pairing window, if one is open now.
	var openWindow: JoinWindow? {
		guard let window, window.expires > now else { return nil }
		return window
	}

	// ---- Pairing (3.3)

	private func paired(_ event: JSONValue) {
		guard let deviceValue = event["device"], let device = ListedDevice(json: deviceValue) else {
			log("paired: the engine named a device pi² Remote cannot read; left")
			return
		}
		devices.removeAll { $0.id == device.id }
		devices.append(device)
		saveDevices()
		log("paired device \(device.id): added to pi² Remote's own list")
		guard let claim = event["claim"]?.stringValue, let connection = claims.removeValue(forKey: claim) else { return }
		let answer = event["paired"]
		guard let pairingText = answer?["pairing"]?.stringValue, let pairingID = PairingID(pairingText), let name = answer?["name"]?.stringValue,
		      case let .array(items)? = answer?["addresses"],
		      let line = try? Paired(device: device.id, pairing: pairingID, name: name, addresses: items.compactMap(\.stringValue))
		else {
			log("paired: the answer for the phone is not one RemoteKit writes; its channel is closed")
			connection.end()
			return
		}
		connection.sendLine(ControlLine.paired(line).line)
		connection.end()
	}

	private func revoke(_ device: DeviceID) {
		let before = devices.count
		devices.removeAll { $0.id == device }
		if devices.count != before { saveDevices() }
		// The phone is told first, signed by the identity key, which it acts on alone (3.6); then its channels end.
		for connection in connections.values where connection.device == device {
			if let pairing, let revocation = try? Revocation.make(pairing: pairing, device: device, identity: keys.identity) {
				connection.sendLine(ControlLine.revoked(revocation).line)
			}
		}
		for (id, session) in sessions where session.device == device {
			sessions.removeValue(forKey: id)
			session.closed()
		}
		for connection in connections.values where connection.device == device { connection.end() }
		log("revoked device \(device): dropped from pi² Remote's own list")
	}

	private func saveDevices() {
		do {
			try vault.saveDevices(devices)
		} catch {
			log("pi² Remote's own list of devices could not be saved: \(error)")
		}
	}

	// ---- Sessions (4.1, 5.8)

	/// A phone attached: a new session, or one resumed on this new channel.
	func attached(_ connection: PhoneConnection, device: DeviceID, session id: SessionID, resumed: Bool, received: UInt64?) -> Bool {
		if resumed {
			guard let session = sessions[id.text], session.device == device else {
				// The engine resumed a session pi² Remote no longer holds the lines of: it is ended, and the phone attaches
				// afresh on a new channel.
				log("session \(id) was resumed by the engine but has no buffer here; ended")
				engine.request("remote.sessionEnd", .object([("session", .string(id.text))]))
				return false
			}
			return session.resume(on: connection, received: received ?? 0)
		}
		// A fresh session; a session the phone asked to resume and the engine did not is gone.
		let session = Session(remote: self, id: id, device: device)
		sessions[id.text] = session
		session.attach(connection)
		return true
	}

	private func fromEngine(session id: String, message: Data) {
		guard let session = sessions[id] else { return }
		session.fromEngine(message)
	}

	/// Ends a session from pi² Remote's side: its phone's session ended (`sessionEnd`), its resume window lapsed, or its
	/// buffer was passed. The engine is told, and closes it (4.5, 5.8).
	func end(_ session: Session, why: String) {
		guard sessions.removeValue(forKey: session.id.text) != nil else { return }
		session.closed()
		log("ended session \(session.id): \(why)")
		engine.request("remote.sessionEnd", .object([("session", .string(session.id.text))]))
	}

	// ---- Builds

	/// A build as the engine writes one: 1 to 4 numbers of 1 to 9 digits, joined by dots.
	package static func isBuild(_ text: String) -> Bool {
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		return (1 ... 4).contains(parts.count) && parts.allSatisfy { (1 ... 9).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
	}

	/// Whether `build` is at least `minimum`, part by part, as the engine compares them (devices.ts, `buildAtLeast`).
	package static func buildAtLeast(_ build: String, _ minimum: String) -> Bool {
		let a = build.split(separator: ".").map { Int($0) ?? 0 }
		let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
		for index in 0 ..< max(a.count, b.count) {
			let (p, q) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
			if p != q { return p > q }
		}
		return true
	}
}
