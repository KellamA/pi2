
import CryptoKit
import Foundation
import RemoteKit

/// The marker session of the sealed-bytes check (iphone.md 10 and 13, decision 8; #683), run by
/// `scripts/relay-protocol-test --sealed` against the recording relay (`relay/test/sealed`) on this computer.
///
/// Both ends are RemoteKit's, made here with test keys: a Mac and a phone, each through the relay client over the
/// system's WebSocket. They pair (IKpsk2 over the joined phone's socket: the Mac's proof, `pair` with the device's
/// name, model and system, `paired` with the Mac's name), connect (KK: the proof, `attach`, `attached`), and carry the
/// markers of `relay/test/sealed/markers.json` every way the relay carries anything: the channel's lines both ways
/// (padded as the phone pads, one long enough to be cut into `more` frames with a marker across the cut), acks, pings,
/// `sessionEnd` and `bye`; request items for the Mac (one marked `presence`) and Mac items for the phone, both through
/// the mailbox; and the Mac's state for the phone. Each end checks that every marker reached the other, opened. Some
/// items are left in the mailbox, so that the relay holds them when its storage is read. Pushes: none, since the relay
/// at this head sends none (P20, #689).
///
/// It writes what the relay may not read, for `relay/test/sealed/check.mjs`: the markers, the ends' private keys and
/// the public keys the relay is never given, the pairing's secret, the channels' bindings and `pair`'s attestation; the
/// two keys it may be given, and the devices' ids; and the SHA-256 of every Noise message and sealed item it sent.
///
/// `--plant` is the check's own test: a second pairing whose phone sends a marker in clear as the channel's bytes and
/// whose Mac leaves it in clear in an item, which the check must find everywhere it went (and in the relay's console,
/// where check.mjs has the recording relay write it).
enum SealedSession {
	/// The places a marker goes, each sent once at least; markers.json gives one marker for each, and no other.
	static let places = [
		"device name", "device model", "device system", "Mac name", "method", "method in an item", "message", "transcript", "notification",
		"secret", "file preview", "project", "long line", "request item", "receipt", "state", "home address", "private address", "device event",
	]

