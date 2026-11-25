import CryptoKit
import Dispatch
import Foundation
import RemoteKit

// pi² Remote's end of the relay (docs/iphone.md 5.3, 3.3, 3.6, 6.5; #678's second part): RemoteKit's relay client
// (`RelayClient`, docs/remotekit.md "The relay's client") held as the pairing's Mac, and what pi² Remote does with it.
//
// - It registers a pairing when the engine asks (`register`), with the relay key of that relay's address, and binds the
//   pairing to that address: the pairing's id is never shown to another relay.
// - It keeps one connection while remote access and **Reach through pi²'s relay** are on, which the client opens again
//   with backoff; it stops only on a refusal that trying again would not change, and then starts again on the person's
//   action (the switch off and on), after an hour, or at the next launch.
// - The relay is not trusted. Every message is read strictly by the client, whose bounds hold what it is sent; nothing
//   the relay says changes the list of devices, the pairing or a key (docs/pi2-remote.md, "The relay's word"); its
//   lists and notices are hints, logged or shown; and every byte it passes from a phone goes to a `PhoneConnection`,
//   the one code path the home path's bytes take, with the same handshake, attach, limits and budgets.
// - Join windows: the relay's is opened with the engine's (`openJoin`, the token's hash) and closed after the device
//   is added (`addDevice` before `closeJoin`, relay/README.md); the device key and App Attest key id it lists are pi²
//   Remote's own list's, the engine's verified claim's.
// - The list of devices kept in step: at each `ready`, a device the relay lists that pi² Remote's own list does not is
//   removed there; one the list has and the relay does not is a hint, logged. A revocation removes the device's slot.
// - A phone's leave (#929): a `left` is the relay's word until the phone's notice verifies against the device key on pi²
//   Remote's own list; only then is the engine told (`remote.left`), which checks it again and revokes the device.
// - The mailbox both ways: what phones left is taken, opened and verified with the device's keys on pi² Remote's own
//   list, and handed to the engine (`remote.mailboxIn`), which checks it again; the relay is told `took` only for what
//   the engine kept or certainly refused, and for what certainly is not genuine (#806, #876). What the engine leaves
//   for a phone (`mailboxOut`) is signed with the identity key, sealed to the device's record key on the list and put.
// - Pushes (#689, #935): the hand-over (`PushHandOver.relay`) has this client from the relay's `ready`, which proves
//   this pairing's Mac on its socket, until that socket goes (`connecting`, `disconnected`), the client stops
//   (`stopped`) or is stopped (`stopClient`); at any other moment every push is answered `push-later`.
// - What it can do is told to the engine as `remote.state`'s `relay` (6.5): off (none wanted), unavailable and why,
//   connecting, ready, down until a time, or stopped and the relay's word for it.

/// What the engine is told of the relay path (`remote.state`'s `relay`; docs/iphone.md 6.5): whether the person wants
/// none, what keeps it from running, or how it runs. The relay's own words in it are its claims.
enum RelayPathState: Equatable {
	/// **Reach through pi²'s relay** is off: home and private networks only, as the person chose.
	case off
	/// It cannot run, and why: no relay key, no pairing registered at this relay, an address it does not connect to.
	case unavailable(String)
	case connecting
	case ready
	/// The socket dropped; the client connects again at `retryAt` (ms since 1970).
	case down(String, retryAt: Int64)
	/// The client stopped on a refusal trying again would not change, if the relay says true.
	case stopped(String)

	func json(anotherMacAt: Int64?) -> JSONValue {
		var members: [(String, JSONValue)]
		switch self {
		case .off: members = [("available", .bool(false)), ("state", .string("off")), ("why", .string("Reach through pi²'s relay is off: home and private networks only."))]
		case let .unavailable(why): members = [("available", .bool(false)), ("state", .string("unavailable")), ("why", .string(Log.oneLine(why)))]
		case .connecting: members = [("available", .bool(false)), ("state", .string("connecting"))]
		case .ready: members = [("available", .bool(true)), ("state", .string("ready"))]
		case let .down(why, retryAt): members = [("available", .bool(false)), ("state", .string("down")), ("why", .string(why)), ("retryAt", .integer(retryAt))]
		case let .stopped(why): members = [("available", .bool(false)), ("state", .string("stopped")), ("why", .string(why))]
		}
		if let anotherMacAt { members.append(("anotherMacAt", .integer(anotherMacAt))) }
		return .object(members)
	}
}

extension Admission {
	/// What the relay path's limits count a slot as: the slot's own 16 bytes, read as an address that is counted by
	/// itself (the relay path's `Admission` takes every address as on the Mac's own link). The relay names slots, so a
	/// relay that names new ones meets the limits for all (eight waiting, 600 unknown first messages a minute), as a
	/// stranger with many addresses does on the home path; a slot that is a phone's meets its own.
	static func relaySource(_ slot: DeviceID) -> IPAddress {
		.v6(Array(Base64URL.decode(String(slot.text.dropFirst(4)), count: 16) ?? Data(count: 16)))
	}

	/// The relay path's own limits: the home listener's numbers, with each slot counted by itself.
	static func forRelay() -> Admission { Admission(localPrefixes: [(.v6([UInt8](repeating: 0, count: 16)), 0)]) }
}

