
import CryptoKit
import Foundation

// The relay's client (iphone.md 5.3, 5.8, 6.6; relay/README.md, "The protocol"; #678): one end's socket to the relay,
// held open, proved, kept alive with pings, and opened again when it drops, with backoff and jitter, and after `busy`
// only once the relay said it may come back. pi² Remote holds one as the pairing's Mac and the phone one as its device;
// both register or join through it first. It reads every message strictly (`RelayIncoming.parse`), acts on none it has
// not read whole, and sends nothing the relay would refuse for its form.
//
// What it decides, and what it leaves to its user:
// - It never takes a refusal that means the pairing or the device is gone (`unknown-pairing`, `not-listed`, `removed`,
//   `left`, `deleted`, `signature`, `update-required`, `replaced`) for a dropped connection: it stops, and says why.
//   Everything else (the network, `busy`, `unavailable`, `timeout`, `too-many`, `another-mac`) it tries again.
// - Requests go one at a time, each answered before the next is sent: the relay names a request's answer by its kind
//   alone (`ok { what }`), so two in flight could not be told apart. Channel bytes are not requests and go at once.
// - A request whose socket drops before its answer throws `disconnected`: it may or may not have been carried out. A
//   `put` sent again with the same id is answered `exists` if the first one was stored, which `put` reports as such.
// - Items taken from the mailbox are checked against the ids its user remembered (`remember`) once it had opened,
//   verified and kept them, for 25 hours (`RelayItemMemory`), and a repeat is dropped: the relay can deliver an item
//   twice, and a Mac item that is not a state has no number to refuse it by. Only verified items are remembered, so
//   that items the relay made up cannot fill the memory. The memory is the user's to keep across launches.
// - A take is acknowledged (#806): the relay deletes nothing as it hands items over, and `take` tells it what this end
//   is done with (`took`) only once its user's closure has returned the ids it kept, or found certainly not genuine,
//   and the repeats the memory dropped. A closure that throws, or an app that ends first, acknowledges nothing, and the
//   relay hands the items over again at the next take; the memory drops those already kept, and they are acknowledged
//   then. Takes go one at a time, from the request to its `took`, so that two are never given the same items.
// - Everything the relay says is its word, not a fact: a hint to show, never a reason to forget, revoke, wipe or
//   register again (remotekit.md, "What a caller must and must not do"). A `left` carries the phone's own notice, which
//   its caller checks (`RelayLeft.verified`) before it takes the device for gone (#813).
// - What it reports is bounded (`RelayOptions.eventBuffer`): a caller that does not read cannot be made to hold what a
//   relay sends without end. Past the bound the socket is closed and opened again; repeated `mail` and presence
//   notices are sent once.

/// A key that proves an end at the relay: the Mac's relay key, or the phone's device key (iphone.md 3.2, 3.4). It signs
/// only `RelayProof`'s labelled text over a challenge of exactly 32 bytes, and a phone's the leave text for its Mac
/// (`RelayLeaveNotice`).
public struct RelaySigner: Sendable {
	public let publicKey: P256.Signing.PublicKey
	private let sign: @Sendable (Data) throws -> Data

	/// `sign` gives an ECDSA P-256 signature over SHA-256 of what it is given, as 64 raw bytes (r then s).
	public init(publicKey: P256.Signing.PublicKey, sign: @escaping @Sendable (Data) throws -> Data) {
		self.publicKey = publicKey
		self.sign = sign
	}

	public init<Key: StatementSigner & Sendable>(_ key: Key) {
		self.init(publicKey: key.publicKey, sign: { try key.sign($0) })
	}

	/// The signature for a `proof` or a `leave`, checked against the public key before it is sent, so that a key that
	/// is not the one on record is found here and not refused as `signature` by the relay.
	func prove(_ purpose: RelayProof.Purpose, pairing: PairingID?, device: DeviceID?, challenge: Data) throws -> Data {
		try signChecked(try RelayProof.text(purpose, pairing: pairing, device: device, challenge: challenge))
	}

	/// The notice a phone leaves for its Mac (3.6): the device key's signature over the leave text, checked as a proof is.
	func leaveNotice(pairing: PairingID, device: DeviceID, identityKey: P256.Signing.PublicKey, at: Int64) throws -> Data {
		let text: Data
		do {
			text = try RelayLeaveNotice.text(pairing: pairing, device: device, identityKey: identityKey, at: at)
		} catch let error as RemoteKitError {
			throw RelayClientError.invalid(error)
		}
		return try signChecked(text)
	}

	private func signChecked(_ text: Data) throws -> Data {
		let signature: Data
		do {
			signature = try sign(text)
		} catch {
			throw RelayClientError.cannotSign
		}
		guard signature.count == SignedStatement.signatureLength, SignedStatement.verify(signature, over: text, by: publicKey) else {
			throw RelayClientError.cannotSign
		}
		return signature
	}
}

/// The relay's answer to a push: sent (Apple took it), or refused with its word.
public enum RelayPushAnswer: Equatable, Sendable {
	case sent
	case refused(RelayWhy)
}

/// Why a call to the relay's client did not do what it asked.
public enum RelayClientError: Error, Equatable, Sendable {
	/// Not connected and proved just now; the client is connecting again.
	case notConnected
	/// The socket dropped before the answer came: the request may or may not have been carried out.
	case disconnected
	/// The relay refused the request or the connection, with its word.
	case refused(RelayWhy)
	/// Past a limit: the relay closed the socket, and may be come back to at `until`.
	case busy(until: Int64)
	/// The relay answered the connection with this HTTP status, not a WebSocket.
	case http(Int)
	/// The socket closed, or could not be opened, without a word from the relay; or nothing came in time.
	case lost
	/// The relay sent what this client does not read.
	case unreadable
	/// A request this end does not send: the Mac's to a phone's client, or the other way round.
	case wrongEnd
	/// The key would not sign, or signed with another key than its public one.
	case cannotSign
	/// The client was stopped.
	case stopped
	/// What the caller gave cannot be sent: the relay would refuse its form.
	case invalid(RemoteKitError)
}

/// How long the client waits, and how it comes back.
public struct RelayOptions: Sendable {
	/// How often a ready socket pings the relay. The relay takes a Mac socket that has sent nothing for 90 seconds for
	/// gone (relay/README.md), so this stays well below that.
	public var pingEvery: Int64 = 30_000
	/// A socket that has heard nothing, not even a pong, for this long is taken for dead and opened again.
	public var quietAfter: Int64 = 75_000
	/// A handshake or a request not answered within this long, checked at each ping, takes the socket for dead.
	public var answerWithin: Int64 = 30_000
	/// Waits between attempts.
	public var backoff = RelayBackoff()
	/// A connection that stayed ready this long starts the backoff again from the beginning.
	public var steadyAfter: Int64 = 60_000
	/// The most events held for a caller that has not read them; past it the socket is closed and opened again
	/// (`RelayDrop.overflow`). A data event holds at most 70 KB.
	public var eventBuffer = 256
	public var clock: any RelayClock = SystemRelayClock()
	/// A number from 0 up to 1, for jitter.
	public var random: @Sendable () -> Double = { Double.random(in: 0..<1) }

