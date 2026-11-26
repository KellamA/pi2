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
	/// The longest line taken from an attached phone (#675's security read B, M2; #904): 72 MiB, room for a message with
	/// what the Mac's may carry, ten pictures at the engine's limit of 5 MiB each, written in base64 (about 67 MiB), and
	/// its text. Set on a channel only once the engine has taken its attach, made under the session's Face ID; until then,
	/// and on a pairing channel always, RemoteKit's 64 KiB holds. The engine caps what it takes from pi² Remote at this and
	/// 64 KiB (`EngineLink.maxLineToEngine`, `MAX_PHONE_LINE` in remote.ts), which pi2-remote-helper-check holds equal.
	package static let phoneLineLimit = 72 * 1024 * 1024

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
	/// Why there is no relay key for the relay in use, when there is none.
	private(set) var relayKeyProblem: String?
	package private(set) var pairing: PairingID?
	/// The pairing pi² Remote registered at a relay, and that relay's address, kept with the list of devices: the relay
	/// path runs only for that pairing at that address (#678).
	package private(set) var registration: RelayRegistration?
	/// The relay's end (`Relay/`, #678): the relay path's channels go to the same `PhoneConnection`s as the home path's.
	private(set) lazy var relayEnd = RelayEnd(remote: self)
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
		registration = kept.registration
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
		case "forgetPairing": forgetPairing(event)
		case "openJoin":
			guard let secret = event["secret"]?.stringValue.flatMap({ Base64URL.decode($0, count: 32) }), let expires = event["expires"]?.integerValue else {
				log("openJoin: not a pairing window; left")
				return
			}
			window = JoinWindow(secret: secret, expires: TimeInterval(expires) / 1000)
			log("a pairing window is open until \(Date(timeIntervalSince1970: TimeInterval(expires) / 1000))")
			relayEnd.openJoin(tokenHash: event["tokenHash"]?.stringValue.flatMap { Base64URL.decode($0, count: 32) }, expires: expires)
		case "closeJoin":
			// Only channels with no claim yet: the engine says `closeJoin` before `paired` (devices.ts, pairConfirm).
			window = nil
			for connection in connections.values where connection.isPairingBeforeClaim { connection.windowClosed() }
			// A claim with the engine is answered right after: `paired` follows `closeJoin` within one save, `pairRefused`
			// at once. Neither within 30 seconds, and its channel ends, with no try counted.
			for connection in connections.values where connection.isClaim { connection.endIfUnanswered(after: PhoneConnection.answerAfterCloseJoin) }
			relayEnd.closeJoin(claimWaiting: connections.values.contains { $0.isClaim })
			log("the pairing window closed")
		case "paired": paired(event)
		case "pairRefused":
			if let claim = event["claim"]?.stringValue, let connection = claims.removeValue(forKey: claim) {
				log("a claim was refused on the Mac; its channel is closed")
				// The engine's word for the phone, when it gives one (#881); its words are never read.
				if let why = EngineWords.pairRefusal(event["reason"]?.stringValue) { connection.refusePairing(why) } else { connection.end() }
			}
			relayEnd.claimAnswered()
		case "revoke":
			if let text = event["device"]?.stringValue, let device = DeviceID(text) { revoke(device) }
		case "presenceKey": presenceKeyAccepted(event)
		case "push": pushes.take(event, pairing: pairing, devices: devices)
		case "sessionClosed":
			// The engine says `revoke` before it closes a revoked device's sessions (#776's 25), so the `revoked` line has
			// gone already: the channel ends at once.
			if let id = event["session"]?.stringValue, let session = sessions.removeValue(forKey: id) {
				session.closed()
				log("the engine closed session \(id)")
			}
		case "mailboxOut":
			// What the engine leaves for a phone in the relay's mailbox: sealed to the device on pi² Remote's own list.
			guard let text = event["device"]?.stringValue, let device = DeviceID(text), let item = event["item"], let kind = item["kind"]?.stringValue, let body = item["body"] else {
				log("mailboxOut: not an item for a device; left")
				return
			}
			relayEnd.leave(kind: kind, number: item["number"]?.integerValue, body: body, for: device)
		default:
			break
		}
	}

	/// The first event: what the engine has of the pairing and the switches. pi² Remote's own list of devices loses any
	/// device `start` does not list (revoked while pi² Remote was not running, 3.6), and gains none: a device is added
	/// to it only when the engine pairs it (`paired`), so a device written into the engine's store by hand is never
	/// attached (5.5). Each device it keeps takes its presence key from `start` (#891), as the engine has it: the engine is
	/// the judge of the presence key, which it changes only when the person accepts a new one on the Mac, and its
	/// `presenceKey` event is sent once and lost while pi² Remote is not running (Reach from an iPhone off, a crash) or
	/// when pi² Remote could not keep it. Read as the event's is (`presenceKeyAccepted`); an entry with no `presenceKey`
	/// leaves the key on the list as it is.
	private func start(_ event: JSONValue) {
		guard !started else { return }
		started = true
		relay = event["relay"]?.stringValue ?? ""
		switches = Switches(event["switches"])
		pairing = event["pairing"]?.stringValue.flatMap(PairingID.init)
		if let build = event["minimumBuild"]?.stringValue, Self.isBuild(build) { minimumBuild = build }
		var listed = Set<String>()
		var presence: [String: JSONValue] = [:]
		if case let .array(items)? = event["devices"] {
			for item in items {
				guard let id = item["id"]?.stringValue else { continue }
				listed.insert(id)
				if let key = item["presenceKey"] { presence[id] = key }
			}
		}
		let kept = devices.filter { listed.contains($0.id.text) }
		if kept.count != devices.count {
			log("\(devices.count - kept.count) device(s) the engine no longer lists were dropped from pi² Remote's own list")
			// Revoked while pi² Remote was not running, or by a revocation whose write failed: the key the device holds goes
			// too, before anything is advertised (nothing is until `applySwitches` below). A new one if a device is left,
			// none if not; if it cannot be kept, none at all, and nothing is advertised.
			devices = kept
			keep(devices, homeKey: devices.isEmpty ? nil : HomeKey.random())
		}
		var renewed = devices
		for (index, device) in renewed.enumerated() {
			guard let given = presence[device.id.text] else { continue }
			let key = given.stringValue.flatMap { PublicKeys.signingKey(fromBase64URL: $0) }
			guard !Self.samePresenceKey(key, device.presenceKey) else { continue }
			renewed[index] = device.withPresenceKey(key)
			log(key == nil
				? "start: the engine gave device \(device.id) a Face ID key pi² Remote cannot read; none of that device's attaches is taken until it has one it can"
				: "start: device \(device.id)'s Face ID key on pi² Remote's own list is now the one the engine has, accepted on the Mac")
		}
		if !renewed.elementsEqual(devices, by: { Self.samePresenceKey($0.presenceKey, $1.presenceKey) }) { keepPresenceKeys(renewed) }
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
		relayKeyProblem = unavailable
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
			// After the hello, which the engine takes `remote.state` only after: the relay path, as it can run now (a relay
			// key that cannot be read or made among the reasons it cannot).
			log("said hello: \(self.devices.count) device(s) on pi² Remote's own list, keys in \(self.vault.name)")
			self.relayEnd.reconsider()
		}
	}

	private func settings(_ event: JSONValue) {
		let before = relay
		relay = event["relay"]?.stringValue ?? relay
		switches = Switches(event["switches"])
		applySwitches()
		// Direct from any address turned off: the connections it let in end now, not when they next connect (M4). Their
		// sessions keep the resume window, for another path.
		for connection in connections.values {
			guard let peer = connection.peer, !admits(peer: peer, arrivedOn: connection.arrivedOn, kind: kind, direct: switches.direct) else { continue }
			log("a connection from outside the local and private ranges ended: Direct from any address is off")
			connection.windowClosed()
		}
		if relay.utf8.elementsEqual(before.utf8) {
			reportAddresses()
			relayEnd.reconsider()
		} else {
			log("the relay's address changed: its own relay key is told to the engine")
			// The old relay's client, and pushes with it, stop now, not once the engine answers the hello (#937).
			relayEnd.addressChanged()
			hello()
		}
	}

	/// The relay's `register`: the engine has no pairing yet (`RelayEnd.register`).
	private func register(_ event: JSONValue) {
		relayEnd.register()
	}

	/// The person started again on the Mac (#917, `devices.startAgain`): the engine revoked every device, each `revoke`
	/// sent before this on the same connection, and forgot its pairing, which this names. pi² Remote forgets it too, with
	/// its registration and what is left of the list (nothing, but a device the engine revoked while it was not told),
	/// in one write; the next `register` registers a new pairing at the relay now set. Nothing is sent to any relay.
	private func forgetPairing(_ event: JSONValue) {
		guard let named = event["pairing"]?.stringValue, let pairing, named.utf8.elementsEqual(pairing.text.utf8) else {
			return log("forgetPairing: not this Mac's pairing; left")
		}
		for device in devices.map(\.id) { revoke(device) }
		relayEnd.forgetPairing()
		window = nil
		self.pairing = nil
		registration = nil
		keep([], homeKey: nil)
		log("the pairing was forgotten, as the person asked on the Mac: the next pairing is registered anew at the relay in use")
		relayEnd.reconsider()
	}

	/// The pairing the relay gave, or pi² Remote made for the home path alone (`registration` nil), kept with the list of
	/// devices before the engine hears of it.
	func adopt(pairing made: PairingID, registration given: RelayRegistration?) {
		pairing = made
		registration = given
		guard given != nil else { return }
		do {
			try vault.keep(KeptDevices(devices: devices, homeKey: homeKey, registration: given))
		} catch {
			registration = nil
			log("the relay's pairing could not be kept with the list of devices (\(error)): the relay path stays off for it")
		}
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
			// The home path's connections alone: the relay's are not this switch's.
			for connection in connections.values where connection.peer != nil { connection.windowClosed() }
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
			let idle = connections.values.filter { $0.admission === admission && $0.waitingForFirstMessage && (admitted == .allFull || $0.admissionKey == key) }
			guard let oldest = idle.min(by: { $0.acceptedAt < $1.acceptedAt }) else {
				Seldom.shared.say("pending", "a connection from \(peer) refused: \(admission.pendingCount) wait to authenticate already")
				close(descriptor)
				return
			}
			oldest.end()
		}
		let link = TCPLink(descriptor: descriptor, queue: queue)
		let connection = PhoneConnection(remote: self, link: link, route: .tcp(peer, arrivedOn: arrivedOn), admission: admission, admissionKey: key)
		connections[ObjectIdentifier(connection)] = connection
		connection.start()
	}

	// ---- Back-pressure towards the engine (#675's security read B, M2)

	/// The most that may wait to be written to the engine before pi² Remote stops reading from phones, and how far it
	/// must fall before it reads from them again: TCP then holds a phone back, not pi² Remote's memory.
	package static let engineBacklog = 8 * 1024 * 1024
	package static let engineDrained = 2 * 1024 * 1024
	package private(set) var phonesPaused = false

	/// A phone's line went to the engine: if too much now waits, no phone is read until it has drained.
	func engineMayBeFull() {
		guard !phonesPaused, engine.pending > Self.engineBacklog else { return }
		phonesPaused = true
		heldBackSince = .now
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

	// ---- What phones' unfinished lines may make pi² Remote hold, and for how long (#908)

	/// What all phones' unfinished lines may hold together: each channel's line begun and not finished
	/// (`Channel.unfinishedLineLength`), on the home, direct and relay paths alike. Ten attached connections (two for each
	/// of five devices) could otherwise hold a line of 72 MiB each, 720 MiB; this lets three phones send ten pictures each
	/// at once. Over it, the connection holding the most is ended (its session keeps what a resume needs). It is checked
	/// after each frame is held, so it is passed by one frame at most, for a moment.
	package var lineBudget = 256 * 1024 * 1024
	/// How long an unfinished line may go with nothing more of it coming, on `lineClock`: a phone that lost its network
	/// halfway through a message frees what it sent within this and a sixth of it more (the watch's step). Changed (by
	/// the check alone), the watch takes its new step at once.
	package var lineStalledAfter: Duration = .seconds(30) {
		didSet { lineWatch?.schedule(deadline: .now() + lineWatchStep) }
	}
	/// The slowest link a line may come by, in bytes a second: a line may take `lineStalledAfter`, and as long again as
	/// what it holds takes at this rate, so that a piece every few seconds cannot keep a line held for ever. 64 KiB a
	/// second, about half a megabit: ten pictures (67 MiB) in about 18 minutes; a line of 72 MiB held 20 minutes at most.
	package var slowestLine = 64 * 1024

	/// Since when phones are held back by the engine's backlog, while they are, and for how long in all before.
	private var heldBackSince: SuspendingClock.Instant?
	private var heldBackFor: Duration = .zero
	private var lineWatch: DispatchSourceTimer?

	/// The clock an unfinished line is timed by: it stands still while phones are held back (`phonesPaused`), since a
	/// phone pi² Remote does not read cannot send the rest of its line; and, a suspending clock, while the Mac sleeps, when
	/// pi² Remote reads nothing either (the watch's `DispatchTime` does not run then).
	var lineClock: SuspendingClock.Instant {
		let now = SuspendingClock.now
		return now - heldBackFor - (heldBackSince.map { now - $0 } ?? .zero)
	}

	/// Whether `line` is overdue at `now`, and why: nothing more of it came for `stalledAfter`, or it has taken longer
	/// than `stalledAfter` and what it holds takes at `slowest` bytes a second.
	package static func overdue(_ line: UnfinishedLine, at now: SuspendingClock.Instant, stalledAfter: Duration, slowest: Int) -> LineOverdue? {
		if now - line.grew >= stalledAfter { return .stalled }
		if now - line.began > stalledAfter + .seconds(Double(line.held) / Double(max(1, slowest))) { return .tooSlow }
		return nil
	}

	/// Ends the connection holding the most of an unfinished line, when all of them together hold more than `lineBudget`.
	func keepLinesWithinBudget() {
		let held = connections.values.map { ($0, $0.unfinishedHeld) }
		guard let largest = Self.overBudget(held, budget: lineBudget) else { return }
		let who = largest.device.map { "device \($0)" } ?? "a phone not yet attached"
		Seldom.shared.say("line budget \(largest.device?.text ?? "")", "phones' unfinished lines held more than \(lineBudget / 1024 / 1024) MiB in all; the connection holding the most, of \(who), is closed")
		largest.end()
	}

	/// What all phones' channels hold of unfinished lines, together.
	package var linesHeld: Int { connections.values.reduce(0) { $0 + $1.unfinishedHeld } }

	/// A connection began holding a line: the watch runs while any does, every sixth of `lineStalledAfter`.
	func watchLines() {
		guard lineWatch == nil else { return }
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.setEventHandler { [unowned self] in self.checkLines() }
		timer.schedule(deadline: .now() + lineWatchStep)
		timer.resume()
		lineWatch = timer
	}

	/// A sixth of `lineStalledAfter`, read at each step.
	private var lineWatchStep: DispatchTimeInterval {
		let (seconds, attoseconds) = (lineStalledAfter / 6).components
		return .nanoseconds(max(1_000_000, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)))
	}

	/// Ends each connection whose unfinished line is overdue; the watch stops once no connection holds one.
	private func checkLines() {
		let now = lineClock
		var holding = false
		for connection in Array(connections.values) {
			guard let line = connection.unfinished else { continue }
			if let overdue = Self.overdue(line, at: now, stalledAfter: lineStalledAfter, slowest: slowestLine) {
				connection.endOverdue(overdue)
			} else {
				holding = true
			}
		}
		guard !holding else {
			lineWatch?.schedule(deadline: .now() + lineWatchStep)
			return
		}
		lineWatch?.cancel()
		lineWatch = nil
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
		if let since = heldBackSince { heldBackFor += .now - since }
		heldBackSince = nil
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
			// The claim is answered: the relay's window, and the phone's joined slot with it, go now, not 30 seconds on.
			relayEnd.claimAnswered()
			return
		}
		log("paired device \(device.id): added to pi² Remote's own list")
		// Listed at the relay too, with the keys of the engine's verified claim, before its window closes (3.3 step 8). A
		// phone pairing on the relay path is told once it is listed, under the engine's id; on the home path, at once.
		guard let connection else { return relayEnd.paired(device, link: nil) {} }
		let answer = event["paired"]
		guard let pairingText = answer?["pairing"]?.stringValue, let pairingID = PairingID(pairingText), let name = answer?["name"]?.stringValue,
		      case let .array(items)? = answer?["addresses"],
		      let line = try? Paired(device: device.id, pairing: pairingID, name: name, addresses: items.compactMap(\.stringValue), homeKey: homeKey)
		else {
			log("paired: the answer for the phone is not one RemoteKit writes; its channel is closed")
			connection.end()
			return relayEnd.paired(device, link: nil) {}
		}
		let tell = {
			connection.sendLine(ControlLine.paired(line).line)
			connection.end()
		}
		guard let link = connection.relayLink else {
			tell()
			return relayEnd.paired(device, link: nil) {}
		}
		relayEnd.paired(device, link: link, then: tell)
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
		relayEnd.removeDevice(device)
		// The remaining phones attached now are sent the new key at once; the others at their next attach.
		for connection in connections.values where connection.isAttached { connection.sendHomeKey() }
	}

	/// The engine's word that the person accepted a device's new presence key on the Mac (iphone.md 3.2, #891), sent
	/// before it closes that device's sessions, so taken here before their close is: the key goes on pi² Remote's own list
	/// in place of the old one, and its own check of an attach's presence signature takes the new key from now on and no
	/// longer the old. This event, and never the engine's answer to an offer, is what changes a presence key on the list.
	/// A key it cannot read (`PublicKeys.signingKey`, the one form the phone writes) leaves that device with no presence
	/// key, so that none of its attaches is taken here, and changes nothing of any other device. Kept with the list and
	/// the home key in one write, as every change of the list is; in memory whether or not that write succeeds.
	private func presenceKeyAccepted(_ event: JSONValue) {
		guard let text = event["device"]?.stringValue, let id = DeviceID(text), let index = devices.firstIndex(where: { $0.id == id }) else {
			log("presenceKey: the engine named no device on pi² Remote's own list; left")
			return
		}
		let key = event["presenceKey"]?.stringValue.flatMap { PublicKeys.signingKey(fromBase64URL: $0) }
		var list = devices
		list[index] = devices[index].withPresenceKey(key)
		if key == nil {
			log("presenceKey: the engine gave device \(id) a Face ID key pi² Remote cannot read; none of that device's attaches is taken until it has one it can")
		} else {
			log("device \(id)'s new Face ID key, accepted on the Mac, is on pi² Remote's own list")
		}
		keepPresenceKeys(list)
	}

	/// Whether two presence keys, or their absence, are the same.
	static func samePresenceKey(_ a: P256.Signing.PublicKey?, _ b: P256.Signing.PublicKey?) -> Bool {
		switch (a, b) {
		case (nil, nil): true
		case let (a?, b?): Bytes.constantTimeEqual(a.derRepresentation, b.derRepresentation)
		default: false
		}
	}

	/// `list`, whose presence keys changed, taken in memory whatever happens, then kept with the home key in one write.
	/// No home key means an earlier write failed: this write makes one, as a revocation's does, and the phones attached
	/// now are sent it.
	private func keepPresenceKeys(_ list: [ListedDevice]) {
		devices = list
		let makes = homeKey == nil && !list.isEmpty
		if keep(list, homeKey: makes ? HomeKey.random() : homeKey), makes {
			for connection in connections.values where connection.isAttached { connection.sendHomeKey() }
		}
	}

	/// A session the engine opened or resumed for an attach pi² Remote did not take after all (its presence signature is
	/// not the key on the list, #891): ended in the engine, and here if pi² Remote holds it.
	func endUnlisted(session id: SessionID, device: DeviceID) {
		if let session = sessions[id.text], session.device == device {
			end(session, why: "its new channel's presence signature is not the key on pi² Remote's own list")
		} else {
			engine.request("remote.sessionEnd", .object([("session", .string(id.text))]))
		}
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
			try vault.keep(KeptDevices(devices: list, homeKey: key, registration: registration))
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

/// A phone's line begun and not finished, as pi² Remote times it (#908): when it began and when it last grew, on
/// `Remote.lineClock`, and how much of it its channel holds.
package struct UnfinishedLine: Equatable, Sendable {
	package var began: SuspendingClock.Instant
	package var grew: SuspendingClock.Instant
	package var held: Int

	package init(began: SuspendingClock.Instant, grew: SuspendingClock.Instant, held: Int) {
		self.began = began
		self.grew = grew
		self.held = held
	}
}

/// Why an unfinished line ends its connection (`Remote.overdue`).
package enum LineOverdue: Equatable, Sendable {
	/// Nothing more of it came for `Remote.lineStalledAfter`.
	case stalled
	/// It came slower than `Remote.slowestLine`.
	case tooSlow
}