/// The pairing pi² Remote registered at a relay, and that relay's address, kept with its list of devices
/// (`KeptDevices`): the pairing's id is shown to that relay alone (#678's security read).
package struct RelayRegistration: Sendable, Equatable {
	package let pairing: PairingID
	package let relay: String

	package init(pairing: PairingID, relay: String) {
		self.pairing = pairing
		self.relay = relay
	}
}

final class RelayEnd: @unchecked Sendable {
	private unowned let remote: Remote
	/// The relay path's limits before a channel authenticates, apart from the home listener's: a relay cannot use up the
	/// home path's, nor the home path the relay's.
	let admission = Admission.forRelay()
	private let connector: any RelayConnector = URLSessionRelayConnector()

	/// The Mac's build, as the relay compares it with its minimum: this bundle's `CFBundleVersion`, which build.sh writes.
	static let build: RelayBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(RelayBuild.init) ?? RelayBuild("1")!
	/// How long a client stopped on a refusal waits before it starts again by itself.
	static let restartAfterStop: TimeInterval = 3600
	/// The most the Mac sends the relay in a second, below its limits for an end (6.6: 100 messages, 2 MB), so that a
	/// long engine line to a phone is paced rather than closed with `busy`.
	static let messagesPerSecond = 80
	static let bytesPerSecond = 1_500_000
	/// How often the relay's word that another Mac tried to connect is told to the engine, at most, in ms (#921's read).
	static let anotherMacEvery: Int64 = 60_000

	private struct Target: Equatable {
		let url: URL
		let address: String
		let pairing: PairingID
		let key: Data
	}

	private var client: RelayClient?
	private var running: Target?
	/// A client stopped on a refusal for this target: not started again until the person's action, an hour, or the next
	/// launch.
	private var stoppedFor: Target?
	private var restart: DispatchWorkItem?
	private var generation = 0
	private(set) var isReady = false
	private var reported: RelayPathState?
	private var anotherMacAt: Int64?
	private var registering = false

	/// The link of each slot with a channel on the relay path.
	private var links: [DeviceID: RelayLink] = [:]
	private var outgoing: [(link: RelayLink, slot: DeviceID, bytes: Data)] = []
	private var sending = false
	/// What waits for the queued bytes to have gone (`afterSent`).
	private var whenSent: [() -> Void] = []
	private var paceStart = ContinuousClock.now
	private var paceMessages = 0
	private var paceBytes = 0
	private var paceScheduled = false

	private struct Request: @unchecked Sendable {
		let what: String
		let run: @Sendable (RelayClient) async throws -> Void
		let done: (Error?) -> Void
	}
	private var requests: [Request] = []
	private var requesting = false

	private struct Window {
		let tokenHash: Data
		let expires: Int64
		var sent: Bool
	}
	private var window: Window?
	private var deferredClose: DispatchWorkItem?
	/// Devices paired while the relay was away, to be listed there while their window lasts.
	private var pendingAdds: [DeviceID: (device: ListedDevice, until: Int64)] = [:]

	private struct Leaving {
		let device: DeviceID
		let id: ItemID
		let item: Data
		let state: Bool
		let at: TimeInterval
	}
	/// What the engine left for phones, waiting to be put; bounded, and kept for this run only.
	private var outbox: [Leaving] = []
	private var putting = false
	static let outboxMost = 256
	static let outboxBytesMost = 4 * 1024 * 1024
	private var taking = false
	private var takeAgain = false

	init(remote: Remote) { self.remote = remote }

	private var now: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

	// ---- Whether it runs, and what the engine is told

	/// Starts, keeps or stops the client as the switches, the relay's address, its key and the pairing say. Called once
	/// the engine has taken `remote.hello`, and whenever one of them changes.
	func reconsider() {
		switch wanted() {
		case let .failure(state):
			stopClient()
			stoppedFor = nil
			restart?.cancel()
			restart = nil
			report(state.state)
		case let .success(target):
			if running == target, client != nil { return }
			if stoppedFor == target { return }
			stopClient()
			stoppedFor = nil
			start(target)
		}
	}

	private struct Unwanted: Error { let state: RelayPathState }

	private func wanted() -> Result<Target, Unwanted> {
		guard remote.switches.on, remote.switches.relay else { return .failure(Unwanted(state: .off)) }
		guard let url = URL(string: remote.relay), RelayEndpoint.isAllowed(url) else {
			return .failure(Unwanted(state: .unavailable("the relay's address is not one pi² Remote connects to (wss://, or ws:// to this Mac)")))
		}
		guard let key = remote.relayKey else {
			return .failure(Unwanted(state: .unavailable(remote.relayKeyProblem ?? "the relay key for this address could not be read or made; the relay path is off, home and direct carry on")))
		}
		guard let pairing = remote.pairing else { return .failure(Unwanted(state: .unavailable("no pairing yet: one is registered at the relay when the first iPhone pairs"))) }
		guard let registration = remote.registration, registration.pairing == pairing, registration.relay.utf8.elementsEqual(remote.relay.utf8) else {
			return .failure(Unwanted(state: .unavailable("this Mac's pairing was not registered at this relay by pi² Remote, and is shown to no other relay; home and direct carry on")))
		}
		return .success(Target(url: url, address: remote.relay, pairing: pairing, key: key.publicKey.rawRepresentation))
	}