	public init() {}
}

/// Exponential backoff with jitter: before the nth attempt again (from 0), a wait of between half and all of
/// `first`·2ⁿ, at most `longest`; so that many ends that dropped at once (the relay restarted) do not come back at once.
public struct RelayBackoff: Sendable, Equatable {
	public var first: Int64 = 1_000
	public var longest: Int64 = 60_000

	public init(first: Int64 = 1_000, longest: Int64 = 60_000) {
		self.first = first
		self.longest = longest
	}

	public func delay(attempt: Int, random: Double) -> Int64 {
		let full = attempt >= 32 ? longest : min(longest, first << Int64(attempt))
		let half = full / 2
		return half + Int64((Double(full - half) * min(max(random, 0), 1)).rounded(.down))
	}
}

/// What the client reports as it goes. Past `RelayOptions.eventBuffer` unread events are dropped, the `disconnected`
/// that follows an overflow among them, so a caller takes any `connecting`, `macReady` or `deviceReady` to mean that the
/// socket before is gone, whether or not it was told.
public enum RelayEvent: Equatable, Sendable {
	/// Opening a socket; `attempt` counts the attempts since the last steady connection. Any socket before is gone.
	case connecting(attempt: Int)
	/// The Mac is connected and proved, on a new socket: any before is gone. What `ready` lists is the relay's word: a
	/// hint (remotekit.md).
	case macReady(RelayMacReady)
	/// The phone is connected and proved, on a new socket: any before is gone. Whether the Mac is there, and the count of
	/// mail, are the relay's word.
	case deviceReady(macOnline: Bool, mail: Int)
	/// The channel's bytes: to the Mac, under the device's id; to a phone, as from the Mac. The id is the relay's word:
	/// only the channel of that device proves who sent them (its handshake's prologue names the device), so the bytes go
	/// to that device's channel and nowhere else, and a failure there touches no other device.
	case data(from: DeviceID?, Data)
	/// The relay says a device connected: a hint it can forge. Only for a device `ready` listed, a `joined` named or
	/// `addDevice` added, and only when it changes.
	case online(DeviceID)
	/// The relay says a device went: a hint it can forge. As `online`.
	case offline(DeviceID)
	/// The relay says a phone joined the window. Its key and App Attest key id are the relay's word: `addDevice` sends
	/// the engine's, from the claim the engine verified, never these.
	case phoneJoined(RelayJoinNotice)
	/// The relay says a device left, and passes on what its phone signed for the Mac. Its word alone until
	/// `RelayLeft.verified` has checked the notice against the device key the caller holds: only a verified leave is the
	/// device having left; any other is a hint, "the relay says this device left", and nothing is revoked or forgotten on it.
	case left(RelayLeft)
	/// The relay says another copy of pi² Remote holding the relay key tried to connect as this Mac (3.4). A hostile
	/// relay can say it too: shown as what the relay says.
	case anotherMac
	/// The relay says it closed a phone past a limit, until then (6.6): a hint.
	case held(DeviceID, until: Int64)
	/// The relay says the Mac connected or went away, as a phone is told: a hint.
	case macOnline(Bool)
	/// The relay says something arrived in this end's mailbox: `take` it. Sent once until the next `take`.
	case mail
	/// The socket dropped; the client opens it again at `retryAt` (ms since 1970, by this end's clock).
	case disconnected(RelayDrop, retryAt: Int64)
	/// The client stopped for good, and why. Nothing follows.
	case stopped(RelayStop)
}

/// Why a socket dropped, when the client will try again.
public enum RelayDrop: Equatable, Sendable {
	/// The socket closed, or could not be opened, without a word from the relay.
	case lost
	/// Past a limit (6.6): back at `until`, by the relay's clock.
	case busy(until: Int64)
	/// Refused with a word worth trying again after: `unavailable`, `timeout`, `too-many`, `another-mac`, `limits`.
	case refused(RelayWhy)
	/// The relay answered the connection with an HTTP status worth trying again after (429, 5xx).
	case http(Int)
	/// The relay sent what this client does not read.
	case unreadable
	/// Nothing heard for too long, or a handshake or request not answered.
	case quiet
	/// More events waited unread than `RelayOptions.eventBuffer`.
	case overflow
}

/// Why the client stopped.
public enum RelayStop: Equatable, Sendable {
	/// Its user stopped it.
	case stopped
	/// A refusal that trying again would not change, if the relay says true: that the pairing or the device is gone
	/// (`unknown-pairing`, `not-listed`, `removed`, `left`, `deleted`), the key is not the one on record (`signature`),
	/// the build is too old (`update-required`), another connection took this one's place (`replaced`), or a word this
	/// client does not know. **Each is the relay's claim, which a hostile relay can make**: the client stops, and its
	/// user shows it, but forgets no key or pairing, revokes nothing, wipes nothing and registers no new pairing on it;
	/// it starts again on the person's word, or after a long wait, or at the next launch (remotekit.md).
	case refused(RelayWhy)
	/// The relay answered with an HTTP status trying again cannot change (400, 403, 404, 426).
	case http(Int)
	/// The key would not sign.
	case cannotSign
}

/// What `put` found.
public enum RelayPutResult: Equatable, Sendable {
	case stored
	/// An item with that id was there already: the same put sent again, after a drop, whose first one was stored.
	case alreadyThere
}

/// What `take` brought: the items not taken before, oldest first, and a phone's state from the Mac.
public struct RelayTaken: Equatable, Sendable {
	public let items: [RelayMailItem]
	public let state: RelayStateItem?
	/// Items dropped as repeats of ones remembered in the last 25 hours, or twice in this take. They are acknowledged with
	/// the rest, so that the relay deletes them.
	public let repeats: Int

	public init(items: [RelayMailItem], state: RelayStateItem?, repeats: Int) {
		self.items = items
		self.state = state
		self.repeats = repeats
	}

	/// The ids of everything given: the items and the state. For `take`'s closure to return only once all of it is kept
	/// or certainly not genuine.
	public var ids: Set<ItemID> { Set(items.map(\.id) + (state.map { [$0.id] } ?? [])) }
}

/// What a phone gives to App Attest at `join`, and what it gets back (3.3 step 2): its attestation of a new key, made
/// for this join, over the client data hash it is given, and that key's id.
public struct RelayAttestation: Sendable {
	public let attestation: Data
	public let keyId: AttestKeyID

