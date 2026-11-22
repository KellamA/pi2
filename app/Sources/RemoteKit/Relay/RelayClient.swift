
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
// - Items taken from the mailbox are checked against the ids taken in the last 25 hours (`RelayItemMemory`), and a
//   repeat is dropped: the relay can deliver an item twice, and a Mac item that is not a state has no number to refuse
//   it by. The memory is the user's to keep across launches (`itemMemory`, and the initialiser's).

/// A key that proves an end at the relay: the Mac's relay key, or the phone's device key (iphone.md 3.2, 3.4). It signs
/// only `RelayProof`'s labelled text over a challenge of exactly 32 bytes.
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
		let text = try RelayProof.text(purpose, pairing: pairing, device: device, challenge: challenge)
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

/// What the client reports as it goes.
public enum RelayEvent: Equatable, Sendable {
	/// Opening a socket; `attempt` counts the attempts since the last steady connection.
	case connecting(attempt: Int)
	/// The Mac is connected and proved.
	case macReady(RelayMacReady)
	/// The phone is connected and proved.
	case deviceReady(macOnline: Bool, mail: Int)
	/// The channel's bytes: to the Mac, from the device named; to a phone, from the Mac.
	case data(from: DeviceID?, Data)
	case online(DeviceID)
	case offline(DeviceID)
	case phoneJoined(RelayJoinNotice)
	case left(DeviceID)
	/// Another copy of pi² Remote holding the relay key tried to connect as this Mac (3.4).
	case anotherMac
	/// A phone was closed past a limit, until then (6.6).
	case held(DeviceID, until: Int64)
	/// The Mac connected or went away, as a phone is told.
	case macOnline(Bool)
	/// Something arrived in this end's mailbox: `take` it.
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
}

/// Why the client stopped.
public enum RelayStop: Equatable, Sendable {
	/// Its user stopped it.
	case stopped
	/// A refusal that trying again cannot change: the pairing or the device is gone (`unknown-pairing`, `not-listed`,
	/// `removed`, `left`, `deleted`), the key is not the one on record (`signature`), the build is too old
	/// (`update-required`), another connection took this one's place (`replaced`), or a word this client does not know.
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
	/// Items dropped as repeats of ones taken in the last 25 hours.
	public let repeats: Int
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
	private var endWaiters: [CheckedContinuation<RelayStop?, Never>] = []
	private var memory: RelayItemMemory