	private func report(_ state: RelayPathState, force: Bool = false) {
		guard force || state != reported else { return }
		reported = state
		remote.engine.request("remote.state", .object([("relay", state.json(anotherMacAt: anotherMacAt))]))
	}

	// ---- The client

	private func start(_ target: Target) {
		guard let key = remote.relayKey else { return }
		let made: RelayClient
		do {
			made = try RelayClient(relay: target.url, role: .mac(target.pairing), build: Self.build, signer: RelaySigner(key), connector: connector)
		} catch {
			return report(.unavailable("the relay's client could not start: \(error)"))
		}
		generation += 1
		let generation = self.generation
		client = made
		running = target
		report(.connecting)
		log("the relay path: connecting as this pairing's Mac")
		let queue = remote.queue
		Task {
			for await event in made.events { queue.async { self.heard(event, generation) } }
		}
		Task { await made.start() }
	}

	private func stopClient() {
		remote.pushes.relay = nil
		guard let client else { return }
		generation += 1
		self.client = nil
		running = nil
		isReady = false
		dropRequests()
		endLinks()
		Task { await client.stop() }
	}

	private func heard(_ event: RelayEvent, _ generation: Int) {
		guard generation == self.generation else { return }
		switch event {
		case .connecting:
			isReady = false
			remote.pushes.relay = nil
			dropRequests()
			endLinks()
			if case .down = reported {} else { report(.connecting) }
		case let .macReady(info):
			isReady = true
			// The pushes go through this client from now until its socket goes (#935): only once the relay has proved this
			// pairing's Mac on it, and only the client of this generation, which is this pairing's at this relay.
			if let client { remote.pushes.relay = RelayClientPushes(client: client) }
			report(.ready)
			Seldom.shared.say("relay ready", "the relay path is ready")
			inStep(with: info)
			sendWindow()
			retryAdds()
			flushOutbox()
			if info.mail > 0 { take() }
		case let .data(from?, bytes):
			received(bytes, from: from)
		case .data(nil, _), .online, .offline, .macOnline, .deviceReady:
			// Presence is the relay's word, and nothing here needs it: a channel shows itself.
			break
		// The relay's word, each kind in the log at most once a minute under a kind of its own: a relay that repeats a notice
		// cannot wash pi² Remote's log, nor hide the home path's lines (#921's security read).
		case .phoneJoined:
			Seldom.shared.say("relay joined", "the relay says a phone joined the pairing window (its word: the channel and the engine decide)")
		case let .left(left):
			heardLeft(left)
		case .anotherMac:
			// Told to the engine at most once a minute, with the first time in that minute: each report is a `remote.state`, and
			// a `devices` event to the app.
			let at = now
			if let said = anotherMacAt, at - said < Self.anotherMacEvery { break }
			anotherMacAt = at
			Seldom.shared.say("relay anotherMac", "the relay says another copy of pi² Remote tried to connect as this Mac (its word)")
			report(reported ?? .ready, force: true)
		case let .held(device, until):
			Seldom.shared.say("relay held", "the relay says it held device \(device) off past a limit, until \(until) (its word)")
		case .mail:
			take()
		case let .disconnected(drop, retryAt):
			isReady = false
			remote.pushes.relay = nil
			dropRequests()
			endLinks()
			report(.down(Self.describe(drop), retryAt: retryAt))
		case let .stopped(reason):
			isReady = false
			remote.pushes.relay = nil
			dropRequests()
			endLinks()
			client = nil
			stoppedFor = running
			running = nil
			let why = Self.describe(reason)
			log("the relay path stopped: \(why); it starts again when Reach through pi²'s relay is turned off and on, in an hour, or at the next launch, and nothing is forgotten on the relay's word")
			report(.stopped(why))
			restart?.cancel()
			let again = DispatchWorkItem { [unowned self] in
				self.restart = nil
				self.stoppedFor = nil
				self.reconsider()
			}
			restart = again
			remote.queue.asyncAfter(deadline: .now() + Self.restartAfterStop, execute: again)
		}
	}

	static func describe(_ drop: RelayDrop) -> String {
		switch drop {
		case .lost: "the connection to the relay was lost"
		case let .busy(until): "the relay says this Mac is past a limit, until \(until)"
		case let .refused(why): "the relay refused, saying \(why.word)"
		case let .http(status): "the relay answered HTTP \(status)"
		case .unreadable: "the relay sent what pi² Remote does not read"
		case .quiet: "the relay did not answer in time"
		case .overflow: "the relay sent more than pi² Remote holds unread"
		}
	}

	static func describe(_ stop: RelayStop) -> String {
		switch stop {
		case .stopped: "stopped"
		case let .refused(why): "the relay refused, saying \(why.word)"
		case let .http(status): "the relay answered HTTP \(status)"
		case .cannotSign: "the relay key would not sign"
		}
	}

	// ---- Registering