	public init(attestation: Data, keyId: AttestKeyID) {
		self.attestation = attestation
		self.keyId = keyId
	}
}

public actor RelayClient {
	public enum Role: Equatable, Sendable {
		case mac(PairingID)
		case device(PairingID, DeviceID)

		var pairing: PairingID {
			switch self {
			case let .mac(pairing), let .device(pairing, _): pairing
			}
		}

		var end: RelayEnd {
			switch self {
			case .mac: .mac
			case .device: .device
			}
		}
	}

	public nonisolated let role: Role
	/// What the client reports, in order. Ends after `stopped`.
	public nonisolated let events: AsyncStream<RelayEvent>
	private let emit: AsyncStream<RelayEvent>.Continuation
	private let url: URL
	private let build: RelayBuild
	private let signer: RelaySigner
	private let connector: any RelayConnector
	private let options: RelayOptions

	private var runner: Task<Void, Never>?
	private var watchdog: Task<Void, Never>?
	private var finished = false
	private var generation = 0
	private var socket: (any RelaySocket)?
	private var ready = false
	private var challenge: Data?
	private var connectedAt: Int64 = 0
	private var lastHeard: Int64 = 0
	private var quiet = false
	private var unreadable = false
	private var refusal: RelayWhy?
	private var busyUntil: Int64?
	private var pending: Pending?
	private var requestBusy = false
	private var requestQueue: [CheckedContinuation<Void, Never>] = []
	/// Takes, one at a time from the `take` request to its `took` (#806).
	private var takeBusy = false
	private var takeQueue: [CheckedContinuation<Void, Never>] = []
	private var endWaiters: [Int: CheckedContinuation<RelayStop?, Never>] = [:]
	private var nextWaiter = 0
	private var memory: RelayItemMemory
	private var overflowed = false
	/// Whether `mail` was reported and no `take` came after.
	private var mailReported = false
	/// What was last reported of each device's presence, and of the Mac's, so that a repeat is not reported again; kept
	/// only for the devices the client knows of (`known`).
	private var presence: [DeviceID: Bool] = [:]
	/// The devices the Mac's client takes notices of: those a `ready` listed, a `joined` named, `addDevice` added or
	/// `send(_:to:)` sent to, the latest `RelayClient.knownDevices` seen. A presence notice naming any other is not read, so that a relay naming new ids
	/// cannot grow what the client holds.
	private var known: [DeviceID] = []
	/// The most devices known at once: five listed, and the slots of the windows opened while connected.
	public static let knownDevices = 64
	private var macPresence: Bool?
	/// Why the client stopped, once it has: also for a caller whose events were past the bound when it stopped.
	public private(set) var stopReason: RelayStop?

	/// Throws `invalid` for a relay's address that is not `wss://`, or `ws://` to this computer (`RelayEndpoint`).
	public init(
		relay url: URL, role: Role, build: RelayBuild, signer: RelaySigner, connector: any RelayConnector = URLSessionRelayConnector(),
		options: RelayOptions = RelayOptions(), itemMemory: RelayItemMemory = RelayItemMemory()
	) throws {
		try Self.checkAddress(url)
		self.url = url
		self.role = role
		self.build = build
		self.signer = signer
		self.connector = connector
		self.options = options
		memory = itemMemory
		(events, emit) = AsyncStream.makeStream(of: RelayEvent.self, bufferingPolicy: .bufferingOldest(max(1, options.eventBuffer)))
	}

	static func checkAddress(_ url: URL) throws {
		guard RelayEndpoint.isAllowed(url) else { throw RelayClientError.invalid(RemoteKitError("relay address", "not wss, or ws to this computer")) }
	}

	/// Starts connecting, and keeps connected until `stop` or a refusal that stops it.
	public func start() {
		guard runner == nil, !finished else { return }
		runner = Task { await self.run() }
	}

	/// Closes the socket and stops for good.
	public func stop() {
		finish(.stopped)
	}

	/// The ids of items remembered in the last 25 hours, for its user to keep across launches and give back to the next
	/// client.
	public var itemMemory: RelayItemMemory { memory }

	/// Remembers items its user has opened, verified and kept, so that the relay handing one over again is dropped as a
	/// repeat for 25 hours. **This is the caller's to do**, after `SealedItem.openRequest` or `openMacItem` took the item
	/// and it is kept: an item the relay made up is never remembered, so it cannot push a real one out. Remember before
	/// the next `take` (a repeat across two takes before it is not caught), and save `itemMemory` after each call, so that
	/// a relaunch remembers too.
	///
	/// Answers false if the memory is full of ids younger than 25 hours and could not take them all. The caller does
	/// nothing about it: those items are only not guarded against a repeat, and the other checks still hold (the engine's
	/// nonces for requests, rising numbers for states, the age limit for the Mac's items).
	@discardableResult
	public func remember(_ items: [RelayMailItem]) -> Bool {
		let now = options.clock.now()
		var all = true
		for item in items where !memory.remember(item, at: now) { all = false }
		return all
	}

	/// Whether a socket is connected and proved just now.
	public var isReady: Bool { ready }

	// MARK: The Mac's requests

	/// Opens a join window for the token whose SHA-256 is `tokenHash`, until `expires` (ms since 1970; the relay keeps it
	/// five minutes at most). A window already open is closed first, with the slots of phones that joined it.
	public func openJoin(tokenHash: Data, expires: Int64) async throws {
		try requireMac()
		try await expectOK(.openJoin(tokenHash: tokenHash, expires: expires), .openJoin)
	}

	/// Closes the join window, and drops the slots of phones that joined it and were not added: send `addDevice` first.
	public func closeJoin() async throws {
		try requireMac()
		try await expectOK(.closeJoin, .closeJoin)
	}

	/// Lists the phone that joined with `deviceKey` under the engine's id for it (3.3 step 8), with the App Attest key the
	/// Mac checked in `pair` (not the relay's). Before `closeJoin`, and before the window expires.
	public func addDevice(_ device: DeviceID, deviceKey: P256.Signing.PublicKey, attestKeyId: AttestKeyID) async throws {
		try requireMac()
		try await expectOK(.addDevice(device, deviceKey: deviceKey, attestKeyId: attestKeyId), .addDevice)
		know(device)
	}

	/// Removes a device's slot, its mailbox and push token; the relay closes its socket at once (3.6). A device already
	/// gone is answered as removed.
	public func removeDevice(_ device: DeviceID) async throws {
		try requireMac()
		try await expectOK(.removeDevice(device), .removeDevice)
	}

	/// Deletes the pairing at the relay. The relay then closes this socket, and the client stops with `deleted`.
	public func deletePairing() async throws {
		try requireMac()
		try await expectOK(.deletePairing, .deletePairing)
	}

	/// Leaves a device's latest state, in place of the one before.
	public func putState(_ item: Data, id: ItemID, for device: DeviceID) async throws {
		try requireMac()
		try await expectOK(.state(device: device, id: id, item: item), .state)
	}

	/// Asks the relay to push to a device (#689; relay/README.md, "Pushes", "Live Activities"): `sent` once Apple took
	/// it, or the relay's word for why not (`no-token`, `token-dead`, `push-limit`, `push-later`, `unavailable`,
	/// `unknown-device`, `clock`, or a word this client does not know), which is the caller's to pass on. Nothing is sent
	/// again here: what to ask again is the engine's to decide. Throws as any request does when it could not be asked.
	public func push(_ push: RelayPush) async throws -> RelayPushAnswer {
		try requireMac()
		switch try await request(.push(push), .push) {
		case .ok: return .sent
		case let .refused(why): return .refused(why)
		case .taken: throw RelayClientError.unreadable
		}
	}

	/// Sends the channel's bytes to a device; the relay puts nothing round them but takes the id off. If the device is not
	/// connected, the relay answers `offline`, which the client reports only if it last reported the device online.
	public func send(_ bytes: Data, to device: DeviceID) async throws {
		try requireMac()
		guard let deviceBytes = Base64URL.decode(String(device.text.dropFirst(4)), count: 16) else { throw RelayClientError.invalid(RemoteKitError("relay data", "not a device")) }
		// The relay answers `offline` for an id it has no socket for, as an honest relay does: the id is the caller's
		// own, so knowing it lets the relay grow nothing.
		know(device)
		try await sendBinary(deviceBytes + bytes, body: bytes.count)
	}

	// MARK: A phone's requests

	/// Sends the channel's bytes to the Mac. If the Mac is not connected, the relay answers `macOnline(false)`, which the
	/// client reports only if it last reported the Mac online.
	public func send(_ bytes: Data) async throws {
		try requireDevice()
		try await sendBinary(bytes, body: bytes.count)
	}

	/// Gives the relay this phone's push token (7).
	public func setPushToken(_ apns: String, environment: RelayPushEnvironment) async throws {
		try requireDevice()
		try await expectOK(.token(apns: apns, environment: environment), .token)
	}

	/// Gives the relay a Live Activity's push token, for the activity this phone started under `activity` (7).
	public func setActivityToken(_ apns: String, environment: RelayPushEnvironment, for activity: ItemID) async throws {
		try requireDevice()
		try await expectOK(.activityToken(activity: activity, apns: apns, environment: environment), .activityToken)
	}

	/// Takes a Live Activity's push token back: the activity ended on the phone.
	public func dropActivity(_ activity: ItemID) async throws {
		try requireDevice()
		try await expectOK(.dropActivity(activity), .dropActivity)
	}

	/// Removes this phone from the pairing at the relay (3.6), signed with the device key over this connection's
	/// challenge, and leaves its Mac the notice it believes (`RelayLeft`): the device key's signature over the leave text
	/// for this pairing, this device, `identityKey` (the Mac's, as the phone keeps it from pairing) and the time now. The
	/// relay closes the socket, and the client stops with `left`. Throws `lost` if no answer came within
	/// `RelayOptions.answerWithin`. The phone's Unpair does not wait on it: its keys are deleted either way (3.6).
	public func leave(mac identityKey: P256.Signing.PublicKey) async throws {
		guard case let .device(pairing, device) = role else { throw RelayClientError.wrongEnd }
		guard !finished else { throw RelayClientError.stopped }
		guard ready, let socket, let challenge else { throw RelayClientError.notConnected }
		let signature = try signer.prove(.leave, pairing: pairing, device: device, challenge: challenge)
		let at = options.clock.now()
		let notice = try signer.leaveNotice(pairing: pairing, device: device, identityKey: identityKey, at: at)
		let message = RelayOutgoing.leave(signature: signature, at: at, notice: notice)
		do {
			try message.validate()
		} catch let error as RemoteKitError {
			throw RelayClientError.invalid(error)
		}
		let sentOn = generation
		do {
			try await socket.send(.text(message.text))
		} catch {
			throw RelayClientError.disconnected
		}
		// The answer may have been handled while the leave was being sent: the client stopped, or a new socket opened.
		if finished {
			guard stopReason == .refused(.left) else { throw RelayClientError.disconnected }
			return
		}
		guard sentOn == generation else { throw RelayClientError.disconnected }
		nextWaiter += 1
		let waiter = nextWaiter
		let clock = options.clock
		let within = options.answerWithin
		let deadline = Task {
			guard (try? await clock.sleep(milliseconds: within)) != nil else { return }
			self.endWaiter(waiter)
		}
		defer { deadline.cancel() }
		let stop = await withCheckedContinuation { endWaiters[waiter] = $0 }
		if stop == .refused(.left) { return }
		throw finished || sentOn != generation ? RelayClientError.disconnected : RelayClientError.lost
	}

	// MARK: Both ends' mailbox

	/// Puts a sealed item in the other end's mailbox: the Mac's to a device, a phone's to the Mac. `presence` marks an
	/// item whose request is a `"face"` one (4.2), which the relay keeps an hour, not a day.
	public func put(_ item: Data, id: ItemID, to reader: RelayAddress, presence: Bool = false) async throws -> RelayPutResult {
		switch (role, reader) {
		case (.mac, .device), (.device, .mac): break
		default: throw RelayClientError.wrongEnd
		}
		do {
			try await expectOK(.put(to: reader, id: id, item: item, presence: presence), .put)
			return .stored
		} catch RelayClientError.refused(.exists) {
			return .alreadyThere
		}
	}

	/// Takes what waits in this end's mailbox, hands what is new to `keep`, and once `keep` has returned tells the relay
	/// to delete what `keep` said it is done with (`took`, #806); gives back what `keep` was given.
	///
	/// The relay deletes nothing as it hands items over: only what this end names in `took`. **`keep` returns the ids,
	/// among those it was given (the items' and the state's), that it is done with**, and only those are acknowledged:
	/// - **kept**: opened, verified, stored or handed on, `remember`ed, and the item memory saved in the same write as what
	///   was kept, all before `keep` returns;
	/// - or **certainly not genuine**, so that it never will be kept: its seal does not open with the reader's key, its
	///   signature does not verify, its writer or its address is not what it says. Only that: nothing that could pass.
	///
	/// **A failure that could pass later is not an answer**: the reader's key not available (before the first unlock, in
	/// the notification service extension), the Keychain or the store not writable, the device's record not loaded. Then
	/// `keep` leaves the id out, or throws (nothing is acknowledged, and `take` throws what `keep` threw), and the relay
	/// hands the item over again at the next take, until it expires. An id `keep` names that this take did not bring is
	/// passed over. Items remembered in the last 25 hours (`remember`) are dropped as repeats and not given to `keep`, but
	/// acknowledged: they were kept before, and a redelivery after an acknowledgement that was lost is deleted. An item
	/// given twice in this take is given to `keep` once, and acknowledged as `keep` says of it.
	///
	/// **One take at a time**: a take waits for the one before it until that one's `took` has been sent, or its `keep`
	/// threw, so that two takes are never given the same items, which the first had not yet remembered. Callers of one
	/// end share one client, or at least one take at a time and one item memory (the app and its extension).
	///
	/// An acknowledgement that does not reach the relay (the socket dropped, the client stopped) is not an error: what
	/// `keep` kept stays kept, and the relay hands those items over again, which the memory drops and the next take
	/// acknowledges. A closure, rather than a token the caller acknowledges later, so that acknowledging cannot be left
	/// out, or done before the items are kept; and it names what it is done with, so that nothing is acknowledged by
	/// default.
	public func take(_ keep: @Sendable (RelayTaken) async throws -> Set<ItemID>) async throws -> RelayTaken {
		await acquireTake()
		defer { releaseTake() }
		mailReported = false
		guard case let .taken(items, state) = try await request(.take, .take) else { throw RelayClientError.unreadable }
		let now = options.clock.now()
		var seen = Set<String>()
		let remembered = Set(items.filter { memory.contains($0, at: now) }.map(\.id))
		let fresh = items.filter { !memory.contains($0, at: now) && seen.insert("\($0.from.text) \($0.id.text)").inserted }
		let taken = RelayTaken(items: fresh, state: state, repeats: items.count - fresh.count)
		let done = try await keep(taken)
		// What `keep` is done with, and the repeats it was not given, each once, in the take's order: at most a mailbox's
		// items and a state, which `took` holds.
		var named = Set<ItemID>()
		let ids = (items.map(\.id) + (state.map { [$0.id] } ?? [])).filter { (remembered.contains($0) || done.contains($0)) && named.insert($0).inserted }
		if !ids.isEmpty { try? await expectOK(.took(ids: ids), .took) }
		return taken
	}

	// MARK: Registering and joining, each on a socket of its own

	/// Registers a new pairing for this Mac's relay key (5.3), and gives its id. The pairing is pending, and deleted by
	/// the relay 15 minutes later unless a phone that joined it is added.
	public static func register(
		relay url: URL, build: RelayBuild, relayKey: RelaySigner, connector: any RelayConnector = URLSessionRelayConnector(),
		options: RelayOptions = RelayOptions()
	) async throws -> PairingID {
		try checkAddress(url)
		let socket = try await open(connector, url, pairing: nil)
		let deadline = closing(socket, after: options.answerWithin, clock: options.clock)
		defer {
			deadline.cancel()
			socket.close()
		}
		try await sendText(socket, .register(build: build, relayKey: relayKey.publicKey))
		guard case let .challenge(challenge) = try await nextMessage(socket, .registering) else { throw RelayClientError.unreadable }
		let signature = try relayKey.prove(.register, pairing: nil, device: nil, challenge: challenge)
		try await sendText(socket, .proof(signature: signature))
		guard case let .registered(pairing) = try await nextMessage(socket, .registering) else { throw RelayClientError.unreadable }
		return pairing
	}

	/// Joins the open window of a pairing as a phone with no slot (3.3 step 2): the relay's challenge, then `attest` is
	/// given the client data hash (`PairingSecrets.joinClientDataHash`) and answers App Attest's attestation of a new key
	/// made for this join. On `joined`, the socket carries the channel to the Mac (`RelayJoinLink`), until the Mac adds
	/// the phone under the engine's id, which the phone learns in `paired` and says at its next `hello`.
	public static func join(
		relay url: URL, pairing: PairingID, build: RelayBuild, deviceKey: P256.Signing.PublicKey, token: Data,
		attest: @Sendable (Data) async throws -> RelayAttestation, connector: any RelayConnector = URLSessionRelayConnector(),
		options: RelayOptions = RelayOptions()
	) async throws -> RelayJoinLink {
		try checkAddress(url)
		let socket = try await open(connector, url, pairing: pairing)
		let deadline = closing(socket, after: options.answerWithin, clock: options.clock)
		var handedOver = false
		defer {
			deadline.cancel()
			if !handedOver { socket.close() }
		}
		try await sendText(socket, .hello(pairing: pairing, device: nil, role: .device, build: build))
		guard case let .challenge(challenge) = try await nextMessage(socket, .joining) else { throw RelayClientError.unreadable }
		let attestation = try await attest(try PairingSecrets.joinClientDataHash(challenge: challenge, deviceKey: deviceKey))
		try await sendText(socket, .join(pairing: pairing, deviceKey: deviceKey, attestation: attestation.attestation, keyId: attestation.keyId, token: token))
		guard case let .joined(slot) = try await nextMessage(socket, .joining) else { throw RelayClientError.unreadable }
		deadline.cancel()
		handedOver = true
		return RelayJoinLink(socket: socket, slot: slot, options: options)
	}

	// MARK: The connection

	private func run() async {
		var attempt = 0
		while !finished {
			post(.connecting(attempt: attempt))
			let (ending, readyAt) = await connectOnce()
			guard !finished else { return }
			switch ending {
			case let .stop(reason):
				finish(reason)
				return
			case let .retry(drop):
				resumeEndWaiters(nil)
				let now = options.clock.now()
				if let readyAt, now - readyAt >= options.steadyAfter { attempt = 0 }
				let wait = delay(for: drop, attempt: attempt, now: now)
				attempt += 1
				post(.disconnected(drop, retryAt: now + wait))
				do {
					try await options.clock.sleep(milliseconds: wait)
				} catch {
					return
				}
			}
		}
	}

	private enum Ending {
		case retry(RelayDrop)
		case stop(RelayStop)
	}

	/// One socket, from opening it to its end, and how it ended.
	private func connectOnce() async -> (Ending, Int64?) {
		generation += 1
		let id = generation
		ready = false
		challenge = nil
		quiet = false
		unreadable = false
		refusal = nil
		busyUntil = nil
		overflowed = false
		var readyAt: Int64?

		let opened: any RelaySocket
		do {
			opened = try await connector.connect(to: url, pairing: role.pairing)
		} catch let closed as RelaySocketClosed {
			return (classify(closed), nil)
		} catch {
			return (.retry(.lost), nil)
		}
		guard !finished, id == generation else {
			opened.close()
			return (.stop(.stopped), nil)
		}
		socket = opened
		connectedAt = options.clock.now()
		lastHeard = connectedAt
		watchdog = Task { await self.watch(id, opened) }
		defer {
			watchdog?.cancel()
			watchdog = nil
			socket = nil
			ready = false
			opened.close()
			pending?.finish(.failure(RelayClientError.disconnected))
			pending = nil
		}

		var closed: RelaySocketClosed?
		do {
			let device: DeviceID? = if case let .device(_, device) = role { device } else { nil }
			try await opened.send(.text(RelayOutgoing.hello(pairing: role.pairing, device: device, role: role.end == .mac ? .mac : .device, build: build).text))
			while true {
				let frame = try await opened.receive()
				guard id == generation, !finished else { break }
				lastHeard = options.clock.now()
				switch frame {
				case let .binary(bytes):
					guard ready, refusal == nil, busyUntil == nil else { throw Unreadable() }
					try deliver(bytes)
				case let .text(text):
					let message: RelayIncoming
					do {
						message = try RelayIncoming.parse(text, for: role.end)
					} catch {
						throw Unreadable()
					}
					if case let .refused(why) = message {
						refusal = why
						continue
					}
					if case let .busy(until) = message {
						busyUntil = until
						continue
					}
					// After a refusal or `busy`, only the socket's closing is expected.
					guard refusal == nil, busyUntil == nil else { throw Unreadable() }
					if ready {
						try handle(message)
						continue
					}
					switch (message, challenge) {
					case let (.challenge(bytes), nil):
						challenge = bytes
						let signature = try signer.prove(role.end == .mac ? .mac : .device, pairing: role.pairing, device: device, challenge: bytes)
						try await opened.send(.text(RelayOutgoing.proof(signature: signature).text))
					case let (.macReady(info), _?) where role.end == .mac:
						ready = true
						readyAt = options.clock.now()
						resetReported()
						for device in info.devices {
							know(device.device)
							presence[device.device] = device.online
						}
						post(.macReady(info))
					case let (.deviceReady(macOnline, mail), _?) where role.end == .device:
						ready = true
						readyAt = options.clock.now()
						resetReported()
						macPresence = macOnline
						post(.deviceReady(macOnline: macOnline, mail: mail))
					case (.pong, _):
						break
					default:
						throw Unreadable()
					}
				}
			}
		} catch let error as RelaySocketClosed {
			closed = error
		} catch is Unreadable {
			unreadable = true
		} catch RelayClientError.cannotSign {
			return (.stop(.cannotSign), readyAt)
		} catch {
			closed = nil
		}
		if finished { return (.stop(.stopped), readyAt) }
		// A relay that broke the protocol is not taken at its word, whatever it said before.
		if unreadable { return (.retry(.unreadable), readyAt) }
		if overflowed { return (.retry(.overflow), readyAt) }
		if let busyUntil { return (.retry(.busy(until: busyUntil)), readyAt) }
		if let refusal { return (classify(refusal), readyAt) }
		if quiet { return (.retry(.quiet), readyAt) }
		if let closed { return (classify(closed), readyAt) }
		return (.retry(.lost), readyAt)
	}

	private struct Unreadable: Error {}

	/// A message on a ready socket.
	private func handle(_ message: RelayIncoming) throws {
		switch message {
		case .pong:
			break
		case let .ok(kind):
			guard let request = pending, request.kind == kind, kind != .take else { throw Unreadable() }
			pending = nil
			request.finish(.success(.ok))
		case let .requestRefused(kind, why):
			guard let request = pending, request.kind == kind else { throw Unreadable() }
			pending = nil
			request.finish(.success(.refused(why)))
		case let .item(item):
			guard let request = pending, request.kind == .take, request.state == nil, request.items.count < RelayLimits.mailbox(for: role.end) else { throw Unreadable() }
			request.items.append(item)
		case let .state(state):
			guard let request = pending, request.kind == .take, request.state == nil else { throw Unreadable() }
			request.state = state
		case let .taken(count):
			guard let request = pending, request.kind == .take, count == request.items.count + (request.state == nil ? 0 : 1) else { throw Unreadable() }
			pending = nil
			request.finish(.success(.taken(request.items, request.state)))
		case .mail:
			// Once until the next take: more say nothing more.
			guard !mailReported else { return }
			mailReported = true
			post(.mail)
		case let .online(device), let .offline(device):
			let online = if case .online = message { true } else { false }
			// Only of a device the client knows: an id the relay made up is not held.
			guard known.contains(device) else { throw Unreadable() }
			guard presence[device] != online else { return }
			presence[device] = online
			post(online ? .online(device) : .offline(device))
		case let .phoneJoined(notice):
			know(notice.slot)
			post(.phoneJoined(notice))
		case let .left(left):
			presence[left.device] = nil
			post(.left(left))
		case .anotherMac: post(.anotherMac)
		case let .held(device, until): post(.held(device, until: until))
		case let .macOnline(online):
			guard macPresence != online else { return }
			macPresence = online
			post(.macOnline(online))
		case .challenge, .registered, .macReady, .deviceReady, .joined, .refused, .busy:
			throw Unreadable()
		}
	}

	/// The channel's bytes from the relay: to the Mac, with the device's 16-byte id in front.
	private func deliver(_ bytes: Data) throws {
		guard !bytes.isEmpty, bytes.count <= RelayLimits.maxBinary else { throw Unreadable() }
		if role.end == .mac {
			guard bytes.count > 16, let device = DeviceID("dev_" + Base64URL.encode(bytes.prefix(16))) else { throw Unreadable() }
			post(.data(from: device, Data(bytes.dropFirst(16))))
		} else {
			post(.data(from: nil, bytes))
		}
	}

	/// Reports an event; one that does not fit in what is held for the caller closes the socket, which is opened again
	/// through the backoff, rather than holding more.
	private func post(_ event: RelayEvent) {
		if case .dropped = emit.yield(event) {
			guard !overflowed, let socket else { return }
			overflowed = true
			socket.close()
		}
	}

	/// Takes notices of `device` from now on; the earliest known goes past `knownDevices`.
	/// A device seen again moves to the back, so that the devices in use are the last to go.
	private func know(_ device: DeviceID) {
		known.removeAll { $0 == device }
		known.append(device)
		if known.count > Self.knownDevices { presence[known.removeFirst()] = nil }
	}

	/// A `leave` that went unanswered.
	private func endWaiter(_ waiter: Int) {
		endWaiters.removeValue(forKey: waiter)?.resume(returning: nil)
	}

	private func resetReported() {
		mailReported = false
		presence = [:]
		macPresence = nil
	}

	/// Pings while the socket is ready, and closes it once it has heard nothing for too long, or a handshake or a request
	/// went unanswered, so that a socket the network left half open is opened again.
	private func watch(_ id: Int, _ watched: any RelaySocket) async {
		while !Task.isCancelled {
			do {
				try await options.clock.sleep(milliseconds: options.pingEvery)
			} catch {
				return
			}
			guard id == generation, !finished else { return }
			let now = options.clock.now()
			let unanswered = pending.map { now - $0.since >= options.answerWithin } ?? false
			if now - lastHeard >= options.quietAfter || (!ready && now - connectedAt >= options.answerWithin) || unanswered {
				quiet = true
				watched.close()
				return
			}
			if ready { try? await watched.send(.text(RelayOutgoing.ping.text)) }
		}
	}

	private func classify(_ why: RelayWhy) -> Ending {
		switch why {
		case .unavailable, .timeout, .tooMany, .anotherMac, .limits, .busy: .retry(.refused(why))
		default: .stop(.refused(why))
		}
	}

	private func classify(_ closed: RelaySocketClosed) -> Ending {
		if let status = closed.httpStatus {
			return status == 429 || status >= 500 ? .retry(.http(status)) : .stop(.http(status))
		}
		// The refusal's message lost, its word still the closing's reason.
		if let reason = closed.reason, let why = RelayWhy(word: reason) { return classify(why) }
		return .retry(.lost)
	}

	private func delay(for drop: RelayDrop, attempt: Int, now: Int64) -> Int64 {
		let backoff = options.backoff.delay(attempt: attempt, random: options.random())
		switch drop {
		case let .busy(until):
			// The relay's own time to come back, and never sooner than the backoff, so that a time already past (a clock
			// that is fast, or a relay that says so) does not bring the client back at once for ever; and up to a second
			// more, so that the ends it closed together spread out.
			let wait = max(backoff, min(max(until - now, 0), 24 * 3_600_000))
			return wait + Int64((options.random() * 1000).rounded(.down))
		case .refused(.anotherMac):
			// The relay takes a Mac socket gone quiet for gone after 90 seconds; asking sooner only tells it again.
			return max(backoff, 30_000)
		case .refused(.limits):
			return max(backoff, 3_600_000)
		case .http(429):
			return max(backoff, 60_000)
		default:
			return backoff
		}
	}

	private func finish(_ reason: RelayStop) {
		guard !finished else { return }
		finished = true
		generation += 1
		socket?.close()
		socket = nil
		ready = false
		watchdog?.cancel()
		runner?.cancel()
		pending?.finish(.failure(RelayClientError.stopped))
		pending = nil
		for waiter in requestQueue { waiter.resume() }
		requestQueue = []
		for waiter in takeQueue { waiter.resume() }
		takeQueue = []
		stopReason = reason
		resumeEndWaiters(reason)
		emit.yield(.stopped(reason))
		emit.finish()
	}

	private func resumeEndWaiters(_ reason: RelayStop?) {
		let waiters = endWaiters
		endWaiters = [:]
		for waiter in waiters.values { waiter.resume(returning: reason) }
	}

	// MARK: Requests

	private enum Answer: Sendable {
		case ok
		case refused(RelayWhy)
		case taken([RelayMailItem], RelayStateItem?)
	}

	/// The request in flight and what has come of it.
	private final class Pending {
		let kind: RelayRequestKind
		let since: Int64
		var items: [RelayMailItem] = []
		var state: RelayStateItem?
		private var result: Result<Answer, any Error>?
		private var continuation: CheckedContinuation<Answer, any Error>?

		init(kind: RelayRequestKind, since: Int64) {
			self.kind = kind
			self.since = since
		}

		func wait(_ continuation: CheckedContinuation<Answer, any Error>) {
			if let result { continuation.resume(with: result) } else { self.continuation = continuation }
		}

		func finish(_ result: Result<Answer, any Error>) {
			guard self.result == nil else { return }
			self.result = result
			continuation?.resume(with: result)
			continuation = nil
		}
	}

	private func expectOK(_ message: RelayOutgoing, _ kind: RelayRequestKind) async throws {
		switch try await request(message, kind) {
		case .ok: return
		case let .refused(why): throw RelayClientError.refused(why)
		case .taken: throw RelayClientError.unreadable
		}
	}

	private func request(_ message: RelayOutgoing, _ kind: RelayRequestKind) async throws -> Answer {
		do {
			try message.validate()
		} catch let error as RemoteKitError {
			throw RelayClientError.invalid(error)
		}
		await acquire()
		defer { release() }
		guard !finished else { throw RelayClientError.stopped }
		guard ready, let socket else { throw RelayClientError.notConnected }
		let request = Pending(kind: kind, since: options.clock.now())
		pending = request
		do {
			try await socket.send(.text(message.text))
		} catch {
			if pending === request { pending = nil }
			throw RelayClientError.disconnected
		}
		return try await withCheckedThrowingContinuation { request.wait($0) }
	}

	private func sendBinary(_ bytes: Data, body: Int) async throws {
		guard body > 0, bytes.count <= RelayLimits.maxBinary else { throw RelayClientError.invalid(RemoteKitError("relay data", "empty or too long")) }
		guard !finished else { throw RelayClientError.stopped }
		guard ready, let socket else { throw RelayClientError.notConnected }
		do {
			try await socket.send(.binary(bytes))
		} catch {
			throw RelayClientError.disconnected
		}
	}

	private func acquire() async {
		guard requestBusy else {
			requestBusy = true
			return
		}
		await withCheckedContinuation { requestQueue.append($0) }
	}

	private func release() {
		if requestQueue.isEmpty { requestBusy = false } else { requestQueue.removeFirst().resume() }
	}

	private func acquireTake() async {
		guard takeBusy else {
			takeBusy = true
			return
		}
		await withCheckedContinuation { takeQueue.append($0) }
	}

	private func releaseTake() {
		if takeQueue.isEmpty { takeBusy = false } else { takeQueue.removeFirst().resume() }
	}

	private func requireMac() throws {
		guard case .mac = role else { throw RelayClientError.wrongEnd }
	}

	private func requireDevice() throws {
		guard case .device = role else { throw RelayClientError.wrongEnd }
	}

	// MARK: One socket's first messages, for register and join

	static func open(_ connector: any RelayConnector, _ url: URL, pairing: PairingID?) async throws -> any RelaySocket {
		do {
			return try await connector.connect(to: url, pairing: pairing)
		} catch let closed as RelaySocketClosed {
			throw error(closed)
		} catch {
			throw RelayClientError.lost
		}
	}

	static func sendText(_ socket: any RelaySocket, _ message: RelayOutgoing) async throws {
		do {
			try message.validate()
		} catch let error as RemoteKitError {
			throw RelayClientError.invalid(error)
		}
		do {
			try await socket.send(.text(message.text))
		} catch let closed as RelaySocketClosed {
			throw error(closed)
		} catch {
			throw RelayClientError.lost
		}
	}

	/// The next message of a handshake. A refusal or `busy` is read to the socket's closing and thrown.
	static func nextMessage(_ socket: any RelaySocket, _ end: RelayEnd) async throws -> RelayIncoming {
		var refusal: RelayClientError?
		while true {
			let frame: RelayFrame
			do {
				frame = try await socket.receive()
			} catch let closed as RelaySocketClosed {
				throw refusal ?? error(closed)
			} catch {
				throw refusal ?? RelayClientError.lost
			}
			guard case let .text(text) = frame, refusal == nil, let message = try? RelayIncoming.parse(text, for: end) else {
				throw RelayClientError.unreadable
			}
			switch message {
			case let .refused(why): refusal = .refused(why)
			case let .busy(until): refusal = .busy(until: until)
			case .pong: continue
			default: return message
			}
		}
	}

	private static func error(_ closed: RelaySocketClosed) -> RelayClientError {
		if let status = closed.httpStatus { return .http(status) }
		if let reason = closed.reason, let why = RelayWhy(word: reason) { return .refused(why) }
		return .lost
	}

	/// Closes `socket` after `milliseconds` unless cancelled first: a handshake that hangs ends as `lost`.
	static func closing(_ socket: any RelaySocket, after milliseconds: Int64, clock: any RelayClock) -> Task<Void, Never> {
		Task {
			do {
				try await clock.sleep(milliseconds: milliseconds)
				socket.close()
			} catch {}
		}
	}
}

