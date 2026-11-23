
import CryptoKit
import Foundation
import RemoteKit
import Synchronization

/// The protocol test (iphone.md 10, #678): the client, over the system's WebSocket, against the relay itself, run on
/// this computer by `scripts/relay-protocol-test` (Wrangler's local runtime on 127.0.0.1, the relay's own code with a
/// stand-in for App Attest's verifier that takes only the join's true client data hash, `relay/test/protocol`). A Mac
/// registers and connects; a phone joins its window and the two pass bytes; the Mac adds the phone and closes the
/// window; the phone connects as itself; the mailbox both ways; a dropped socket opened again; `busy` past a limit and
/// back; another Mac; pings; leaving; a redirect not followed; deleting the pairing. Every connection goes through
/// `URLSessionRelayConnector`, the join's through the one `join` makes by default,
/// which the relay would answer 403 if it sent an `Origin`, as a connection that does send one is shown to be.
///
/// The test's settings, which scripts/relay-protocol-test gives the relay: MIN_BUILD_MAC 100, MIN_BUILD_DEVICE 1.
enum ProtocolTest {
	static func run(relay url: URL) async {
		Check.section("The protocol, against the relay at \(url.absoluteString)")
		await Check.runs("the protocol, from registering to deleting") { try await whole(url) }
	}

	static func options(pingEvery: Int64 = 30_000, quietAfter: Int64 = 75_000) -> RelayOptions {
		var options = RelayOptions()
		options.backoff = RelayBackoff(first: 200, longest: 2_000)
		options.pingEvery = pingEvery
		options.quietAfter = quietAfter
		options.answerWithin = 10_000
		return options
	}