	/// The engine has no pairing and asks for one (`register`, devices.ts's pairStart): registered at the relay in use,
	/// with that address's relay key, and bound to it. With the relay off, or in a development build whose relay cannot
	/// be reached, pi² Remote makes the pairing's id itself, as a local relay would, so that the home path pairs; that
	/// pairing is registered at no relay, so the relay path stays off for it.
	func register() {
		guard remote.pairing == nil, !registering else { return }
		let address = remote.relay
		guard remote.switches.relay else { return own("Reach through pi²'s relay is off") }
		guard let url = URL(string: address), RelayEndpoint.isAllowed(url), let key = remote.relayKey else {
			return failed("no relay this Mac can register at (its address or relay key)")
		}
		registering = true
		let queue = remote.queue
		let connector = self.connector
		Task {
			do {
				let pairing = try await RelayClient.register(relay: url, build: Self.build, relayKey: RelaySigner(key), connector: connector)
				queue.async { self.registered(pairing, at: address) }
			} catch {
				queue.async { self.failed("the relay did not register this Mac (\(error))") }
			}
		}
	}

	private func registered(_ pairing: PairingID, at address: String) {
		registering = false
		guard remote.pairing == nil, address.utf8.elementsEqual(remote.relay.utf8) else {
			return log("a pairing registered at a relay no longer in use was left")
		}
		remote.adopt(pairing: pairing, registration: RelayRegistration(pairing: pairing, relay: address))
		log("registered a pairing at the relay in use")
		remote.engine.request("remote.state", .object([("pairing", .string(pairing.text))]))
		reconsider()
	}

	private func failed(_ why: String) {
		registering = false
		#if PI2_DEVELOPMENT
		own(why)
		#else
		log("register: \(why); the engine is told the relay path is unavailable, and waits for a pairing until its own time runs out")
		report(.unavailable(why))
		#endif
	}

	/// A pairing's id made here, registered at no relay: for the home path alone.
	private func own(_ why: String) {
		guard remote.pairing == nil else { return }
		let made = PairingID.random()
		remote.adopt(pairing: made, registration: nil)
		log("register: \(why); pi² Remote made the pairing's id itself, for the home path alone")
		remote.engine.request("remote.state", .object([("pairing", .string(made.text))]))
		reconsider()
	}

	// ---- The relay's requests, one at a time, only while ready

	private func request(_ what: String, _ run: @escaping @Sendable (RelayClient) async throws -> Void, done: @escaping (Error?) -> Void = { _ in }) {
		guard isReady else { return done(RelayClientError.notConnected) }
		requests.append(Request(what: what, run: run, done: done))
		nextRequest()
	}

	private func nextRequest() {
		guard !requesting, isReady, let client, !requests.isEmpty else { return }
		let request = requests.removeFirst()
		requesting = true
		let generation = self.generation
		let queue = remote.queue
		Task {
			let failure: Error?
			do {
				try await request.run(client)
				failure = nil
			} catch {
				failure = error
			}
			queue.async {
				guard generation == self.generation else { return request.done(RelayClientError.disconnected) }
				self.requesting = false
				// At most once a minute for each request's kind: a relay that refuses every request cannot wash the log.
				if let failure { Seldom.shared.say("relay request \(request.what)", "the relay's \(request.what): \(failure)") }
				request.done(failure)
				self.nextRequest()
			}
		}
	}

	/// The socket went: what waited is told so; what still matters is asked again from what pi² Remote holds at the
	/// next `ready` (the window, the devices to add, the outbox).
	private func dropRequests() {
		let waiting = requests
		requests = []
		requesting = false
		for request in waiting { request.done(RelayClientError.disconnected) }
	}

	// ---- Join windows and the list of devices (3.3, 3.6)

	/// The engine opened a pairing window: the relay's too, for the token whose hash the engine worked out.
	func openJoin(tokenHash: Data?, expires: Int64) {
		deferredClose?.cancel()
		deferredClose = nil
		guard let tokenHash, tokenHash.count == 32 else {
			window = nil
			return log("openJoin: no token hash for the relay; the window is open on the home path alone")
		}
		window = Window(tokenHash: tokenHash, expires: expires, sent: false)
		sendWindow()
	}

	private func sendWindow() {
		guard let open = window, !open.sent, isReady, open.expires > now else { return }
		window?.sent = true
		request("openJoin", { try await $0.openJoin(tokenHash: open.tokenHash, expires: open.expires) }) { [unowned self] error in
			if error != nil, self.window?.tokenHash == open.tokenHash { self.window?.sent = false }
		}
	}

	/// The engine closed its window. A claim with the engine waits for `paired`, whose `addDevice` must reach the relay
	/// before its window closes and drops the joined slots: then the relay's window closes after it, or 30 seconds on.
	func closeJoin(claimWaiting: Bool) {
		let had = window != nil
		window = nil
		guard had else { return }
		deferredClose?.cancel()
		guard claimWaiting else { return sendClose() }
		let later = DispatchWorkItem { [unowned self] in self.sendClose() }
		deferredClose = later
		remote.queue.asyncAfter(deadline: .now() + PhoneConnection.answerAfterCloseJoin, execute: later)
	}