	public init(
		relay url: URL, role: Role, build: RelayBuild, signer: RelaySigner, connector: any RelayConnector = URLSessionRelayConnector(),
		options: RelayOptions = RelayOptions(), itemMemory: RelayItemMemory = RelayItemMemory()
	) {
		self.url = url
		self.role = role
		self.build = build
		self.signer = signer
		self.connector = connector
		self.options = options
		memory = itemMemory
		(events, emit) = AsyncStream.makeStream(of: RelayEvent.self, bufferingPolicy: .unbounded)
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

	/// The ids of items taken in the last 25 hours, for its user to keep across launches and give back to the next client.
	public var itemMemory: RelayItemMemory { memory }

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

	/// Sends the channel's bytes to a device; the relay puts nothing round them but takes the id off. If the device is not
	/// connected, the relay says so with an `offline` event.
	public func send(_ bytes: Data, to device: DeviceID) async throws {
		try requireMac()
		guard let deviceBytes = Base64URL.decode(String(device.text.dropFirst(4)), count: 16) else { throw RelayClientError.invalid(RemoteKitError("relay data", "not a device")) }
		try await sendBinary(deviceBytes + bytes, body: bytes.count)
	}

	// MARK: A phone's requests

	/// Sends the channel's bytes to the Mac. If the Mac is not connected, the relay says so with `macOnline(false)`.
	public func send(_ bytes: Data) async throws {
		try requireDevice()
		try await sendBinary(bytes, body: bytes.count)
	}

	/// Gives the relay this phone's push token (7).
	public func setPushToken(_ apns: String, environment: RelayPushEnvironment) async throws {
		try requireDevice()
		try await expectOK(.token(apns: apns, environment: environment), .token)
	}

	/// Removes this phone from the pairing at the relay (3.6), signed with the device key over this connection's
	/// challenge. The relay closes the socket, and the client stops with `left`.
	public func leave() async throws {
		guard case let .device(pairing, device) = role else { throw RelayClientError.wrongEnd }
		guard !finished else { throw RelayClientError.stopped }
		guard ready, let socket, let challenge else { throw RelayClientError.notConnected }
		let signature = try signer.prove(.leave, pairing: pairing, device: device, challenge: challenge)
		do {
			try await socket.send(.text(RelayOutgoing.leave(signature: signature).text))
		} catch {
			throw RelayClientError.disconnected
		}
		let stop = await withCheckedContinuation { endWaiters.append($0) }
		guard stop == .refused(.left) else { throw RelayClientError.disconnected }
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

	/// Takes what waits in this end's mailbox. The relay deletes each item as it hands it over.
	public func take() async throws -> RelayTaken {
		guard case let .taken(items, state) = try await request(.take, .take) else { throw RelayClientError.unreadable }
		let now = options.clock.now()
		let fresh = items.filter { memory.isNew($0, at: now) }
		return RelayTaken(items: fresh, state: state, repeats: items.count - fresh.count)
	}

	// MARK: Registering and joining, each on a socket of its own

	/// Registers a new pairing for this Mac's relay key (5.3), and gives its id. The pairing is pending, and deleted by
	/// the relay 15 minutes later unless a phone that joined it is added.
	public static func register(
		relay url: URL, build: RelayBuild, relayKey: RelaySigner, connector: any RelayConnector = URLSessionRelayConnector(),
		options: RelayOptions = RelayOptions()
	) async throws -> PairingID {
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
		let socket = try await open(connector, url, pairing: pairing)
		let deadline = closing(socket, after: options.answerWithin, clock: options.clock)
		var handedOver = false
		defer {
			deadline.cancel()
			if !handedOver { socket.close() }
		}
		try await sendText(socket, .hello(pairing: pairing, device: nil, role: .device, build: build))
		guard case let .challenge(challenge) = try await nextMessage(socket, .joining) else { throw RelayClientError.unreadable }
		let attestation = try await attest(PairingSecrets.joinClientDataHash(challenge: challenge, deviceKey: deviceKey))
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
			emit.yield(.connecting(attempt: attempt))
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
				emit.yield(.disconnected(drop, retryAt: now + wait))
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
						emit.yield(.macReady(info))
					case let (.deviceReady(macOnline, mail), _?) where role.end == .device:
						ready = true
						readyAt = options.clock.now()
						emit.yield(.deviceReady(macOnline: macOnline, mail: mail))
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
			guard let request = pending, request.kind == .take, request.state == nil, request.items.count < RelayLimits.maxTaken else { throw Unreadable() }
			request.items.append(item)
		case let .state(state):
			guard let request = pending, request.kind == .take, request.state == nil else { throw Unreadable() }
			request.state = state
		case let .taken(count):
			guard let request = pending, request.kind == .take, count == request.items.count + (request.state == nil ? 0 : 1) else { throw Unreadable() }
			pending = nil
			request.finish(.success(.taken(request.items, request.state)))
		case .mail: emit.yield(.mail)
		case let .online(device): emit.yield(.online(device))
		case let .offline(device): emit.yield(.offline(device))
		case let .phoneJoined(notice): emit.yield(.phoneJoined(notice))
		case let .left(device): emit.yield(.left(device))
		case .anotherMac: emit.yield(.anotherMac)
		case let .held(device, until): emit.yield(.held(device, until: until))
		case let .macOnline(online): emit.yield(.macOnline(online))
		case .challenge, .registered, .macReady, .deviceReady, .joined, .refused, .busy:
			throw Unreadable()
		}
	}

	/// The channel's bytes from the relay: to the Mac, with the device's 16-byte id in front.
	private func deliver(_ bytes: Data) throws {
		guard !bytes.isEmpty, bytes.count <= RelayLimits.maxBinary else { throw Unreadable() }
		if role.end == .mac {
			guard bytes.count > 16, let device = DeviceID("dev_" + Base64URL.encode(bytes.prefix(16))) else { throw Unreadable() }
			emit.yield(.data(from: device, Data(bytes.dropFirst(16))))
		} else {
			emit.yield(.data(from: nil, bytes))
		}
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
			// The relay's own time to come back, and up to a second more, so that the ends it closed together spread out.
			let wait = min(max(until - now, 0), 24 * 3_600_000)
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
		resumeEndWaiters(reason)
		emit.yield(.stopped(reason))
		emit.finish()
	}

	private func resumeEndWaiters(_ reason: RelayStop?) {
		let waiters = endWaiters
		endWaiters = []
		for waiter in waiters { waiter.resume(returning: reason) }
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
/// once, with an App Attest key of its own.
public actor RelayJoinLink {
	/// The slot the relay gave the joined phone, until the Mac adds it under the engine's id.
	public nonisolated let slot: DeviceID
	public nonisolated let events: AsyncStream<RelayLinkEvent>
	private let emit: AsyncStream<RelayLinkEvent>.Continuation
	private let socket: any RelaySocket
	private let options: RelayOptions
	private var reader: Task<Void, Never>?
	private var pinger: Task<Void, Never>?
	private var closed = false

	init(socket: any RelaySocket, slot: DeviceID, options: RelayOptions) {
		self.socket = socket
		self.slot = slot
		self.options = options
		(events, emit) = AsyncStream.makeStream(of: RelayLinkEvent.self, bufferingPolicy: .unbounded)
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
			guard refusal == nil, busy == nil else { return end(.unreadable) }
			switch frame {
			case let .binary(bytes):
				guard !bytes.isEmpty, bytes.count <= RelayLimits.maxBinary else { return end(.unreadable) }
				emit.yield(.data(bytes))
			case let .text(text):
				// Once the Mac has added the phone, the socket is a listed phone's; it is sent what a joining one is.
				guard let message = try? RelayIncoming.parse(text, for: .joining) else { return end(.unreadable) }
				switch message {
				case let .refused(why): refusal = why
				case let .busy(until): busy = until
				case let .macOnline(online): emit.yield(.macOnline(online))
				case .mail: emit.yield(.mail)
				case .pong: break
				default: return end(.unreadable)
				}
			}
		}
	}

	private func ping() async {
		while !closed {
			do {
				try await options.clock.sleep(milliseconds: options.pingEvery)
			} catch {
				return
			}
			guard !closed else { return }
			try? await socket.send(.text(RelayOutgoing.ping.text))
		}
	}

	private func end(_ reason: RelayLinkEnd) {
		guard !closed else { return }
		closed = true
		socket.close()
		reader?.cancel()
		pinger?.cancel()
		emit.yield(.ended(reason))
		emit.finish()
	}
}

public enum RelayLinkEvent: Equatable, Sendable {
	case data(Data)
	case macOnline(Bool)
	case mail
	/// The socket closed. Nothing follows.
	case ended(RelayLinkEnd)
}

public enum RelayLinkEnd: Equatable, Sendable {
	/// Its user closed it.
	case closed
	case lost
	case busy(until: Int64)
	/// Refused with this word: `window-ended` (the window closed before the Mac added it), `removed`, `replaced`.
	case refused(RelayWhy)
	case http(Int)
	case unreadable
}