	static func whole(_ url: URL) async throws {
		let connector = URLSessionRelayConnector()
		let relayKey = P256.Signing.PrivateKey()
		let deviceKey = P256.Signing.PrivateKey()
		let mac = RelayBuild("200")!
		let phone = RelayBuild("3.1")!

		// Registering.
		await Check.throwsError("register below the Mac's minimum build", .refused(.updateRequired)) {
			try await RelayClient.register(relay: url, build: RelayBuild("99")!, relayKey: RelaySigner(relayKey), connector: connector)
		}
		let pairing = try await RelayClient.register(relay: url, build: mac, relayKey: RelaySigner(relayKey), connector: connector)
		print("ok   registered a pairing")

		// The Mac pings every second and takes its socket for dead after 8 seconds without a word, so that pongs that did
		// not come would show within the test (below).
		let macClient = try RelayClient(
			relay: url, role: .mac(pairing), build: mac, signer: RelaySigner(relayKey), connector: connector, options: options(pingEvery: 1_000, quietAfter: 8_000))
		let macEvents = Inbox(macClient.events)
		await macClient.start()
		let ready = try await macEvents.next("the Mac's ready") { if case let .macReady(ready) = $0 { ready } else { nil } }
		Check.equal(ready, RelayMacReady(devices: [], left: [], pending: true, mail: 0), "the Mac is ready, its pairing pending")

		// A Mac with another key is refused for its signature, and the connected Mac hears nothing.
		let stranger = try RelayClient(relay: url, role: .mac(pairing), build: mac, signer: RelaySigner(P256.Signing.PrivateKey()), connector: connector, options: options())
		let strangerEvents = Inbox(stranger.events)
		await stranger.start()
		Check.equal(try await strangerEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.refused(.signature), "a Mac with another key is refused")
		// A second copy holding the relay key is refused, and the connected Mac is told.
		let copy = try RelayClient(relay: url, role: .mac(pairing), build: mac, signer: RelaySigner(relayKey), connector: connector, options: options())
		let copyEvents = Inbox(copy.events)
		await copy.start()
		let (copyDrop, _) = try await copyEvents.next("the copy's drop") { if case let .disconnected(drop, at) = $0 { (drop, at) } else { nil } }
		Check.equal(copyDrop, .refused(.anotherMac), "a second Mac holding the relay key is refused while the first is connected")
		_ = try await macEvents.next("anotherMac") { $0 == .anotherMac ? true : nil }
		Check.that(!macEvents.all.contains(.anotherMac) || macEvents.all.filter { $0 == .anotherMac }.count == 1, "the connected Mac is told once, and not of the stranger")
		await copy.stop()

		// The join window, and a phone joining it.
		let secret = Bytes.random(32)
		let token = PairingSecrets.joinToken(secret: secret, pairing: pairing)
		let now = SystemRelayClock().now()
		try await macClient.openJoin(tokenHash: PairingSecrets.joinTokenHash(token), expires: now + 300_000)
		let relayAttestKey = AttestKeyID(bytes: Bytes.random(32))!
		let attest: @Sendable (Data) async throws -> RelayAttestation = { hash in
			// The stand-in takes exactly the client data hash the relay worked out, then the key's id.
			RelayAttestation(attestation: hash + Data(base64Encoded: relayAttestKey.text)!, keyId: relayAttestKey)
		}
		await Check.throwsError("a join with another token", .refused(.token)) {
			try await RelayClient.join(relay: url, pairing: pairing, build: phone, deviceKey: deviceKey.publicKey, token: Bytes.random(32), attest: attest, connector: connector)
		}
		// With the default connector, which `join` makes and lets go: the link keeps its socket's session alive.
		let link = try await RelayClient.join(relay: url, pairing: pairing, build: phone, deviceKey: deviceKey.publicKey, token: token, attest: attest)
		let linkEvents = Inbox(link.events)
		print("ok   joined, with the default connector, with the join's client data hash the relay worked out")
		let notice = try await macEvents.next("joined") { if case let .phoneJoined(notice) = $0 { notice } else { nil } }
		Check.equal(notice, RelayJoinNotice(slot: link.slot, deviceKey: deviceKey.publicKey, keyId: relayAttestKey), "the Mac hears of the joined phone, its key and the relay's App Attest key")

		// The channel's bytes on the joined socket, both ways.
		try await link.send(Data("pair".utf8))
		Check.equal(try await macEvents.next("bytes from the joined phone") { (event: RelayEvent) -> RelayEvent? in if case let .data(from, bytes) = event { RelayEvent.data(from: from, bytes) } else { nil } }, RelayEvent.data(from: link.slot, Data("pair".utf8)), "a joined phone's bytes reach the Mac under its slot")
		try await macClient.send(Data("challenge".utf8), to: link.slot)
		Check.equal(try await linkEvents.next("bytes to the joined phone") { (event: RelayLinkEvent) -> Data? in if case let .data(bytes) = event { bytes } else { nil } }, Data("challenge".utf8), "the Mac's bytes reach the joined phone")

		// The Mac adds it under the engine's id, with its own App Attest key, then closes the window.
		let device = DeviceID.random()
		await Check.throwsError("a device key that never joined", .refused(.notJoined)) {
			try await macClient.addDevice(device, deviceKey: P256.Signing.PrivateKey().publicKey, attestKeyId: AttestKeyID(bytes: Bytes.random(32))!)
		}
		try await macClient.addDevice(device, deviceKey: deviceKey.publicKey, attestKeyId: AttestKeyID(bytes: Bytes.random(32))!)
		try await macClient.closeJoin()
		try await macClient.send(Data("paired".utf8), to: device)
		Check.equal(try await linkEvents.next("bytes under the engine's id") { (event: RelayLinkEvent) -> Data? in if case let .data(bytes) = event { bytes } else { nil } }, Data("paired".utf8), "the same socket carries on under the engine's id, past closeJoin")
		try await link.send(Data("thanks".utf8))
		Check.equal(try await macEvents.next("bytes from the added phone") { (event: RelayEvent) -> RelayEvent? in if case let .data(from, bytes) = event { RelayEvent.data(from: from, bytes) } else { nil } }, RelayEvent.data(from: device, Data("thanks".utf8)), "and its bytes reach the Mac under it")
		await link.close()
		_ = try await macEvents.next("offline") { $0 == .offline(device) ? true : nil }

		// The phone connects as itself.
		let tracking = TrackingConnector(connector)
		let phoneClient = try RelayClient(relay: url, role: .device(pairing, device), build: phone, signer: RelaySigner(deviceKey), connector: tracking, options: options())
		let phoneEvents = Inbox(phoneClient.events)
		await phoneClient.start()
		let phoneReady = try await phoneEvents.next("the phone's ready") { if case let .deviceReady(online, mail) = $0 { (online, mail) } else { nil } }
		Check.that(phoneReady == (true, 0), "the phone is ready, the Mac there and nothing waiting")
		_ = try await macEvents.next("online") { $0 == .online(device) ? true : nil }
		try await phoneClient.setPushToken(String(repeating: "c0", count: 32), environment: .development)

		// The mailbox, both ways.
		let sealed = Data([4]) + Bytes.random(200)
		let toMac = ItemID.random()
		Check.equal(try await phoneClient.put(sealed, id: toMac, to: .mac), .stored, "a phone's item for the Mac")
		Check.equal(try await phoneClient.put(sealed, id: toMac, to: .mac), .alreadyThere, "the same put again")
		_ = try await macEvents.next("mail") { $0 == .mail ? true : nil }
		let macTook = try await macClient.take()
		Check.equal(macTook.items, [RelayMailItem(from: .device(device), id: toMac, item: sealed, presence: false)], "the Mac takes it")
		Check.equal(try await macClient.take().items, [], "and it is gone")
		let face = ItemID.random()
		_ = try await phoneClient.put(sealed, id: face, to: .mac, presence: true)
		Check.equal(try await macClient.take().items.map(\.presence), [true], "an item marked presence keeps its flag")
		let toPhone = ItemID.random()
		let state = ItemID.random()
		Check.equal(try await macClient.put(sealed, id: toPhone, to: .device(device)), .stored, "the Mac's item for the phone")
		try await macClient.putState(sealed, id: state, for: device)
		_ = try await phoneEvents.next("mail") { $0 == .mail ? true : nil }
		let phoneTook = try await phoneClient.take()
		Check.equal(phoneTook.items.map(\.id), [toPhone], "the phone takes the Mac's item")
		Check.equal(phoneTook.state, RelayStateItem(id: state, item: sealed), "and its state")
		await Check.throwsError("an item for a device not listed", .refused(.unknownDevice)) {
			try await macClient.put(sealed, id: ItemID.random(), to: .device(DeviceID.random()))
		}

		// The phone's socket drops, and is opened again.
		tracking.kill()
		let (drop, _) = try await phoneEvents.next("the phone's drop") { if case let .disconnected(drop, at) = $0 { (drop, at) } else { nil } }
		Check.equal(drop, .lost, "a socket closed under the client is lost")
		_ = try await phoneEvents.next("ready again") { if case .deviceReady = $0 { true } else { nil } }
		_ = try await macEvents.next("online again") { $0 == .online(device) ? true : nil }
		print("ok   a dropped socket opened again")

		// Past the limit of 100 messages a second, the phone is closed with busy, and comes back when the relay says.
		var sent = 0
		while sent < 400 {
			do {
				try await phoneClient.send(Data([UInt8(sent & 0xff)]))
			} catch {
				break
			}
			sent += 1
		}
		let (busy, retryAt) = try await phoneEvents.next("busy") { if case let .disconnected(drop, at) = $0 { (drop, at) } else { nil } }
		guard case let .busy(until) = busy else { throw Timeout(what: "busy, got \(busy)") }
		Check.that(retryAt >= until, "the phone comes back no sooner than the relay said")
		let held = try await macEvents.next("held") { if case let .held(who, until) = $0 { (who, until) } else { nil } }
		Check.that(held == (device, until), "the Mac is told the phone was held, and until when")
		_ = try await phoneEvents.next("ready after busy", seconds: 20) { if case .deviceReady = $0 { true } else { nil } }
		print("ok   busy after sending \(sent) messages, and back")

		// Ten seconds of nothing but pings: the relay's pongs keep the Mac's socket, which would otherwise be taken for dead.
		try await Task.sleep(for: .seconds(10))
		Check.that(!macEvents.all.contains { if case .disconnected = $0 { true } else { false } }, "the Mac, pinging every second, was answered and never dropped")

		// Leaving, and what is left after.
		try await phoneClient.leave()
		_ = try await macEvents.next("left") { $0 == .left(device) ? true : nil }
		Check.equal(try await phoneEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.refused(.left), "a phone that left stops")
		try await macClient.removeDevice(device)
		let gone = try RelayClient(relay: url, role: .device(pairing, device), build: phone, signer: RelaySigner(deviceKey), connector: connector, options: options())
		let goneEvents = Inbox(gone.events)
		await gone.start()
		Check.equal(try await goneEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.refused(.notListed), "a phone no longer listed is refused, and stops")

		// A web page's Origin is refused: the client's connections, which all passed, sent none.
		let origin = try RelayClient(relay: url, role: .mac(pairing), build: mac, signer: RelaySigner(relayKey), connector: OriginConnector(), options: options())
		let originEvents = Inbox(origin.events)
		await origin.start()
		Check.equal(try await originEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.http(403), "a connection with an Origin is refused with 403")

		// The test Worker answers 400 to a connection without the client's two fixed headers (User-Agent: pi2-relay-client,
		// Accept-Language: *), so every connection above carried them; one with URLSession's own is refused.
		let plain = try RelayClient(relay: url, role: .mac(pairing), build: mac, signer: RelaySigner(relayKey), connector: OriginConnector(origin: false), options: options())
		let plainEvents = Inbox(plain.events)
		await plain.start()
		Check.equal(try await plainEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.http(400), "a connection with URLSession's own headers, not the client's, is refused")

		// A redirect is not followed: the client stops with the 302, where following it would have connected.
		var redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		redirect.path = "/redirect"
		let redirected = try RelayClient(relay: redirect.url!, role: .mac(pairing), build: mac, signer: RelaySigner(relayKey), options: options())
		let redirectedEvents = Inbox(redirected.events)
		await redirected.start()
		Check.equal(try await redirectedEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.http(302), "a redirect is not followed")

		// Deleting the pairing.
		try await macClient.deletePairing()
		Check.equal(try await macEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.refused(.deleted), "the Mac's client stops once its pairing is deleted")
		let late = try RelayClient(relay: url, role: .mac(pairing), build: mac, signer: RelaySigner(relayKey), connector: connector, options: options())
		let lateEvents = Inbox(late.events)
		await late.start()
		Check.equal(try await lateEvents.next("stopped") { (event: RelayEvent) -> RelayStop? in if case let .stopped(why) = event { why } else { nil } }, RelayStop.refused(.unknownPairing), "a deleted pairing is unknown")
	}
}