	/// A claim was answered: the relay's window, if its closing waited, closes now, once what the channels queued has gone,
	/// so that a refused claim's `pairRefused` reaches its phone before the relay drops the phone's joined slot.
	func claimAnswered() {
		guard deferredClose != nil else { return }
		afterSent { [unowned self] in if self.deferredClose != nil { self.sendClose() } }
	}

	private func sendClose() {
		deferredClose?.cancel()
		deferredClose = nil
		request("closeJoin", { try await $0.closeJoin() })
	}

	/// The engine paired `device` and it is on pi² Remote's own list: listed at the relay with the keys of the engine's
	/// verified claim (never a `joined` notice's), before the relay's window closes. A pairing channel on the relay
	/// (`link`) goes on under the engine's id once it is added; `then` runs after the relay answered (the `paired` line
	/// then goes to that id), at once if nothing waits for it.
	func paired(_ device: ListedDevice, link: RelayLink?, then: @escaping () -> Void) {
		guard let attest = device.attestKeyId.flatMap(AttestKeyID.init) else {
			log("paired device \(device.id) has no App Attest key id the relay takes; it is not listed at the relay")
			claimAnswered()
			return then()
		}
		let until = max(now, window?.expires ?? 0) + 60_000
		request("addDevice", { try await $0.addDevice(device.id, deviceKey: device.deviceKey, attestKeyId: attest) }) { [unowned self] error in
			if let error {
				if case RelayClientError.refused = error {
					log("the relay did not list device \(device.id) (\(error)): it reaches this Mac by home and direct until it pairs again")
				} else {
					self.pendingAdds[device.id] = (device, until)
				}
			} else {
				self.pendingAdds[device.id] = nil
				if let link { self.move(link, to: device.id) }
			}
			self.claimAnswered()
			then()
		}
	}

	private func retryAdds() {
		for (id, pending) in pendingAdds {
			guard pending.until > now, remote.listed(id) != nil else {
				pendingAdds[id] = nil
				continue
			}
			paired(pending.device, link: nil) {}
		}
		if deferredClose != nil, pendingAdds.isEmpty { sendClose() }
	}

	/// A revoked device's slot, mailbox and push token go at the relay (3.6 step 3), once what pi² Remote queued for its
	/// socket has gone, the signed `revoked` line among it: the relay closes the phone's socket as it removes it. If the
	/// relay is away, the next `ready` finds the device listed there and not on pi² Remote's own list, and removes it then.
	func removeDevice(_ device: DeviceID) {
		pendingAdds[device] = nil
		outbox.removeAll { $0.device == device }
		afterSent { [unowned self] in self.request("removeDevice", { try await $0.removeDevice(device) }) }
	}

	/// Runs `then` once the channels' bytes queued now have gone to the relay's socket.
	private func afterSent(_ then: @escaping () -> Void) {
		guard isReady, sending || !outgoing.isEmpty else { return then() }
		whenSent.append(then)
	}

	/// The relay's list against pi² Remote's own, which is the truth: what the relay lists and the list does not is
	/// removed there; what the list has and the relay does not is the relay's word, logged.
	private func inStep(with info: RelayMacReady) {
		let ours = Set(remote.devices.map(\.id))
		var removed = 0
		for listed in info.devices where !ours.contains(listed.device) && removed < 64 {
			removed += 1
			request("removeDevice", { try await $0.removeDevice(listed.device) })
		}
		if removed > 0 { Seldom.shared.say("relay listed", "the relay listed \(removed) device(s) pi² Remote's own list does not have: removed there") }
		let theirs = Set(info.devices.map(\.device))
		let missing = remote.devices.filter { !theirs.contains($0.id) && pendingAdds[$0.id] == nil }.count
		if missing > 0 { Seldom.shared.say("relay unlisted", "\(missing) device(s) on pi² Remote's own list are not listed at the relay, it says: they reach this Mac by home and direct until they pair again") }
		// The relay's client reads at most a few of these (relay/README.md: the record holds five), each checked as one `left`.
		for left in info.left { heardLeft(left) }
	}

	// ---- A phone's leave (3.6; #813, #929)

	/// Devices whose verified leave is with the engine, not yet answered: the same leave again meanwhile, in whatever form
	/// of its signature, is neither checked nor sent again.
	private var leaving: Set<DeviceID> = []