	static func run(relay url: URL, markers path: String, out: String) async {
		Check.section("The marker session, through the recording relay at \(url.absoluteString)")
		let markers: [String: String]
		do {
			let list = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: String]] ?? []
			markers = Dictionary(list.compactMap { entry in entry["place"].flatMap { place in entry["text"].map { (place, $0) } } }, uniquingKeysWith: { first, _ in first })
			guard markers.count == list.count, Set(markers.keys) == Set(places) else {
				print("pi2-relay-check: \(path) must give one marker for each of: \(places.joined(separator: ", "))")
				exit(2)
			}
		} catch {
			print("pi2-relay-check: could not read \(path): \(error)")
			exit(2)
		}
		let ledger = Ledger()
		await Check.runs("the marker session") { try await session(url, markers, ledger) }
		for place in places {
			Check.that(ledger.arrived.contains(place), "the \(place) marker reached the other end, opened")
		}
		ledger.markers = places.map { ($0, markers[$0]!) }
		write(ledger, to: out)
	}

	static func plant(relay url: URL, out: String) async {
		Check.section("A marker planted in clear, through the recording relay at \(url.absoluteString)")
		let ledger = Ledger()
		await Check.runs("the planted session") { try await planted(url, ledger) }
		write(ledger, to: out)
	}

	/// What the session sent, as check.mjs reads it.
	final class Ledger: @unchecked Sendable {
		// Used from one task at a time: the session's steps run one after another.
		var markers: [(String, String)] = []
		var secrets: [Data] = []
		var relayKeys: [String] = []
		var deviceKeys: [String] = []
		var devices: [String] = []
		var noise: [Data] = []
		var items: [Data] = []
		var kept: [Data] = []
		var arrived: Set<String> = []

		func json() throws -> Data {
			func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }
			let value: [String: Any] = [
				"markers": markers.map { ["place": $0.0, "text": $0.1] },
				"secrets": secrets.map(\.hex),
				"keys": ["relayKey": relayKeys, "deviceKey": deviceKeys],
				"devices": devices,
				"noise": noise.map(digest),
				"items": items.map(digest),
				"kept": kept.map(digest),
			]
			return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
		}
	}

	static func write(_ ledger: Ledger, to out: String) {
		do {
			try ledger.json().write(to: URL(fileURLWithPath: out))
		} catch {
			Check.that(false, "writing \(out): \(error)")
		}
	}

	/// One end of a channel, and the way its messages go and come.
	struct End {
		let channel: Channel
		let send: @Sendable (Data) async throws -> Void
		let receive: @Sendable () async throws -> Data
		let ledger: Ledger

		func say(_ line: Data) async throws {
			for message in try channel.seal(line: line) {
				ledger.noise.append(message)
				try await send(message)
			}
		}

		func say(_ line: ControlLine) async throws { try await say(line.line) }

		func sayAck(_ count: UInt64) async throws {
			let message = try channel.sealAck(count)
			ledger.noise.append(message)
			try await send(message)
		}

		func sayPing() async throws {
			let message = try channel.sealPing()
			ledger.noise.append(message)
			try await send(message)
		}

		func sayBye() async throws {
			let message = try channel.sealBye()
			ledger.noise.append(message)
			try await send(message)
		}

		func hear() async throws -> ChannelEvent {
			while true {
				if let event = try channel.open(try await receive()) { return event }
			}
		}

		func hearLine() async throws -> Data {
			guard case let .line(line) = try await hear() else { throw RemoteKitError("marker session", "not a line") }
			return line
		}

		func hearControl() async throws -> ControlLine { try ControlLine.parse(try await hearLine()) }
	}

	static func session(_ url: URL, _ marker: [String: String], _ ledger: Ledger) async throws {
		func m(_ place: String) -> String { marker[place]! }
		let connector = URLSessionRelayConnector()

		// The Mac's keys and the phone's, as 3.2 has them, all in software: nothing of this Mac's.
		let relayKey = P256.Signing.PrivateKey()
		let identity = P256.Signing.PrivateKey()
		let macChannelKey = Curve25519.KeyAgreement.PrivateKey()
		let macRecord = P256.KeyAgreement.PrivateKey()
		let deviceKey = P256.Signing.PrivateKey()
		let presenceKey = P256.Signing.PrivateKey()
		let phoneChannelKey = Curve25519.KeyAgreement.PrivateKey()
		let phoneRecord = P256.KeyAgreement.PrivateKey()
		let secret = Bytes.random(32)
		ledger.secrets += [
			relayKey.rawRepresentation, identity.rawRepresentation, macChannelKey.rawRepresentation, macRecord.rawRepresentation,
			deviceKey.rawRepresentation, presenceKey.rawRepresentation, phoneChannelKey.rawRepresentation, phoneRecord.rawRepresentation, secret,
		]
		// The public keys the relay is never given, which must not be seen any more than the private ones; and the two it
		// is given, each only where its field says.
		ledger.secrets += [
			identity.publicKey.derRepresentation, macChannelKey.publicKey.rawRepresentation, macRecord.publicKey.derRepresentation,
			presenceKey.publicKey.derRepresentation, phoneChannelKey.publicKey.rawRepresentation, phoneRecord.publicKey.derRepresentation,
		]
		ledger.relayKeys = [PublicKeys.text(relayKey.publicKey)]
		ledger.deviceKeys = [PublicKeys.text(deviceKey.publicKey)]
		let addresses = [m("home address"), m("private address")]
		let macBuild = RelayBuild("200")!
		let phoneBuild = RelayBuild("3.1")!

		// The Mac registers and connects.
		let pairing = try await RelayClient.register(relay: url, build: macBuild, relayKey: RelaySigner(relayKey), connector: connector)
		let mac = try RelayClient(relay: url, role: .mac(pairing), build: macBuild, signer: RelaySigner(relayKey), connector: connector, options: ProtocolTest.options())
		let macEvents = Inbox(mac.events)
		await mac.start()
		_ = try await macEvents.next("the Mac's ready") { if case .macReady = $0 { true } else { nil } }
		let fromPhone: @Sendable () async throws -> Data = {
			try await macEvents.next("the phone's bytes") { if case let .data(_, bytes) = $0 { bytes } else { nil } }
		}

		// The window, and the phone joining it with the stand-in's attestation.
		let token = PairingSecrets.joinToken(secret: secret, pairing: pairing)
		try await mac.openJoin(tokenHash: PairingSecrets.joinTokenHash(token), expires: SystemRelayClock().now() + 300_000)
		let relayAttestKey = AttestKeyID(bytes: Bytes.random(32))!
		let link = try await RelayClient.join(
			relay: url, pairing: pairing, build: phoneBuild, deviceKey: deviceKey.publicKey, token: token,
			attest: { hash in RelayAttestation(attestation: hash + Data(base64Encoded: relayAttestKey.text)!, keyId: relayAttestKey) },
			connector: connector)
		let linkEvents = Inbox(link.events)
		let notice = try await macEvents.next("joined") { if case let .phoneJoined(notice) = $0 { notice } else { nil } }
		ledger.devices.append(notice.slot.text)

		// Pairing: IKpsk2, the phone first, over the joined socket.
		let payload = try PairingPayload(
			pairing: pairing, macName: m("Mac name"), channelKey: macChannelKey.publicKey, identityKey: identity.publicKey,
			recordKey: macRecord.publicKey, secret: secret, relay: url.absoluteString, addresses: addresses,
			expires: Int64(Date().timeIntervalSince1970) + 300)
		let phoneHandshake = try ChannelHandshake.pairingInitiator(payload: payload, channelKey: phoneChannelKey)
		let macHandshake = try ChannelHandshake.pairingResponder(pairing: pairing, secret: secret, channelKey: macChannelKey)
		let first = try phoneHandshake.writeMessage()
		ledger.noise.append(first)
		try await link.send(first)
		try macHandshake.readMessage(try await fromPhone())
		let second = try macHandshake.writeMessage()
		ledger.noise.append(second)
		try await mac.send(second, to: notice.slot)
		try phoneHandshake.readMessage(try await linkEvents.next("the second pairing message") { if case let .data(bytes) = $0 { bytes } else { nil } })
		let phonePairing = End(
			channel: try phoneHandshake.channel(), send: { try await link.send($0) },
			receive: { try await linkEvents.next("the Mac's bytes") { if case let .data(bytes) = $0 { bytes } else { nil } } }, ledger: ledger)
		phonePairing.channel.padding = Frame.paddingBlock
		let macPairingChannel = try macHandshake.channel()
		let macToSlot = End(channel: macPairingChannel, send: { try await mac.send($0, to: notice.slot) }, receive: fromPhone, ledger: ledger)
		ledger.secrets.append(macPairingChannel.handshakeHash)

		try await macToSlot.say(.mac(try MacProof.make(challenge: Bytes.random(32), pairing: pairing, binding: macPairingChannel.handshakeHash, identity: identity)))
		guard case let .mac(proof) = try await phonePairing.hearControl() else { throw RemoteKitError("marker session", "not the Mac's proof") }
		try proof.verify(identityKey: identity.publicKey, pairing: pairing, binding: phonePairing.channel.handshakeHash)
		let macAttestKey = AttestKeyID(bytes: Bytes.random(32))!
		let description = DeviceDescription(
			name: m("device name"), model: m("device model"), system: m("device system"), build: phoneBuild.text, deviceKey: deviceKey.publicKey,
			presenceKey: presenceKey.publicKey, channelKey: phoneChannelKey.publicKey, recordKey: phoneRecord.publicKey)
		let pairAttestation = Bytes.random(1_500)
		ledger.secrets.append(pairAttestation)
		try await phonePairing.say(.pair(try PairClaim.make(
			device: description, attestation: pairAttestation, keyId: macAttestKey.text, pairing: pairing,
			binding: phonePairing.channel.handshakeHash, deviceKey: deviceKey)))
		guard case let .pair(claim) = try await macToSlot.hearControl() else { throw RemoteKitError("marker session", "not a claim") }
		try claim.verify(pairing: pairing, binding: macPairingChannel.handshakeHash, handshakeChannelKey: macPairingChannel.remoteChannelKey)
		if claim.device.name == m("device name") { ledger.arrived.insert("device name") }
		if claim.device.model == m("device model") { ledger.arrived.insert("device model") }
		if claim.device.system == m("device system") { ledger.arrived.insert("device system") }

		// The Mac adds the phone under the engine's id, closes the window, and answers `paired` on the same socket.
		let device = DeviceID.random()
		ledger.devices.append(device.text)
		try await mac.addDevice(device, deviceKey: claim.device.deviceKey, attestKeyId: macAttestKey)
		try await mac.closeJoin()
		let macToDevice = End(channel: macPairingChannel, send: { try await mac.send($0, to: device) }, receive: fromPhone, ledger: ledger)
		// The home key, which tags the Mac's Bonjour record (#815): the relay must never see it.
		let homeKey = HomeKey.random()
		ledger.secrets.append(homeKey.rawRepresentation)
		try await macToDevice.say(.paired(try Paired(device: device, pairing: pairing, name: m("Mac name"), addresses: addresses, homeKey: homeKey)))
		guard case let .paired(paired) = try await phonePairing.hearControl() else { throw RemoteKitError("marker session", "not paired") }
		if paired.device == device, paired.name == m("Mac name") { ledger.arrived.insert("Mac name") }
		if paired.addresses == addresses { ledger.arrived.formUnion(["home address", "private address"]) }
		await link.close()
		_ = try await macEvents.next("offline") { $0 == .offline(device) ? true : nil }
		print("ok   paired over the relay")

		// The phone connects as itself: KK, the Mac's proof with the engine's challenge, attach, attached.
		let phone = try RelayClient(
			relay: url, role: .device(pairing, device), build: phoneBuild, signer: RelaySigner(deviceKey), connector: connector, options: ProtocolTest.options())
		let phoneEvents = Inbox(phone.events)
		await phone.start()
		_ = try await phoneEvents.next("the phone's ready") { if case .deviceReady = $0 { true } else { nil } }
		_ = try await macEvents.next("online") { $0 == .online(device) ? true : nil }
		let phoneConnecting = try ChannelHandshake.connection(
			initiator: true, pairing: pairing, device: device, channelKey: phoneChannelKey, remoteChannelKey: macChannelKey.publicKey)
		// On the relay path the device's id is in front of its bytes, so pi² Remote knows which device calls.
		let macConnecting = try ChannelHandshake.connection(
			initiator: false, pairing: pairing, device: device, channelKey: macChannelKey, remoteChannelKey: phoneChannelKey.publicKey)
		let hello = try phoneConnecting.writeMessage()
		ledger.noise.append(hello)
		try await phone.send(hello)
		try macConnecting.readMessage(try await fromPhone())
		let answer = try macConnecting.writeMessage()
		ledger.noise.append(answer)
		try await mac.send(answer, to: device)
		let fromMac: @Sendable () async throws -> Data = {
			try await phoneEvents.next("the Mac's bytes") { if case let .data(_, bytes) = $0 { bytes } else { nil } }
		}
		try phoneConnecting.readMessage(try await fromMac())
		let phoneEnd = End(channel: try phoneConnecting.channel(), send: { try await phone.send($0) }, receive: fromMac, ledger: ledger)
		phoneEnd.channel.padding = Frame.paddingBlock
		let macEnd = End(channel: try macConnecting.channel(), send: { try await mac.send($0, to: device) }, receive: fromPhone, ledger: ledger)
		ledger.secrets.append(macEnd.channel.handshakeHash)

		let challenge = Bytes.random(32)
		try await macEnd.say(.mac(try MacProof.make(challenge: challenge, pairing: pairing, binding: macEnd.channel.handshakeHash, identity: identity)))
		guard case let .mac(connectionProof) = try await phoneEnd.hearControl() else { throw RemoteKitError("marker session", "not the Mac's proof") }
		try connectionProof.verify(identityKey: identity.publicKey, pairing: pairing, binding: phoneEnd.channel.handshakeHash)
		try await phoneEnd.say(.attach(try AttachClaim.make(
			pairing: pairing, device: device, session: nil, received: nil, binding: phoneEnd.channel.handshakeHash, challenge: connectionProof.challenge,
			build: phoneBuild.text, deviceKey: deviceKey, presenceKey: presenceKey)))
		guard case let .attach(attach) = try await macEnd.hearControl() else { throw RemoteKitError("marker session", "not an attach") }
		try attach.verify(
			deviceKey: deviceKey.publicKey, presenceKey: presenceKey.publicKey, pairing: pairing, device: device, binding: macEnd.channel.handshakeHash,
			challenge: challenge)
		try await macEnd.say(.attached(Attached(session: SessionID("s_marker")!, resume: false)))
		guard case .attached = try await phoneEnd.hearControl() else { throw RemoteKitError("marker session", "not attached") }
		phoneEnd.channel.maxLineLength = Lines.defaultMaxLength
		macEnd.channel.maxLineLength = Lines.defaultMaxLength
		print("ok   connected and attached over the relay")

		// The engine's lines, both ways, as the engine writes them: what a device sends and what it is sent.
		func line(_ value: JSONValue) -> Data { JSON.write(value) }
		func s(_ text: String) -> JSONValue { .string(text) }
		let exchanges: [(from: End, to: End, line: Data, places: [String])] = [
			(phoneEnd, macEnd, line(.object([("id", .integer(1)), ("method", s(m("method"))), ("params", .object([("conversation", .integer(7)), ("text", s(m("message")))]))])), ["method", "message"]),
			(phoneEnd, macEnd, longLine(m("long line")), ["long line"]),
			(macEnd, phoneEnd, line(.object([("event", s("transcript")), ("entries", .array([
				.object([("text", s(m("transcript")))]), .object([("preview", s(m("file preview")))]),
			]))])), ["transcript", "file preview"]),
			(macEnd, phoneEnd, line(.object([("event", s("needs")), ("items", .array([.object([("project", s(m("project"))), ("text", s(m("notification")))])]))])), ["project", "notification"]),
			(macEnd, phoneEnd, line(.object([("event", s("secret")), ("value", s(m("secret")))])), ["secret"]),
			(macEnd, phoneEnd, line(.object([("event", s("device")), ("text", s(m("device event"))), ("name", s(m("device name")))])), ["device event"]),
		]
		var received: [ObjectIdentifier: UInt64] = [:]
		for exchange in exchanges {
			try await exchange.from.say(exchange.line)
			let heard = try await exchange.to.hearLine()
			received[ObjectIdentifier(exchange.to.channel), default: 0] += 1
			if heard == exchange.line { ledger.arrived.formUnion(exchange.places) }
		}
		// Acks and pings, each way, and the end of the session and of the channel.
		try await phoneEnd.sayAck(received[ObjectIdentifier(phoneEnd.channel)] ?? 0)
		Check.equal(try await macEnd.hear(), .ack(4), "the phone's ack reaches the Mac")
		try await macEnd.sayAck(received[ObjectIdentifier(macEnd.channel)] ?? 0)
		Check.equal(try await phoneEnd.hear(), .ack(2), "the Mac's ack reaches the phone")
		try await phoneEnd.sayPing()
		Check.equal(try await macEnd.hear(), .ping, "a ping reaches the Mac")
		try await macEnd.sayPing()
		Check.equal(try await phoneEnd.hear(), .ping, "a ping reaches the phone")
		try await phoneEnd.say(.sessionEnd)
		guard case .sessionEnd = try await macEnd.hearControl() else { throw RemoteKitError("marker session", "not sessionEnd") }
		try await phoneEnd.sayBye()
		Check.equal(try await macEnd.hear(), .bye, "the phone's bye reaches the Mac")
		print("ok   the engine's lines both ways, acks, pings, sessionEnd and bye")

		// The mailbox, the phone's way: request items, one of them a "face" one; two taken by the Mac, one left.
		func request(_ method: String, _ params: JSONValue, presence: Bool, keep: Bool) async throws -> (ItemID, String, JSONValue) {
			let id = ItemID.random()
			let item = try RequestItem.make(method: method, params: params, pairing: pairing, device: device, id: id, deviceKey: deviceKey, presenceKey: presenceKey)
			let sealed = try SealedItem.seal(item.plaintext, to: ItemAddress(pairing: pairing, reader: .mac, id: id), readerKey: macRecord.publicKey, writerKey: phoneRecord)
			ledger.items.append(sealed)
			if keep { ledger.kept.append(sealed) }
			Check.equal(try await phone.put(sealed, id: id, to: .mac, presence: presence), .stored, "the phone's request item is stored")
			return (id, method, params)
		}
		let sent = [
			try await request(m("method"), .object([("conversation", .integer(7)), ("text", s(m("message")))]), presence: false, keep: false),
			try await request(m("method in an item"), .object([("answer", s(m("request item"))), ("project", s(m("project")))]), presence: true, keep: false),
		]
		let macTook = try await mac.take()
		Check.equal(macTook.items.map(\.id), sent.map(\.0), "the Mac takes the phone's two request items")
		for (taken, (id, method, params)) in zip(macTook.items, sent) {
			let opened = try SealedItem.openRequest(
				taken.item, at: ItemAddress(pairing: pairing, reader: .mac, id: id), readerKey: macRecord, writer: device,
				writerRecordKey: phoneRecord.publicKey, deviceKey: deviceKey.publicKey, presenceKey: presenceKey.publicKey)
			if opened.method == method, opened.params == params {
				ledger.arrived.insert(method == m("method") ? "method" : "method in an item")
				if method == m("method in an item") { ledger.arrived.insert("request item") }
			}
		}
		// As pi² Remote does once it has opened, verified and kept them, so that a repeat is dropped.
		await mac.remember(macTook.items)
		_ = try await request(m("method"), .object([("text", s(m("message")))]), presence: false, keep: true)

		// The Mac's way: a receipt and the phone's state, taken by the phone; then another of each, left.
		func macItem(kind: String, number: Int64?, body: JSONValue) throws -> (ItemID, Data) {
			let id = ItemID.random()
			let item = try MacItem.make(kind: kind, number: number, body: body, pairing: pairing, device: device, id: id, identity: identity)
			let sealed = try SealedItem.seal(item.plaintext, to: ItemAddress(pairing: pairing, reader: .device(device), id: id), readerKey: phoneRecord.publicKey, writerKey: macRecord)
			ledger.items.append(sealed)
			return (id, sealed)
		}
		let receiptBody = JSONValue.object([("text", s(m("receipt")))])
		let stateBody = JSONValue.object([("projects", .array([.object([("name", s(m("project")))])])), ("text", s(m("state")))])
		let (receiptID, receipt) = try macItem(kind: "receipt", number: nil, body: receiptBody)
		Check.equal(try await mac.put(receipt, id: receiptID, to: .device(device)), .stored, "the Mac's receipt is stored")
		let (stateID, state) = try macItem(kind: "state", number: 1, body: stateBody)
		try await mac.putState(state, id: stateID, for: device)
		let phoneTook = try await phone.take()
		let readerKey = phoneRecord
		func open(_ item: Data, _ id: ItemID) throws -> MacItem {
			try SealedItem.openMacItem(item, at: ItemAddress(pairing: pairing, reader: .device(device), id: id), readerKey: readerKey, writerRecordKey: macRecord.publicKey, identityKey: identity.publicKey)
		}
		if let taken = phoneTook.items.first, phoneTook.items.count == 1, try open(taken.item, taken.id).body == receiptBody { ledger.arrived.insert("receipt") }
		if let taken = phoneTook.state, try open(taken.item, taken.id).body == stateBody { ledger.arrived.insert("state") }
		await phone.remember(phoneTook.items)
		let (keptID, keptReceipt) = try macItem(kind: "receipt", number: nil, body: receiptBody)
		ledger.kept.append(keptReceipt)
		Check.equal(try await mac.put(keptReceipt, id: keptID, to: .device(device)), .stored, "another receipt, left for the phone")
		let (keptStateID, keptState) = try macItem(kind: "state", number: 2, body: stateBody)
		ledger.kept.append(keptState)
		try await mac.putState(keptState, id: keptStateID, for: device)
		print("ok   the mailbox both ways, and the Mac's state")

		// The phone's push token, which the relay keeps (5.3). Pushes themselves are P20's (#689): none at this head.
		try await phone.setPushToken(Bytes.random(32).hex, environment: .development)

		await phone.stop()
		await mac.stop()
	}

	/// A line of some 100 KB, cut into a `more` frame and a `data` frame, with the marker across the cut.
	static func longLine(_ marker: String) -> Data {
		let prefix = Data(#"{"id":2,"method":"conversation.submit","params":{"text":""#.utf8)
		let cut = Frame.maxBodyLength - marker.utf8.count / 2
		let before = Data(repeating: UInt8(ascii: "a"), count: cut - prefix.count)
		let after = Data(repeating: UInt8(ascii: "b"), count: 40_000)
		return prefix + before + Data(marker.utf8) + after + Data(#""}}"#.utf8)
	}

	/// The check's own test: a pairing whose phone sends a marker in clear as the channel's bytes, and whose Mac leaves the
	/// same in clear in an item for the phone, which stays in the mailbox. Neither is the session's Noise or sealed item.
	static func planted(_ url: URL, _ ledger: Ledger) async throws {
		let marker = "pi2 planted marker in clear 5a0c"
		ledger.markers = [("planted", marker)]
		let connector = URLSessionRelayConnector()
		let relayKey = P256.Signing.PrivateKey()
		let deviceKey = P256.Signing.PrivateKey()
		ledger.relayKeys = [PublicKeys.text(relayKey.publicKey)]
		ledger.deviceKeys = [PublicKeys.text(deviceKey.publicKey)]
		let pairing = try await RelayClient.register(relay: url, build: RelayBuild("200")!, relayKey: RelaySigner(relayKey), connector: connector)
		let mac = try RelayClient(relay: url, role: .mac(pairing), build: RelayBuild("200")!, signer: RelaySigner(relayKey), connector: connector, options: ProtocolTest.options())
		let macEvents = Inbox(mac.events)
		await mac.start()
		_ = try await macEvents.next("the Mac's ready") { if case .macReady = $0 { true } else { nil } }
		let token = Bytes.random(32)
		try await mac.openJoin(tokenHash: PairingSecrets.joinTokenHash(token), expires: SystemRelayClock().now() + 300_000)
		let attestKey = AttestKeyID(bytes: Bytes.random(32))!
		let link = try await RelayClient.join(
			relay: url, pairing: pairing, build: RelayBuild("3.1")!, deviceKey: deviceKey.publicKey, token: token,
			attest: { hash in RelayAttestation(attestation: hash + Data(base64Encoded: attestKey.text)!, keyId: attestKey) }, connector: connector)
		let notice = try await macEvents.next("joined") { if case let .phoneJoined(notice) = $0 { notice } else { nil } }
		ledger.devices.append(notice.slot.text)

		try await link.send(Data(marker.utf8))
		let bytes = try await macEvents.next("the planted bytes") { if case let .data(_, bytes) = $0 { bytes } else { nil } }
		Check.equal(bytes, Data(marker.utf8), "the planted bytes pass the relay as they are")

		let device = DeviceID.random()
		ledger.devices.append(device.text)
		try await mac.addDevice(device, deviceKey: deviceKey.publicKey, attestKeyId: AttestKeyID(bytes: Bytes.random(32))!)
		try await mac.closeJoin()
		// An uncompressed point's first byte and then the marker in clear: the relay takes it for a sealed item.
		let item = Data([4]) + Data(repeating: 0, count: 80) + Data(marker.utf8)
		ledger.kept.append(item)
		Check.equal(try await mac.put(item, id: ItemID.random(), to: .device(device)), .stored, "the planted item is stored")
		await link.close()
		await mac.stop()
		print("ok   planted a marker in clear as bytes and as an item")
	}
}