/// The system's connector, keeping the last socket so that the test can close it under the client.
final class TrackingConnector: RelayConnector {
	private let inner: any RelayConnector
	private let last = Locked<(any RelaySocket)?>(nil)

	init(_ inner: any RelayConnector) { self.inner = inner }

	func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
		let socket = try await inner.connect(to: url, pairing: pairing)
		last.withLock { $0 = socket }
		return socket
	}

	func kill() { last.withLock { $0 }?.close() }
}

/// A connection as a web page's would be, with an `Origin`, which the relay must refuse.
/// Or, with `origin` false, one with URLSession's own headers, which name the system and its locale.
final class OriginConnector: RelayConnector {
	let origin: Bool

	init(origin: Bool = true) { self.origin = origin }

	func connect(to url: URL, pairing: PairingID?) async throws -> any RelaySocket {
		var request = URLRequest(url: url)
		if origin { request.setValue("https://example.com", forHTTPHeaderField: "Origin") }
		if let pairing { request.setValue(pairing.text, forHTTPHeaderField: "Pi2-Pairing") }
		let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
		task.resume()
		return OriginSocket(task)
	}
}

final class OriginSocket: RelaySocket, @unchecked Sendable {
	private let task: URLSessionWebSocketTask

	init(_ task: URLSessionWebSocketTask) { self.task = task }

	func send(_ frame: RelayFrame) async throws {
		do {
			if case let .text(text) = frame { try await task.send(.string(text)) }
		} catch {
			throw closed()
		}
	}

	func receive() async throws -> RelayFrame {
		do {
			if case let .string(text) = try await task.receive() { return .text(text) }
		} catch {}
		throw closed()
	}

	func close() { task.cancel() }

	private func closed() -> RelaySocketClosed {
		let status = (task.response as? HTTPURLResponse)?.statusCode
		return RelaySocketClosed(httpStatus: status == 101 ? nil : status)
	}
}