	/// A device the relay says left, now or while the Mac was away. The relay's word alone, until the phone's own notice
	/// verifies (`RelayLeft.verified`) against this pairing's id, the Mac's identity key and **the device key on pi²
	/// Remote's own list**, the engine's verified claim's, never a key the relay named (`joined`) nor the device id taken
	/// on trust: a device not on the list is a hint, with no check. Only a `RelayVerifiedLeave` goes to the engine, as
	/// `remote.left { device, at, notice }`, which checks the notice again against its own record and revokes the device
	/// as unpaired on the phone; the engine's `revoke` then drops it here, as any revocation does.
	///
	/// What a relay can make of it: at most one signature check for each `left` it sends that names a device on the list,
	/// none for any other; a line in the log for each kind of what it said, at most once a minute (a hint, a notice that
	/// does not verify, the engine's refusal), and one for each device on the list whose leave verified; nothing to the
	/// engine, and so no `devices` event to the app, but a leave that verified (remotekit.md, "The leave notice").
	private func heardLeft(_ left: RelayLeft) {
		guard let listed = remote.listed(left.device), let pairing = remote.pairing else {
			// The device's id alone: never the notice, which only a check against its key may read.
			return Seldom.shared.say("relay left", "the relay says device \(left.device) left it, a device not on pi² Remote's own list: its word alone, so nothing is revoked or forgotten")
		}
		guard !leaving.contains(listed.id) else { return }
		guard let leave = left.verified(pairing: pairing, identityKey: remote.keys.identity.publicKey, deviceKey: listed.deviceKey, now: now) else {
			return Seldom.shared.say("relay left not verified", "the relay says device \(left.device) left it, with a notice its device key did not sign for this pairing and this Mac, or dated ahead of this Mac's clock: its word alone, so nothing is revoked")
		}
		leaving.insert(leave.device)
		// At most once a minute for each device on the list: a relay that repeats a genuine leave cannot wash the log.
		Seldom.shared.say("relay left verified \(leave.device)", "device \(leave.device) unpaired itself on the phone: its leave, signed by its device key on pi² Remote's own list for this Mac, verified; the engine is told (remote.left)")
		let params = JSONValue.object([("device", .string(leave.device.text)), ("at", .integer(leave.at)), ("notice", .string(Base64URL.encode(leave.notice)))])
		remote.engine.request("remote.left", params) { [unowned self] result in
			self.leaving.remove(leave.device)
			if case let .failure(why) = result { Seldom.shared.say("relay left refused", "the engine did not take device \(leave.device)'s leave: \(why)") }
		}
	}

	// ---- Channels on the relay path: the same `PhoneConnection` as on TCP

	/// Whether a message of this length starts a channel: a connection's first message (48 bytes), or a pairing's (96)
	/// while a window is open. A phone pads every frame of a channel to 256 bytes (remotekit.md), so its transport
	/// messages are never either length.
	private func startsChannel(_ length: Int) -> Bool {
		length == ChannelHandshake.connectionFirstMessageLength || (length == 96 && remote.openWindow != nil)
	}

	/// Bytes the relay passed on under `slot`: to that slot's channel, or the first message of a new one, which ends the
	/// slot's old channel silently (the phone left it; its session keeps the resume window). A slot is the relay's word:
	/// a connection's handshake is tried against that device's key alone.
	private func received(_ bytes: Data, from slot: DeviceID) {
		if let link = links[slot], !link.isClosed {
			guard startsChannel(bytes.count) else { return link.received(bytes) }
			// The phone left that channel: nothing still queued on it goes, so that the new one's answer comes first.
			outgoing.removeAll { item in
				guard item.link === link else { return false }
				link.sent(item.bytes.count)
				return true
			}
			link.close()
		}
		guard startsChannel(bytes.count) else {
			return Seldom.shared.say("relay stray", "bytes from the relay for no channel, and not a first message; left")
		}
		let key = Admission.relaySource(slot)
		guard admission.admit(key: key) == .taken else {
			return Seldom.shared.say("relay pending", "a first message from the relay refused: \(admission.pendingCount) wait to authenticate on the relay path already")
		}
		let link = RelayLink(relay: self, slot: slot)
		links[slot] = link
		let connection = PhoneConnection(remote: remote, link: link, route: .relay(slot), admission: admission, admissionKey: key)
		remote.connections[ObjectIdentifier(connection)] = connection
		connection.start()
		link.received(bytes)
	}

	private func move(_ link: RelayLink, to device: DeviceID) {
		if links[link.slot] === link { links.removeValue(forKey: link.slot) }
		link.moved(to: device)
		if !link.isClosed { links[device] = link }
	}

	/// A link ended: its slot has no channel.
	func closed(_ link: RelayLink) {
		if links[link.slot] === link { links.removeValue(forKey: link.slot) }
	}

	/// The socket went: every channel on it ends, as a TCP connection that drops; their sessions keep the resume window.
	private func endLinks() {
		let ending = Array(links.values)
		links = [:]
		for link in ending { link.close() }
		let queued = outgoing
		outgoing = []
		for item in queued { item.link.sent(item.bytes.count) }
		pump()
	}

	/// A Noise message to a phone, in order with every other on the socket.
	func send(_ bytes: Data, from link: RelayLink) {
		guard isReady else { return link.sent(bytes.count) }
		outgoing.append((link, link.slot, bytes))
		pump()
	}

	private func pump() {
		if !sending, outgoing.isEmpty || !isReady, !whenSent.isEmpty {
			let waiting = whenSent
			whenSent = []
			for then in waiting { then() }
		}
		guard !sending, isReady, let client, !outgoing.isEmpty else { return }
		let clock = ContinuousClock.now
		if clock - paceStart >= .seconds(1) {
			paceStart = clock
			paceMessages = 0
			paceBytes = 0
		}
		guard paceMessages < Self.messagesPerSecond, paceBytes < Self.bytesPerSecond else {
			guard !paceScheduled else { return }
			paceScheduled = true
			let left = (paceStart + .seconds(1) - clock).components
			let wait = Double(left.seconds) + Double(left.attoseconds) / 1e18
			remote.queue.asyncAfter(deadline: .now() + max(0.001, wait)) { [unowned self] in
				self.paceScheduled = false
				self.pump()
			}
			return
		}
		let next = outgoing.removeFirst()
		paceMessages += 1
		paceBytes += next.bytes.count
		sending = true
		let generation = self.generation
		let queue = remote.queue
		Task {
			let ok = (try? await client.send(next.bytes, to: next.slot)) != nil
			queue.async {
				self.sending = false
				next.link.sent(next.bytes.count)
				if !ok, generation == self.generation { next.link.close() }
				self.pump()
			}
		}
	}