/// A joined phone's socket (3.3 step 2): it carries the channel's bytes to and from the Mac while the pairing exchange
/// runs, and on under the engine's id once the Mac adds the phone. It is not opened again when it drops: a join is made
/// once, with an App Attest key of its own. It holds its socket, and the socket its session, for as long as it lives.
public actor RelayJoinLink {
	/// The slot the relay gave the joined phone, until the Mac adds it under the engine's id.
	public nonisolated let slot: DeviceID
	/// What the link reports, at most `RelayOptions.eventBuffer` unread: past it the link ends (`overflow`).
	public nonisolated let events: AsyncStream<RelayLinkEvent>
	private let emit: AsyncStream<RelayLinkEvent>.Continuation
	private let socket: any RelaySocket
	private let options: RelayOptions
	private var reader: Task<Void, Never>?
	private var pinger: Task<Void, Never>?
	private var closed = false
	private var lastHeard: Int64
	private var mailReported = false
	private var macPresence: Bool?
	/// Why the link ended, once it has: also for a caller whose events were past the bound when it ended.
	public private(set) var endReason: RelayLinkEnd?

	init(socket: any RelaySocket, slot: DeviceID, options: RelayOptions) {
		self.socket = socket
		self.slot = slot
		self.options = options
		lastHeard = options.clock.now()
		(events, emit) = AsyncStream.makeStream(of: RelayLinkEvent.self, bufferingPolicy: .bufferingOldest(max(1, options.eventBuffer)))
		Task { await self.begin() }
	}

	private func begin() {
		guard !closed else { return }
		reader = Task { await self.read() }
		pinger = Task { await self.ping() }
	}

	/// Sends the channel's bytes to the Mac.
	public func send(_ bytes: Data) async throws {
		guard !closed else { throw RelayClientError.stopped }
		guard !bytes.isEmpty, bytes.count <= RelayLimits.maxBinary - 16 else { throw RelayClientError.invalid(RemoteKitError("relay data", "empty or too long")) }
		do {
			try await socket.send(.binary(bytes))
		} catch {
			throw RelayClientError.disconnected
		}
	}

	/// Says the mailbox notice was seen: the next `mail` is reported again.
	public func tookMail() { mailReported = false }

	/// Closes the socket.
	public func close() {
		end(.closed)
	}

	private func read() async {
		var refusal: RelayWhy?
		var busy: Int64?
		while !closed {
			let frame: RelayFrame
			do {
				frame = try await socket.receive()
			} catch let error as RelaySocketClosed {
				if let busy { return end(.busy(until: busy)) }
				if let refusal { return end(.refused(refusal)) }
				if let status = error.httpStatus { return end(.http(status)) }
				if let reason = error.reason, let why = RelayWhy(word: reason) { return end(.refused(why)) }
				return end(.lost)
			} catch {
				return end(.lost)
			}
			guard !closed else { return }
			lastHeard = options.clock.now()
			guard refusal == nil, busy == nil else { return end(.unreadable) }
			switch frame {
			case let .binary(bytes):
				guard !bytes.isEmpty, bytes.count <= RelayLimits.maxBinary else { return end(.unreadable) }
				post(.data(bytes))
			case let .text(text):
				// Once the Mac has added the phone, the socket is a listed phone's; it is sent what a joining one is.
				guard let message = try? RelayIncoming.parse(text, for: .joining) else { return end(.unreadable) }
				switch message {
				case let .refused(why): refusal = why
				case let .busy(until): busy = until
				case let .macOnline(online):
					guard macPresence != online else { break }
					macPresence = online
					post(.macOnline(online))
				case .mail:
					guard !mailReported else { break }
					mailReported = true
					post(.mail)
				case .pong: break
				default: return end(.unreadable)
				}
			}
		}
	}

	/// Pings, and ends the link once it has heard nothing, not even a pong, for `quietAfter`: a socket the network left
	/// half open would otherwise wait for ever.
	private func ping() async {
		while !closed {
			do {
				try await options.clock.sleep(milliseconds: options.pingEvery)
			} catch {
				return
			}
			guard !closed else { return }
			if options.clock.now() - lastHeard >= options.quietAfter { return end(.quiet) }
			try? await socket.send(.text(RelayOutgoing.ping.text))
		}
	}

	private func post(_ event: RelayLinkEvent) {
		if case .dropped = emit.yield(event) { end(.overflow) }
	}

	private func end(_ reason: RelayLinkEnd) {
		guard !closed else { return }
		closed = true
		endReason = reason
		socket.close()
		reader?.cancel()
		pinger?.cancel()
		emit.yield(.ended(reason))
		emit.finish()
	}
}

public enum RelayLinkEvent: Equatable, Sendable {
	/// The channel's bytes from the Mac. Only the channel proves who sent them.
	case data(Data)
	/// The relay says the Mac connected or went: a hint it can forge.
	case macOnline(Bool)
	/// The relay says something arrived in the mailbox: once until `tookMail`.
	case mail
	/// The socket closed. Nothing follows. If the caller's events were past the bound, `endReason` says why.
	case ended(RelayLinkEnd)
}

public enum RelayLinkEnd: Equatable, Sendable {
	/// Its user closed it.
	case closed
	case lost
	case busy(until: Int64)
	/// Refused, as the relay says, with this word: `window-ended` (the window closed before the Mac added it),
	/// `removed`, `replaced`.
	case refused(RelayWhy)
	case http(Int)
	case unreadable
	/// Nothing heard, not even a pong, for `RelayOptions.quietAfter`.
	case quiet
	/// More events waited unread than `RelayOptions.eventBuffer`.
	case overflow
}
