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
	/// Pushes the engine chooses, sealed and handed to the relay (Push/, #689).
	package let pushes: PushHandOver

	/// How long a session waits for its phone after its channel drops (5.8).
	package var resumeWindow: TimeInterval = 60
	/// How long a new connection has to attach, or a pairing claimer to send its first transport message (3.4).
	package var attachWithin: TimeInterval = 10
	/// The longest line taken from an attached phone (#675's security read B, M2): 16 MB, room for a message with two
	/// pictures at the engine's limit of 5 MB each, written in base64, and its text. The engine's own request from a
	/// phone needs no more; the engine caps what it takes from pi² Remote at the same (#776). A phone that sends more
	/// pictures sends them in more than one message.
	package static let phoneLineLimit = 16 * 1024 * 1024

	/// The most lines a session keeps that its phone has not acknowledged, in bytes (5.8).
	package var sessionBufferLimit = 4 * 1024 * 1024

	package private(set) var devices: [ListedDevice]
	/// The home tag's key (#845; remotekit.md, "The home key"): made when the first pairing's claim goes to the engine,
	/// given in `paired` and on every attach, made anew at every revocation, none once no device is left. Never sent to
	/// the engine, never logged. While it is not nil, the vault holds exactly it and `devices` (`keep`).
	package private(set) var homeKey: HomeKey?
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

	/// `advertiser` is the build's (`Advertisers.forBuild`); the check gives one that records what it is asked to advertise.
	package init(kind: BuildKind, keys: MacKeys, vault: any KeyVault, engine: EngineLink, queue: DispatchQueue, advertiser: (any Advertiser)?) throws {
		self.kind = kind
		self.keys = keys
		self.vault = vault
		self.engine = engine
		self.queue = queue
		self.advertiser = advertiser
		pushes = PushHandOver(queue: queue, keys: keys) { [engine] id, why in
			engine.request("remote.pushRefused", .object([("id", .string(id)), ("why", .string(why))]))
		}
		let kept = try vault.kept()
		devices = kept.devices
		homeKey = kept.homeKey
		engine.onEvent = { [unowned self] in self.heard($0) }
		engine.onSessionLine = { [unowned self] in self.fromEngine(session: $0, message: $1) }
		engine.onDrained(below: Self.engineDrained) { [unowned self] in self.engineDrained() }
	}

	/// Seconds since 1970.
	var now: TimeInterval { Date().timeIntervalSince1970 }

	// ---- The engine's `remote` events

	/// The engine's `start`, read before anything else (`Startup.firstLine`); then the control connection's own lines.
	package func begin(_ start: JSONValue) { heard(start) }

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
			// A claim with the engine is answered right after: `paired` follows `closeJoin` within one save, `pairRefused`
			// at once. Neither within 30 seconds, and its channel ends, with no try counted.
			for connection in connections.values where connection.isClaim { connection.endIfUnanswered(after: PhoneConnection.answerAfterCloseJoin) }
			log("the pairing window closed")
		case "paired": paired(event)
		case "pairRefused":
			if let claim = event["claim"]?.stringValue, let connection = claims.removeValue(forKey: claim) {
				log("a claim was refused on the Mac; its channel is closed")
				// The engine's word for the phone, when it gives one (#881); its words are never read.
				if let why = EngineWords.pairRefusal(event["reason"]?.stringValue) { connection.refusePairing(why) } else { connection.end() }
			}
		case "revoke":
			if let text = event["device"]?.stringValue, let device = DeviceID(text) { revoke(device) }
		case "push": pushes.take(event, pairing: pairing, devices: devices)
		case "sessionClosed":
			// The engine says `revoke` before it closes a revoked device's sessions (#776's 25), so the `revoked` line has
			// gone already: the channel ends at once.
			if let id = event["session"]?.stringValue, let session = sessions.removeValue(forKey: id) {
				session.closed()
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
			// Revoked while pi² Remote was not running, or by a revocation whose write failed: the key the device holds goes
			// too, before anything is advertised (nothing is until `applySwitches` below). A new one if a device is left,
			// none if not; if it cannot be kept, none at all, and nothing is advertised.
			devices = kept
			keep(devices, homeKey: devices.isEmpty ? nil : HomeKey.random())
		}
		applySwitches()
		hello()
	}

	/// `remote.hello`: the Mac's public keys, with the relay key of the relay in use, the pairing and the addresses. Said
	/// again when the relay's address changes, since each relay has a key of its own; the engine takes the new one.
	///
	/// A relay key that cannot be read or made concerns the relay path alone (#675's security read B): pi² Remote carries
	/// on with the home and direct paths, the relay path off (`relayKey` nil, which #678's client reads), and says why in
	/// `remote.state`. `remote.hello` must name a relay key, so it names one made for this run alone and kept nowhere,
	/// which signs nothing: the engine can show the relay as off, once it reads `relay` in `remote.state` (#776).
	private func hello() {
		var unavailable: String?
		do {
			relayKey = try vault.relayKey(for: relay)
		} catch {
			relayKey = nil
			unavailable = "the relay key for this address could not be read or made (\(error)); the relay path is off, home and direct carry on"
			log(unavailable!)
		}
		addresses = listener?.addresses ?? []
		let shown = relayKey ?? .software(P256.Signing.PrivateKey())
		let hello: [(String, JSONValue)] = [
			("macKeys", keys.report(relay: shown)), ("pairing", pairing.map { .string($0.text) } ?? .null), ("addresses", .array(addresses.map(JSONValue.string))),
		]
		engine.request("remote.hello", .object(hello)) { result in
			if case let .failure(refusal) = result {
				log("the engine refused remote.hello: \(refusal); stopping")
				exit(1)
			}
			// After the hello, which the engine takes `remote.state` only after.
			if let unavailable {
				self.engine.request("remote.state", .object([("relay", .object([("available", .bool(false)), ("why", .string(Log.oneLine(unavailable)))]))]))
			}
			log("said hello: \(self.devices.count) device(s) on pi² Remote's own list, keys in \(self.vault.name)")
		}
	}

	private func settings(_ event: JSONValue) {
		let before = relay
		relay = event["relay"]?.stringValue ?? relay
		switches = Switches(event["switches"])
		applySwitches()
		// Direct from any address turned off: the connections it let in end now, not when they next connect (M4). Their
		// sessions keep the resume window, for another path.
		for connection in connections.values where !admits(peer: connection.peer, arrivedOn: connection.arrivedOn, kind: kind, direct: switches.direct) {
			log("a connection from outside the local and private ranges ended: Direct from any address is off")
			connection.windowClosed()
		}
		if relay.utf8.elementsEqual(before.utf8) {
			reportAddresses()
		} else {
			log("the relay's address changed: its own relay key is told to the engine")
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
			for connection in connections.values { connection.windowClosed() }
			log("stopped listening: Find on this network is off")
		}
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
	/// `addresses` is what the engine was last told, by `remote.hello` or `remote.state`, never the listener's own: a
	/// listener started again has a new port, which the engine must hear of (#675's security read B, M5).
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
		// No home key, or no device to hold it (before the first pairing, and after the last device is revoked): nothing
		// to recognise, so nothing is advertised (a claimer finds the Mac by the payload's addresses).
		guard let homeKey, !devices.isEmpty else {
			advertiser.stop()
			advertised = nil
			return
		}
		let tag = HomeTag.tag(key: homeKey, pairing: pairing, date: Date())
		let key = "\(listener.port) \(tag)"
		guard key != advertised else { return }
		advertised = key
		advertiser.advertise(port: listener.port, txt: HomeTXT.record(tag: tag))
	}

	private func accepted(_ descriptor: Int32, from peer: IPAddress) {
		// Which interface it came by matters only for the shared address space (D2), so it is looked up for that alone.
		let arrivedOn = peer.isSharedAddressSpace ? MacAddresses.routeInterface(to: peer) : nil
		guard admits(peer: peer, arrivedOn: arrivedOn, kind: kind, direct: switches.direct) else {
			Seldom.shared.say("public", "a connection from an address outside the local and private ranges refused (Direct from any address is off)")
			close(descriptor)
			return
		}
		// Too many waiting: the oldest that has sent no first message yet goes, from the same source if that source is
		// over its share, so that a stranger holding idle connections cannot keep a phone out (D1).
		// The key it is counted under, kept with the connection and released by (D1-a2).
		let key = admission.sourceKey(peer)
		while true {
			let admitted = admission.admit(key: key)
			if admitted == .taken { break }
			let idle = connections.values.filter { $0.waitingForFirstMessage && (admitted == .allFull || $0.admissionKey == key) }
			guard let oldest = idle.min(by: { $0.acceptedAt < $1.acceptedAt }) else {
				Seldom.shared.say("pending", "a connection from \(peer) refused: \(admission.pendingCount) wait to authenticate already")
				close(descriptor)
				return
			}
			oldest.end()
		}
		let connection = PhoneConnection(remote: self, descriptor: descriptor, peer: peer, admissionKey: key, arrivedOn: arrivedOn)
		connections[ObjectIdentifier(connection)] = connection
		connection.start()
	}

	// ---- Back-pressure towards the engine (#675's security read B, M2)

	/// The most that may wait to be written to the engine before pi² Remote stops reading from phones, and how far it
	/// must fall before it reads from them again: TCP then holds a phone back, not pi² Remote's memory.
	package static let engineBacklog = 8 * 1024 * 1024
	package static let engineDrained = 2 * 1024 * 1024
	private(set) var phonesPaused = false

	/// A phone's line went to the engine: if too much now waits, no phone is read until it has drained.
	func engineMayBeFull() {
		guard !phonesPaused, engine.pending > Self.engineBacklog else { return }
		phonesPaused = true
		Seldom.shared.say("backlog", "more than \(Self.engineBacklog / 1024 / 1024) MB wait for the engine: phones are not read until it drains")
		for connection in connections.values where connection.isAttached { connection.pauseReading() }
	}

	// ---- What phones may make pi² Remote hold (#675's security read B, M1b)

	/// The most attached connections one device keeps: a phone moving between paths has two for a moment; a third ends
	/// the oldest, whose session keeps its resume window.
	package static let attachedPerDevice = 2
	/// What all phones' outgoing queues may hold together. One connection may hold up to 128 MB waiting and one line of
	/// the engine's longest (64 MB) on top; this lets one such phone, and every other phone's ordinary traffic, through,
	/// and bounds what slow readers can make the Mac hold, together, at a quarter of a gigabyte. Over it, the connection
	/// with the most waiting is ended (its session keeps what a resume needs).
	package static let queueBudget = 256 * 1024 * 1024

	/// Of `items` and what each holds, the one to let go when together they hold more than `budget`: the largest.
	package static func overBudget<T>(_ items: [(T, Int)], budget: Int) -> T? {
		guard items.reduce(0, { $0 + $1.1 }) > budget else { return nil }
		return items.max(by: { $0.1 < $1.1 })?.0
	}

	func keepWithinBudget() {
		let held = connections.values.map { ($0, $0.queued) }
		guard let largest = Self.overBudget(held, budget: Self.queueBudget) else { return }
		log("phones leave more than \(Self.queueBudget / 1024 / 1024) MB unread in all; the one leaving the most is closed")
		largest.end()
	}

	/// A device's newest connections are kept; older ones past `attachedPerDevice` end.
	private func keepNewest(of device: DeviceID) {
		let attached = connections.values.filter { $0.isAttached && $0.device == device }.sorted { $0.attachedAt > $1.attachedAt }
		for old in attached.dropFirst(Self.attachedPerDevice) {
			log("device \(device) has more than \(Self.attachedPerDevice) connections attached; the oldest is closed")
			old.end()
		}
	}

	private func engineDrained() {
		guard phonesPaused else { return }
		phonesPaused = false
		for connection in connections.values { connection.resumeReading() }
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
		// The device and the home key are kept together before the phone is told (#845). The first pairing's key was made
		// and kept when its claim went to the engine (`keyForClaim`), so a key that cannot be kept refuses the claim while
		// the window is open; one is made here only if a write failed since.
		var list = devices
		list.removeAll { $0.id == device.id }
		list.append(device)
		let connection = event["claim"]?.stringValue.flatMap { claims.removeValue(forKey: $0) }
		guard keep(list, homeKey: homeKey ?? HomeKey.random()), let homeKey else {
			// Not on pi² Remote's own list, so never attached. The engine has paired it already: it is asked to take the
			// pairing back (`remote.pairUnkept`, #887), which it does only for this device, the last it sent `paired` for,
			// within a minute; and the phone is told the Mac could not save it (#881).
			log("paired device \(device.id) could not be kept on pi² Remote's own list; the engine is asked to take the pairing back")
			engine.request("remote.pairUnkept", .object([("device", .string(device.id.text))])) { result in
				if case let .failure(refusal) = result { log("the engine did not take back the pairing of device \(device.id): \(refusal)") }
			}
			connection?.refusePairing(.unsaved)
			return
		}
		log("paired device \(device.id): added to pi² Remote's own list")
		guard let connection else { return }
		let answer = event["paired"]
		guard let pairingText = answer?["pairing"]?.stringValue, let pairingID = PairingID(pairingText), let name = answer?["name"]?.stringValue,
		      case let .array(items)? = answer?["addresses"],
		      let line = try? Paired(device: device.id, pairing: pairingID, name: name, addresses: items.compactMap(\.stringValue), homeKey: homeKey)
		else {
			log("paired: the answer for the phone is not one RemoteKit writes; its channel is closed")
			connection.end()
			return
		}
		connection.sendLine(ControlLine.paired(line).line)
		connection.end()
	}

	/// The first pairing's claim is about to go to the engine: its home key is made and kept now, with the list as it is,
	/// so that a key that cannot be kept refuses the claim while the window is still open (`remote.pairRefused`), and
	/// the engine never pairs a device whose phone could not be given the key (#675's security read, S2). It is not
	/// advertised while no device holds it, and is given only in `paired`; a claim that does not end paired leaves it for
	/// the next one. False if it could not be kept.
	func keyForClaim() -> Bool {
		if homeKey != nil { return true }
		return keep(devices, homeKey: HomeKey.random())
	}

	private func revoke(_ device: DeviceID) {
		// Dropped at once, and kept with a new home key in one write before anything else (`KeptDevices`), so that no
		// restart can bring back the key the revoked phone holds; no key at all once no device is left (S3). A write that
		// fails leaves the list and the key as they were, the device still on the list, and `homeKey` nil: nothing is
		// advertised, and the next `start`, which no longer names the device, drops it and makes the new key.
		devices.removeAll { $0.id == device }
		pushes.forget(device)
		if keep(devices, homeKey: devices.isEmpty ? nil : HomeKey.random()), homeKey != nil { log("a new home key was made, after a revocation") }
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
		// The remaining phones attached now are sent the new key at once; the others at their next attach.
		for connection in connections.values where connection.isAttached { connection.sendHomeKey() }
	}

	/// Keeps `list` and `key` in one write (`KeptDevices`), and only then takes the key as the home key and advertises
	/// its tag, never the old one beside it. So while `homeKey` is not nil the vault holds exactly it and `devices`, and
	/// every phone given the key is on the list kept beside it. A write that fails leaves `homeKey` nil: nothing is
	/// advertised and no key sent until one is kept. `devices` becomes `list` once kept; a caller that drops a device
	/// whatever happens drops it first.
	@discardableResult
	private func keep(_ list: [ListedDevice], homeKey key: HomeKey?) -> Bool {
		let kept: Bool
		do {
			try vault.keep(KeptDevices(devices: list, homeKey: key))
			devices = list
			homeKey = key
			kept = true
		} catch {
			homeKey = nil
			log("pi² Remote's own list of devices and the home key could not be kept: \(error); nothing is advertised until they are")
			kept = false
		}
		advertise()
		return kept
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
			let resumed = session.resume(on: connection, received: received ?? 0)
			keepNewest(of: device)
			return resumed
		}
		// A fresh session; a session the phone asked to resume and the engine did not is gone.
		let session = Session(remote: self, id: id, device: device)
		sessions[id.text] = session
		session.attach(connection)
		keepNewest(of: device)
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