	// ---- The mailbox: what phones left (5.3, 4.3; #806)

	/// The least time between the starts of two takes (#921's security read): a relay that says `mail` after every `took`
	/// cannot make pi² Remote open 200 items back to back, only 12 takes and 2,400 items a minute at most. A phone loses
	/// nothing a working relay gives it: one take brings everything that waits (the Mac's mailbox holds 200 items, 50 from
	/// any one phone), a `mail` during a take or this wait is taken at its end, and the mailbox carries what a phone leaves
	/// while the Mac is away, which a few seconds do not change.
	static let takeEvery: Duration = .seconds(5)
	private var lastTake: ContinuousClock.Instant?
	private var takeWaits = false

	/// Takes what waits in the Mac's mailbox, one take at a time, no sooner than `takeEvery` after the one before began.
	func take() {
		guard isReady, let client else { return }
		guard !taking else {
			takeAgain = true
			return
		}
		if let lastTake, ContinuousClock.now - lastTake < Self.takeEvery {
			guard !takeWaits else { return }
			takeWaits = true
			let wait = Self.takeEvery - (ContinuousClock.now - lastTake)
			remote.queue.asyncAfter(deadline: .now() + .milliseconds(Int(wait / .milliseconds(1)) + 1)) { [unowned self] in
				self.takeWaits = false
				self.take()
			}
			return
		}
		lastTake = .now
		taking = true
		let queue = remote.queue
		Task {
			do {
				_ = try await client.take { taken in await self.keep(taken, client: client) }
			} catch {
				queue.async { Seldom.shared.say("relay take", "the relay's take: \(error)") }
			}
			queue.async {
				self.taking = false
				if self.takeAgain {
					self.takeAgain = false
					self.take()
				}
			}
		}
	}

	private enum Opened {
		case item(device: DeviceID, plaintext: JSONValue)
		/// Its seal does not open with this Mac's record key and the device's, its signatures do not verify with the
		/// device's keys on pi² Remote's own list, or it names a writer that is not on the list: it never will open.
		case notGenuine(String)
		/// What could pass later: nothing of the item's own.
		case later(String)
		/// Genuine, and more than a day old: the engine would refuse it, and a relay that kept it could hand it over again
		/// after the device's Face ID key changed. Taken, and never handed on.
		case expired
	}

	/// The oldest a phone's item is handed to the engine, in ms: the engine's own bound (`DAY`, for `ITEM_TOO_OLD`, in
	/// engine/src/devices.ts), and what the relay keeps an item for. pi2-remote-helper-check compares the two (Relayed.swift).
	static let itemOldest: Int64 = 86_400_000

	/// What a take brought, opened, verified and handed to the engine one item at a time; gives back what the relay may
	/// delete: what the engine kept or certainly refused, and what certainly is not genuine. An item the engine could
	/// not take now (remote access off, the device suspended, its store not writable) is left, and comes again at the
	/// next take until it expires at the relay.
	private func keep(_ taken: RelayTaken, client: RelayClient) async -> Set<ItemID> {
		var done = Set<ItemID>()
		var kept: [RelayMailItem] = []
		// Said once for the take, with how many, and each kind at most once a minute: a relay's items cannot wash the log.
		var notGenuine: (count: Int, last: String) = (0, "")
		var waiting: (count: Int, last: String) = (0, "")
		var expired = 0
		if let state = taken.state { done.insert(state.id) }
		for item in taken.items {
			switch await onQueue({ self.open(item) }) {
			case let .notGenuine(why):
				notGenuine = (notGenuine.count + 1, why)
				done.insert(item.id)
			case let .later(why):
				waiting = (waiting.count + 1, why)
			case .expired:
				expired += 1
				done.insert(item.id)
			case let .item(device, plaintext):
				if await handOn(item.id, from: device, plaintext) {
					done.insert(item.id)
					kept.append(item)
				}
			}
		}
		if !kept.isEmpty { await client.remember(kept) }
		await onQueue { [notGenuine, waiting, expired] in
			if notGenuine.count > 0 { Seldom.shared.say("relay items not genuine", "\(notGenuine.count) item(s) in the mailbox not genuine (the last: \(notGenuine.last)); the relay deletes them") }
			if waiting.count > 0 { Seldom.shared.say("relay items waiting", "\(waiting.count) item(s) in the mailbox wait (the last: \(waiting.last))") }
			if expired > 0 { Seldom.shared.say("relay items expired", "\(expired) item(s) in the mailbox more than a day old; the relay deletes them, and the engine is not given them") }
		}
		return done
	}

	private func open(_ item: RelayMailItem) -> Opened {
		guard case let .device(writer) = item.from else { return .notGenuine("not from a device") }
		guard let listed = remote.listed(writer) else { return .notGenuine("from no device on pi² Remote's own list") }
		guard let presence = listed.presenceKey else { return .notGenuine("its device has no presence key on pi² Remote's own list") }
		guard let pairing = remote.pairing else { return .later("no pairing") }
		let address = ItemAddress(pairing: pairing, reader: .mac, id: item.id)
		let request: RequestItem
		do {
			switch remote.keys.record {
			case let .software(key):
				request = try SealedItem.openRequest(item.item, at: address, readerKey: key, writer: writer, writerRecordKey: listed.recordKey, deviceKey: listed.deviceKey, presenceKey: presence)
			case let .enclave(key):
				request = try SealedItem.openRequest(item.item, at: address, readerKey: key, writer: writer, writerRecordKey: listed.recordKey, deviceKey: listed.deviceKey, presenceKey: presence)
			}
		} catch let error as RemoteKitError where error == RemoteKitError("request item", "no valid presence signature") {
			// Sealed and signed by the device, and not by the presence key on pi² Remote's own list: a new presence key the
			// person accepted on the Mac is not on the list until the engine's `presenceKey` event is taken there (#891). It
			// could pass then, so it is left, and expires at the relay if it never does.
			return .later("its presence signature is not the presence key's on pi² Remote's own list")
		} catch {
			return .notGenuine("its seal or its signatures do not hold")
		}
		guard now - request.at <= Self.itemOldest else { return .expired }
		guard let plaintext = try? JSON.parse(request.plaintext) else { return .notGenuine("not one JSON object") }
		return .item(device: writer, plaintext: plaintext)
	}

	/// `remote.mailboxIn`: the engine checks the item again (devices.ts, `checkRequestItem`) and handles it, and answers
	/// `taken` once it has kept or certainly refused it; an error is what could pass later.
	private func handOn(_ id: ItemID, from device: DeviceID, _ plaintext: JSONValue) async -> Bool {
		let params = JSONValue.object([("device", .string(device.text)), ("id", .string(id.text)), ("item", plaintext)])
		let result: Result<JSONValue, Refused> = await withCheckedContinuation { done in
			remote.queue.async { self.remote.engine.request("remote.mailboxIn", params) { done.resume(returning: $0) } }
		}
		switch result {
		case let .success(value): return value["taken"]?.boolValue == true
		case let .failure(why):
			await onQueue { Seldom.shared.say("relay items not taken", "the engine did not take an item from the mailbox now (\(why)); it comes again at the next take") }
			return false
		}
	}

	private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
		await withCheckedContinuation { done in remote.queue.async { done.resume(returning: work()) } }
	}

	// ---- The mailbox: what the Mac leaves for a phone (5.3)

	/// The engine's `mailboxOut`: an item for `device`, signed by the identity key, sealed to the device's record key on
	/// pi² Remote's own list (never a key the relay gave), and put in its mailbox; a `state` in place of the one before.
	/// Kept to put while the relay is away, within a bound, for this run.
	func leave(kind: String, number: Int64?, body: JSONValue, for device: DeviceID) {
		guard let listed = remote.listed(device), let pairing = remote.pairing else { return log("mailboxOut: no such device on pi² Remote's own list, or no pairing; left") }
		let id = ItemID.random()
		let sealed: Data
		do {
			let item = try MacItem.make(kind: kind, number: number, body: body, pairing: pairing, device: device, id: id, identity: remote.keys.identity)
			let address = ItemAddress(pairing: pairing, reader: .device(device), id: id)
			switch remote.keys.record {
			case let .software(key): sealed = try SealedItem.seal(item.plaintext, to: address, readerKey: listed.recordKey, writerKey: key)
			case let .enclave(key): sealed = try SealedItem.seal(item.plaintext, to: address, readerKey: listed.recordKey, writerKey: key)
			}
		} catch {
			return log("mailboxOut: an item for device \(device) could not be made or sealed (\(error)); left")
		}
		if kind == "state" { outbox.removeAll { $0.device == device && $0.state } }
		guard outbox.count < Self.outboxMost, outbox.reduce(0, { $0 + $1.item.count }) + sealed.count <= Self.outboxBytesMost else {
			return log("mailboxOut: more waits for the relay than pi² Remote holds; an item for device \(device) was left")
		}
		outbox.append(Leaving(device: device, id: id, item: sealed, state: kind == "state", at: Date().timeIntervalSince1970))
		flushOutbox()
	}

	private func flushOutbox() {
		outbox.removeAll { Date().timeIntervalSince1970 - $0.at > 23 * 3600 }
		guard isReady, !putting, let next = outbox.first else { return }
		putting = true
		request("put", { client in
			if next.state {
				try await client.putState(next.item, id: next.id, for: next.device)
			} else {
				_ = try await client.put(next.item, id: next.id, to: .device(next.device))
			}
		}) { [unowned self] error in
			self.putting = false
			var gone = error == nil
			if case RelayClientError.refused? = error { gone = true }
			if case RelayClientError.invalid? = error { gone = true }
			guard gone else { return }
			self.outbox.removeAll { $0.id == next.id }
			self.flushOutbox()
		}
	}
}
