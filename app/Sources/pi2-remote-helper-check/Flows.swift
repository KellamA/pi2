import CryptoKit
import Darwin
import Foundation
import RemoteKit
import pi2_remote

/// pi² Remote in loopback mode, with this check as its engine and as a phone: the home path's listener, pairing,
/// attaching, a session's lines both ways, resuming, `sessionEnd`, a session closed by the engine, revocation, and its
/// own list of devices (docs/iphone.md 3.3, 3.4, 5.4, 5.6, 5.8).
enum Flows {
	static let team = "ABCDE12345"
	static let switches = JSONValue.object([("on", .bool(true)), ("relay", .bool(true)), ("home", .bool(true)), ("direct", .bool(false)), ("preview", .bool(true))])

	struct Mac {
		let pairing: PairingID
		let port: UInt16
		let identity: P256.Signing.PublicKey
		let channel: Curve25519.KeyAgreement.PublicKey
		let record: P256.KeyAgreement.PublicKey
	}

	nonisolated(unsafe) static var hello0: JSONValue?
	nonisolated(unsafe) static var relayKeyText: String?

	/// The home key pi² Remote keeps, read from its list of devices in the data folder, where it is kept with them.
	static func storedHomeKey(_ home: URL) -> HomeKey? {
		guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("remote-devices.json").path) else { return nil }
		return (try? KeptDevices(data: data))?.homeKey
	}

	static func listed(_ home: URL) -> [String] {
		guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("remote-devices.json").path), let value = try? JSON.parse(data),
		      case let .array(items)? = value["devices"]
		else { return [] }
		return items.compactMap { $0["id"]?.stringValue }
	}

	/// `start`, and the `remote.hello` it brings.
	static func hello(_ engine: FakeEngine, pairing: PairingID, devices: [String] = []) -> Mac? {
		engine.event("start", [
			("relay", .string("ws://127.0.0.1:9/v1")), ("switches", switches), ("pairing", .string(pairing.text)),
			("devices", .array(devices.map { .object([("id", .string($0))]) })), ("minimumBuild", .string("1")),
		])
		guard let hello = engine.request("remote.hello") else { return nil }
		engine.answer(hello.id)
		hello0 = hello.params
		relayKeyText = hello.params["macKeys"]?["relay"]?.stringValue
		let keys = hello.params["macKeys"]
		guard let identity = keys?["identity"]?.stringValue.flatMap(PublicKeys.signingKey), let channel = keys?["channel"]?.stringValue.flatMap(PublicKeys.channelKey),
		      let record = keys?["record"]?.stringValue.flatMap(PublicKeys.agreementKey), PublicKeys.signingKey(fromBase64URL: keys?["relay"]?.stringValue ?? "") != nil,
		      case let .array(addresses)? = hello.params["addresses"], addresses.count == 1, let address = addresses[0].stringValue,
		      address.hasPrefix("127.0.0.1:"), let port = UInt16(address.dropFirst("127.0.0.1:".count))
		else {
			Check.expect(false, "remote.hello gives the Mac's four public keys and one address, on 127.0.0.1", JSON.text(hello.params))
			return nil
		}
		Check.expect(keys?["secureEnclave"]?.boolValue == false, "a development build says its keys are not in a Secure Enclave")
		Check.expect(hello.params["pairing"]?.stringValue == pairing.text, "and names the pairing start gave it")
		return Mac(pairing: pairing, port: port, identity: identity, channel: channel, record: record)
	}

	/// Pairs a phone through a window the check opens, as the engine would; returns the device's id.
	nonisolated(unsafe) static var home = URL(fileURLWithPath: "/nonexistent")

	static func pair(_ engine: FakeEngine, mac: Mac, keys: PhoneKeys, claim: String) -> DeviceID? {
		let secret = Bytes.random(32)
		let expires = Int64(Date().timeIntervalSince1970) + 300
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string("x")), ("expires", .integer(expires * 1000))])
		let payload = try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: secret,
			relay: "ws://127.0.0.1:9/v1", addresses: ["127.0.0.1:\(mac.port)"], expires: expires)
		guard let phone = Phone(port: mac.port), let paired = phone.pair(payload: payload, keys: keys, team: team) else { return nil }
		guard let request = engine.request("remote.pairClaim") else { return nil }
		Check.expect(request.params.keys == ["claim", "binding", "challenge", "path"], "remote.pairClaim takes the claim, the binding, the challenge and the path", JSON.text(request.params))
		Check.expect(request.params["challenge"]?.stringValue == Base64URL.encode(paired.challenge), "with the exact challenge the Mac sent the phone")
		Check.expect(request.params["binding"]?.stringValue == Base64URL.encode(paired.binding) && request.params["path"]?.stringValue == "home", "this channel's binding, and the home path")
		Check.expect(request.params["claim"] == (try? JSON.parse(paired.claimLine))?["pair"], "and the claim as the phone wrote it")
		engine.answer(request.id, .object([("claim", .string(claim))]))
		let device = DeviceID.random()
		// As the engine does once the digits match: the window closed first, then `paired` (devices.ts, pairConfirm).
		engine.event("closeJoin")
		Check.expect(phone.message(within: 1) == nil && !phone.closed, "closeJoin before paired leaves the claimed phone's channel open")
		engine.event("paired", [
			("claim", .string(claim)), ("device", keys.paired(id: device)),
			("paired", .object([("device", .string(device.text)), ("pairing", .string(mac.pairing.text)), ("name", .string("Check Mac")), ("addresses", .array([.string("127.0.0.1:\(mac.port)")]))])),
		])
		guard let line = phone.line(), case let .paired(answer)? = try? ControlLine.parse(line, from: .mac) else {
			Check.expect(false, "the phone is told it is paired")
			return nil
		}
		Check.expect(answer.device == device && answer.pairing == mac.pairing && answer.addresses == ["127.0.0.1:\(mac.port)"], "the phone is told its device id, the pairing and the Mac's addresses")
		Check.expect(storedHomeKey(home) == answer.homeKey, "and the home key pi² Remote keeps (#845)")
		Check.expect(phone.event() == .bye && phone.closesWithin(), "then the pairing channel ends")
		return device
	}

	/// A connection's channel and attach, as the engine answers it; returns the phone and the engine's session.
	static func attach(_ engine: FakeEngine, mac: Mac, device: DeviceID, keys: PhoneKeys, session: String, resume: (SessionID, UInt64)? = nil, resumed: Bool = false) -> (Phone, Attached)? {
		guard let phone = Phone(port: mac.port) else { return nil }
		let challenge = Bytes.random(32)
		let handshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: device, channelKey: keys.channel, remoteChannelKey: mac.channel)
		phone.send(try! handshake.writeMessage())
		guard let begin = engine.request("remote.attachBegin") else { return nil }
		engine.answer(begin.id, .object([("challenge", .string(Base64URL.encode(challenge)))]))
		guard let answer = phone.message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel(maxLineLength: Lines.defaultMaxLength) else { return nil }
		phone.channel = channel
		guard let proofLine = phone.line(), case let .mac(proof)? = try? ControlLine.parse(proofLine) else { return nil }
		Check.expect(proof.challenge == challenge, "the Mac's proof carries the engine's challenge")
		Check.expect((try? proof.verify(identityKey: mac.identity, pairing: mac.pairing, binding: channel.handshakeHash)) != nil, "signed by the Mac's identity key over this channel")
		let claim = try! AttachClaim.make(
			pairing: mac.pairing, device: device, session: resume?.0, received: resume?.1, binding: channel.handshakeHash, challenge: challenge, build: keys.build,
			deviceKey: keys.device, presenceKey: keys.presence)
		phone.sendLine(ControlLine.attach(claim).line)
		guard let request = engine.request("remote.attach") else { return nil }
		let attach = request.params["attach"]
		Check.expect(request.params.keys == ["attach", "binding", "path"] && attach?.keys == ["signed", "signature", "presence"], "remote.attach takes the attach without received, as the engine reads it", JSON.text(request.params))
		Check.expect(attach?["signed"]?.stringValue == claim.statement.text && attach?["presence"]?.stringValue == Base64URL.encode(claim.presence), "the attach's signed text and presence signature as the phone made them")
		engine.answer(request.id, .object([("session", .string(session)), ("resume", .bool(resumed))]))
		guard let line = phone.line(), case let .attached(attached)? = try? ControlLine.parse(line, from: .mac) else {
			Check.expect(false, "the phone is told it is attached")
			return nil
		}
		let key = phone.readHomeKey()
		Check.expect(key != nil && key == storedHomeKey(home), "after attached, the phone is sent the home key (#845)")
		return (phone, attached)
	}

	static func run(helper: URL, home: URL) {
		Check.section("pi² Remote in loopback mode, this check its engine and a phone")
		Flows.home = home
		let (child, engine) = Starts.start(helper: helper, home: home)
		defer { child.stop() }
		Check.expect(engine.quiet(for: 0.5), "pi² Remote says nothing before the engine's start")
		let pairing = PairingID.random()
		guard var mac = hello(engine, pairing: pairing) else { Check.stop("pi² Remote said hello") }
		let keyFile = home.appendingPathComponent("remote-keys.json")
		let mode = (try? FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int) ?? -1
		Check.expect(mode == 0o600, "its keys are in a file in the engine's data folder, readable by the person alone", String(mode, radix: 8))
		Check.expect(!FileManager.default.fileExists(atPath: "/tmp/pi2-remote-elsewhere"), "and not where its own arguments and environment pointed")
		let log = (try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
		Check.expect(log.contains("a development build") && log.contains("listening on 127.0.0.1"), "its log says it is a development build listening on 127.0.0.1", log)

		Check.section("the home listener takes 127.0.0.1 alone, and a first message of the right length alone")
		for address in MacAddresses.current(port: mac.port) where !address.hasPrefix("[") {
			let host = String(address.split(separator: ":")[0])
			Check.expect(Phone(port: mac.port, address: host) == nil, "nothing listens on \(host):\(mac.port)")
		}
		var phone = Phone(port: mac.port)!
		phone.send(Bytes.random(96))
		Check.expect(phone.closesWithin(10), "a pairing's first message with no window open is closed")
		phone = Phone(port: mac.port)!
		phone.send(Bytes.random(48))
		Check.expect(phone.closesWithin(10), "a connection's first message from no paired device is closed")
		phone = Phone(port: mac.port)!
		phone.raw(Data([0xFF, 0xFF]))
		Check.expect(phone.closesWithin(10), "a first message announcing 65,535 bytes is closed before they come")
		Check.expect(engine.quiet(for: 1), "none of them reached the engine")

		Check.section("pairing on the home path (3.3)")
		let secret = Bytes.random(32)
		let expires = Int64(Date().timeIntervalSince1970) + 300
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string("x")), ("expires", .integer(expires * 1000))])
		phone = Phone(port: mac.port)!
		phone.send(Bytes.random(96))
		Check.expect(phone.closesWithin(10), "a first message that is not a handshake's is closed")
		Check.expect(engine.quiet(for: 1), "and is not counted as a wrong try: anyone could send one")
		let wrong = try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: Bytes.random(32),
			relay: "ws://127.0.0.1:9/v1", addresses: [], expires: expires)
		phone = Phone(port: mac.port)!
		let keys = PhoneKeys()
		Check.expect(phone.pair(payload: wrong, keys: keys, team: team) == nil, "a phone with the wrong secret cannot read the Mac's answer")
		phone.end()
		Check.expect(engine.request("remote.pairWrong") != nil, "and when it gives up, pi² Remote counts a wrong try (remote.pairWrong)")
		// A claimer that finished the handshake and sent no claim yet: closeJoin ends its channel.
		let payload = try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: secret,
			relay: "ws://127.0.0.1:9/v1", addresses: [], expires: expires)
		phone = Phone(port: mac.port)!
		let early = try! ChannelHandshake.pairingInitiator(payload: payload, channelKey: keys.channel)
		phone.send(try! early.writeMessage())
		if let answer = phone.message(), (try? early.readMessage(answer)) != nil, let channel = try? early.channel() {
			phone.channel = channel
			Check.expect(phone.line() != nil, "a claimer with the right secret gets the Mac's proof")
			engine.event("closeJoin")
			Check.expect(phone.event() == .bye && phone.closesWithin(), "closeJoin ends a pairing channel that has sent no claim")
		} else {
			Check.expect(false, "a claimer with the right secret completes the handshake")
		}
		Check.expect(engine.request("remote.pairWrong", within: 2) == nil, "and that is no wrong try: its first message never came, but the window closed")

		// Claimers that hold the secret and whose claim pi² Remote refuses itself: each is told to the engine (#675's
		// security read B, M3), as a wrong try.
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string("x")), ("expires", .integer(expires * 1000))])
		func provenClaimer() -> Phone? {
			guard let phone = Phone(port: mac.port) else { return nil }
			let handshake = try! ChannelHandshake.pairingInitiator(payload: payload, channelKey: keys.channel)
			phone.send(try! handshake.writeMessage())
			guard let answer = phone.message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel() else { return nil }
			phone.channel = channel
			guard phone.line() != nil else { return nil }
			return phone
		}
		if let quiet = provenClaimer(), let channel = quiet.channel {
			quiet.send(try! channel.sealPing())
			let refused = engine.request("remote.pairRefused", within: 30)
			Check.expect(refused?.params["why"]?.stringValue == "silent" && quiet.closesWithin(5), "a claimer that proves the secret with a ping and goes quiet: remote.pairRefused silent when its ten seconds run out (#776's 28)")
		}
		if let other = provenClaimer() {
			other.sendLine(Data(#"{"hello":1}"#.utf8))
			Check.expect(engine.request("remote.pairRefused")?.params["why"]?.stringValue == "not-pair" && other.closesWithin(5), "a claimer whose first line is not a claim to pair: remote.pairRefused not-pair")
		}
		if let forged = provenClaimer() {
			let claim = try! PairClaim.make(device: keys.description(), attestation: Data("x".utf8), keyId: keys.keyId, pairing: mac.pairing, binding: Bytes.random(32), deviceKey: keys.device)
			forged.sendLine(ControlLine.pair(claim).line)
			Check.expect(engine.request("remote.pairRefused")?.params["why"]?.stringValue == "not-bound" && forged.closesWithin(5), "a claim not signed for this channel: remote.pairRefused not-bound")
			Check.expect(forged.homeKey == nil, "and none of them is sent a home key")
		}
		Check.expect(engine.quiet(for: 1), "and no claim pi² Remote refused reached the engine as a claim")
		engine.event("closeJoin")

		guard let device = pair(engine, mac: mac, keys: keys, claim: "claim_1") else { Check.stop("a phone paired") }
		Check.expect(listed(home) == [device.text], "the device is on pi² Remote's own list once the engine paired it")
		let kept = FileManager.default.contents(atPath: home.appendingPathComponent("remote-devices.json").path).flatMap { try? JSON.parse($0) }
		Check.expect(kept?["devices"].flatMap { if case let .array(items) = $0 { items.first } else { nil } }?["attestKeyId"]?.stringValue == keys.keyId, "with the App Attest key id of the engine's verified claim, for the relay's addDevice")

		Check.section("a relay key for each relay address (#678's security read)")
		let firstRelay = relayKeyText
		engine.event("settings", [("relay", .string("ws://127.0.0.1:10/v1")), ("switches", switches)])
		let other = engine.request("remote.hello")
		if let other { engine.answer(other.id) }
		let otherRelay = other?.params["macKeys"]?["relay"]?.stringValue
		Check.expect(otherRelay != nil && otherRelay != firstRelay, "another relay's address: remote.hello again, with a relay key of its own")
		Check.expect(other?.params["macKeys"]?["identity"] == hello0?["macKeys"]?["identity"] && other?.params["macKeys"]?["channel"] == hello0?["macKeys"]?["channel"], "and the same identity and channel keys")
		engine.event("settings", [("relay", .string("ws://127.0.0.1:9/v1")), ("switches", switches)])
		let back = engine.request("remote.hello")
		if let back { engine.answer(back.id) }
		Check.expect(back?.params["macKeys"]?["relay"]?.stringValue == firstRelay, "back to the first relay, its own key again")
		engine.event("settings", [("relay", .string("ws://127.0.0.1:9/v1")), ("switches", switches)])
		Check.expect(engine.quiet(for: 1), "the same address again says nothing")
		// A relay key that cannot be made (the data folder cannot be written): the relay path is off, the rest carries on.
		chmod(home.path, 0o500)
		engine.event("settings", [("relay", .string("ws://127.0.0.1:11/v1")), ("switches", switches)])
		let unmade = engine.request("remote.hello")
		if let unmade { engine.answer(unmade.id) }
		let off = engine.request("remote.state")
		if let off { engine.answer(off.id) }
		chmod(home.path, 0o700)
		Check.expect(unmade != nil && child.running, "a relay key that cannot be made does not stop pi² Remote: it says hello again")
		Check.expect(off?.params["relay"]?["available"]?.boolValue == false && off?.params["relay"]?["why"]?.stringValue?.contains("relay path is off") == true, "and tells the engine the relay path is off, and why", off.map { JSON.text($0.params) } ?? "nothing")
		Check.expect(Phone(port: mac.port) != nil, "while the home path still answers")
		engine.event("settings", [("relay", .string("ws://127.0.0.1:9/v1")), ("switches", switches)])
		let restored = engine.request("remote.hello")
		if let restored { engine.answer(restored.id) }
		Check.expect(restored?.params["macKeys"]?["relay"]?.stringValue == firstRelay, "back to a relay whose key it has: that key again")

		Check.section("Find on this network off and on: the engine hears of the new port (#675's security read B, M5)")
		let homeOff = JSONValue.object([("on", .bool(true)), ("relay", .bool(true)), ("home", .bool(false)), ("direct", .bool(false)), ("preview", .bool(true))])
		// A claimer with a wrong secret, the handshake done and nothing proven, when the switch goes off: no wrong try.
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string("x")), ("expires", .integer(expires * 1000))])
		let unproven = Phone(port: mac.port)!
		let unprovenHandshake = try! ChannelHandshake.pairingInitiator(payload: wrong, channelKey: keys.channel)
		unproven.send(try! unprovenHandshake.writeMessage())
		Check.expect(unproven.message() != nil, "a claimer with a wrong secret gets the Mac's answer")
		engine.event("settings", [("relay", .string("ws://127.0.0.1:9/v1")), ("switches", homeOff)])
		Check.expect(unproven.closesWithin(10), "Find on this network off ends a pairing channel with no claim")
		let none = engine.request("remote.state")
		Check.expect(none != nil, "and is no wrong try: the engine is told only the addresses")
		Check.expect(none?.params["addresses"] == .array([]), "off: the engine is told the Mac has no address to reach", none.map { JSON.text($0.params) } ?? "nothing")
		if let none { engine.answer(none.id) }
		engine.event("closeJoin")
		engine.event("settings", [("relay", .string("ws://127.0.0.1:9/v1")), ("switches", switches)])
		let again = engine.request("remote.state")
		if let again { engine.answer(again.id) }
		if case let .array(items)? = again?.params["addresses"], let text = items.first?.stringValue, text.hasPrefix("127.0.0.1:"), let port = UInt16(text.dropFirst("127.0.0.1:".count)) {
			Check.expect(Phone(port: port) != nil, "on again: the engine is told the new port, which answers")
			mac = Mac(pairing: mac.pairing, port: port, identity: mac.identity, channel: mac.channel, record: mac.record)
		} else {
			Check.expect(false, "on again: the engine is told the new port", again.map { JSON.text($0.params) } ?? "nothing")
		}

		Check.section("attaching, a session's lines, resuming (3.4, 5.6, 5.8)")
		guard let (first, attached) = attach(engine, mac: mac, device: device, keys: keys, session: "s_one") else { Check.stop("the phone attached") }
		Check.expect(attached.session.text == "s_one" && !attached.resume, "the phone is told its session")
		for n in 1 ... 3 { engine.toSession("s_one", "{\"event\":\"check\",\"n\":\(n)}") }
		let got = (1 ... 3).compactMap { _ in first.line() }
		Check.expect(got == (1 ... 3).map { Data("{\"event\":\"check\",\"n\":\($0)}".utf8) }, "the engine's lines reach the phone as they were written", got.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " "))
		first.sendLine(Data(#"{"id":"r1","method":"engine.info","params":{}}"#.utf8))
		let passed = engine.sessionLine()
		Check.expect(passed?.1 == Data(#"{"session":"s_one","message":{"id":"r1","method":"engine.info","params":{}}}"#.utf8), "the phone's line reaches the engine in its session, as it was written", passed.map { String(decoding: $0.1, as: UTF8.self) } ?? "none")
		first.sendAck(1)
		usleep(300_000)
		first.end()
		usleep(300_000)
		engine.toSession("s_one", #"{"event":"check","n":4}"#)
		guard let (second, again) = attach(engine, mac: mac, device: device, keys: keys, session: "s_one", resume: (SessionID("s_one")!, 1), resumed: true) else { Check.stop("the phone resumed") }
		Check.expect(again.resume && again.session.text == "s_one", "the phone is told it resumed")
		let replayed = (2 ... 4).compactMap { _ in second.line() }
		Check.expect(replayed == (2 ... 4).map { Data("{\"event\":\"check\",\"n\":\($0)}".utf8) }, "it is sent what it had not acknowledged, and what came while it was away, in order", replayed.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " "))
		second.sendLine(Data("[1]".utf8))
		Check.expect(second.closesWithin(10), "a line that is not one JSON object closes the channel")
		Check.expect(engine.sessionLine(within: 1) == nil, "and never reaches the engine")
		guard let (third, _) = attach(engine, mac: mac, device: device, keys: keys, session: "s_one", resume: (SessionID("s_one")!, 4), resumed: true) else { Check.stop("the phone resumed again") }

		Check.section("long lines (#675's security read B, M1 and M2)")
		for megabytes in [20, 63] {
			let pad = String(repeating: "a", count: megabytes * 1024 * 1024 - 64)
			let big = "{\"event\":\"check\",\"pad\":\"\(pad)\"}"
			engine.toSession("s_one", big)
			let got = third.line(within: 240)
			Check.expect(got?.count == big.utf8.count && got.map { $0.elementsEqual(big.utf8) } == true, "an engine line of \(megabytes) MB reaches the phone whole", "\(got?.count ?? 0) bytes")
		}
		let before = rss(child.pid)
		let numbers = "{\"id\":\"n1\",\"method\":\"engine.info\",\"params\":{\"x\":[" + String(repeating: "0,", count: 7 * 1024 * 1024) + "0]}}"
		third.sendLine(Data(numbers.utf8))
		let carried = engine.sessionLine(within: 120)
		let grown = rss(child.pid) - before
		Check.expect(carried?.1.count == numbers.utf8.count + #"{"session":"s_one","message":}"#.utf8.count, "a phone's 14 MB line of small numbers reaches the engine", "\(carried?.1.count ?? 0) bytes")
		Check.expect(grown < 120 * 1024, "and is checked without building it: pi² Remote grew by \(grown / 1024) MB, not the gigabyte a tree of it takes")
		third.sendLine(Data(#"{"sessionEnd":{}}"#.utf8))
		let ended = engine.request("remote.sessionEnd")
		Check.expect(ended?.params["session"]?.stringValue == "s_one", "the phone's sessionEnd ends its session in the engine")
		Check.expect(third.event() == .bye, "and its channel")

		Check.section("what pi² Remote refuses to pass on (3.4)")
		let stranger = P256.Signing.PrivateKey()
		if let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: device, keys: keys) {
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: "0", deviceKey: stranger, presenceKey: keys.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			Check.expect(phone.event() == .bye && phone.closesWithin(10), "an attach not signed by the device key on pi² Remote's own list is closed with bye alone, whatever its build")
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}
		if let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: device, keys: keys) {
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: "0", deviceKey: keys.device, presenceKey: keys.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			if let line = phone.line(within: 10), case let .refused(refusal)? = try? ControlLine.parse(line, from: .mac) {
				Check.expect(refusal.reason == .update && phone.event() == .bye && phone.closesWithin(10), "an attach from a build below the minimum is refused update, then closed (#820)")
			} else {
				Check.expect(false, "an attach from a build below the minimum is refused update")
			}
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}

		Check.section("the engine closes a session; the resume window; revocation")
		var second2 = PhoneKeys()
		second2.build = "8"
		guard let other = pair(engine, mac: mac, keys: second2, claim: "claim_2") else { Check.stop("a second phone paired") }
		Check.expect(Set(listed(home)) == [device.text, other.text], "both devices are on the list")
		guard let (closing, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_two") else { Check.stop("attached again") }
		// Back-pressure: the engine (this check) reads nothing while the phone sends; pi² Remote stops reading from the
		// phone once 8 MB wait for the engine, so the phone is held back and pi² Remote's memory is not (M2).
		let secret3 = Bytes.random(32)
		let expires3 = Int64(Date().timeIntervalSince1970) + 300
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret3))), ("tokenHash", .string("x")), ("expires", .integer(expires3 * 1000))])
		let payload3 = try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: secret3,
			relay: "ws://127.0.0.1:9/v1", addresses: [], expires: expires3)
		let rssBefore = rss(child.pid)
		closing.sendTimeout(3)
		let pad = String(repeating: "b", count: 1024 * 1024)
		var sent = 0
		for index in 0 ..< 160 {
			guard closing.sendLine(Data("{\"id\":\"bp\(index)\",\"method\":\"engine.info\",\"params\":{\"pad\":\"\(pad)\"}}".utf8)) else { break }
			sent += 1
		}
		let rssHeld = rss(child.pid) - rssBefore
		Check.expect(sent < 100, "a phone sending 160 MB at an engine that reads nothing is held back", "\(sent) MB taken")
		Check.expect(rssHeld < 64 * 1024, "and pi² Remote holds no more than the bound for the engine: it grew by \(rssHeld / 1024) MB")
		// Meanwhile a second phone connects and a claimer pairs: neither is attached, so neither is paused (M2c). Both
		// wait past the three seconds a first message has before the engine is read at all.
		let joining = Phone(port: mac.port)!
		let joiningHandshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: other, channelKey: second2.channel, remoteChannelKey: mac.channel)
		joining.send(try! joiningHandshake.writeMessage())
		let unanswered = Phone(port: mac.port)!
		let claimSent = unanswered.pair(payload: payload3, keys: PhoneKeys(), team: team) != nil
		Check.expect(claimSent, "a claimer completes its handshake and sends its claim while another phone is held back")
		sleep(4)
		var claimRequest: (id: JSONValue, params: JSONValue)?
		if let begin = engine.request("remote.attachBegin", within: 60) {
			let challenge = Bytes.random(32)
			engine.answer(begin.id, .object([("challenge", .string(Base64URL.encode(challenge)))]))
			if let answer = joining.message(), (try? joiningHandshake.readMessage(answer)) != nil, let channel = try? joiningHandshake.channel(maxLineLength: Lines.defaultMaxLength) {
				joining.channel = channel
				_ = joining.line()
				let claim = try! AttachClaim.make(pairing: mac.pairing, device: other, session: nil, received: nil, binding: channel.handshakeHash, challenge: challenge, build: second2.build, deviceKey: second2.device, presenceKey: second2.presence)
				joining.sendLine(ControlLine.attach(claim).line)
				// The claim was sent before this attach, so the engine hears it first.
				claimRequest = engine.request("remote.pairClaim")
				if let attachRequest = engine.request("remote.attach") { engine.answer(attachRequest.id, .object([("session", .string("s_six")), ("resume", .bool(false))])) }
			}
			let attachedLine = joining.line().flatMap { try? ControlLine.parse($0, from: .mac) }
			joining.readHomeKey()
			if case .attached? = attachedLine {
				Check.expect(true, "a second phone attaches while the first is held back")
			} else {
				Check.expect(false, "a second phone attaches while the first is held back")
			}
		} else {
			Check.expect(false, "a second phone's first message is read while the first phone is held back")
		}
		var unansweredAt: Date?
		if let claimed = claimRequest {
			Check.expect(true, "and the claimer's claim reaches the engine, uncut")
			engine.answer(claimed.id, .object([("claim", .string("claim_3"))]))
			usleep(300_000)
			// As before `paired`, and then no answer ever: its channel ends 30 s later.
			engine.event("closeJoin")
			unansweredAt = Date()
		} else {
			Check.expect(false, "and the claimer's claim reaches the engine, uncut")
		}
		var drained = 0
		while engine.sessionLine(within: 3) != nil { drained += 1 }
		Check.expect(drained > 0 && drained <= sent, "once the engine reads, what the phone sent reaches it", "\(drained) of \(sent)")
		engine.event("sessionClosed", [("session", .string("s_two")), ("why", .string("check"))])
		Check.expect(closing.event(within: 30) == .bye, "a session the engine closes ends its channel")
		guard let (lapsing, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_three") else { Check.stop("the second phone attached") }
		// A `refused` line is the Mac's alone (#820): from a phone it closes the channel, and the session waits for a resume.
		lapsing.sendLine(Data(#"{"refused":{"reason":"update"}}"#.utf8))
		Check.expect(lapsing.closesWithin(10), "a refused line from a phone, which only the Mac may send, closes the channel")
		let dropped = Date()
		Check.expect(engine.sessionLine(within: 1) == nil, "and never reaches the engine")
		if let unansweredAt {
			usleep(UInt32(max(0, 20 - Date().timeIntervalSince(unansweredAt)) * 1_000_000))
			Check.expect(unanswered.message(within: 0.2) == nil && !unanswered.closed, "20 s after closeJoin, a claim the engine took and has not answered still waits")
		}
		let lapsed = engine.request("remote.sessionEnd", within: 90)
		let after = Date().timeIntervalSince(dropped)
		Check.expect(lapsed?.params["session"]?.stringValue == "s_three" && after >= 59, "a session whose phone does not come back within 60 seconds is ended in the engine (remote.sessionEnd)", String(format: "after %.0f s", after))
		if unansweredAt != nil {
			Check.expect(unanswered.closesWithin(5), "and 30 s after closeJoin with neither paired nor pairRefused, its channel has ended")
			Check.expect(engine.quiet(for: 0.5), "with no try counted")
		}

		Check.section("a phone's line limit, its challenge and its build (#675's security read B)")
		if let (long, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_five") {
			long.sendLine(Data(("{\"id\":\"l\",\"method\":\"submit\",\"params\":{\"text\":\"" + String(repeating: "c", count: Remote.phoneLineLimit) + "\"}}").utf8))
			Check.expect(long.closesWithin(30), "a line from a phone over \(Remote.phoneLineLimit / 1024 / 1024) MB closes its channel")
			Check.expect(engine.sessionLine(within: 1) == nil, "and never reaches the engine")
			engine.event("sessionClosed", [("session", .string("s_five")), ("why", .string("check"))])
		}
		if let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: other, keys: second2) {
			_ = challenge
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: other, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: Bytes.random(32), build: "8", deviceKey: second2.device, presenceKey: second2.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			Check.expect(phone.closesWithin(10), "an attach that names another challenge than its channel's is closed")
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}
		if let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: other, keys: second2) {
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: other, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: "9a", deviceKey: second2.device, presenceKey: second2.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			Check.expect(phone.closesWithin(10), "an attach whose build is not numbers and dots is closed by pi² Remote itself")
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}

		Check.section("a device's attached connections, and the Mac's proof from a phone (#675's security read B, M1b)")
		if let (seventh, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_seven"),
		   let (eighth, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_eight") {
			Check.expect(joining.event(within: 10) == .bye && joining.closesWithin(5), "a device's third attached connection ends its oldest")
			Check.expect(seventh.message(within: 0.5) == nil && !seventh.closed && !eighth.closed, "and keeps its newest two")
			engine.event("sessionClosed", [("session", .string("s_six")), ("why", .string("check"))])
			seventh.sendLine(Data(#"{"challenge":"x","mac":{"signed":"y","signature":"z"}}"#.utf8))
			Check.expect(seventh.closesWithin(10), "the Mac's proof sent by a phone in a session closes its channel")
			Check.expect(engine.sessionLine(within: 1) == nil, "and never reaches the engine")
			engine.event("sessionClosed", [("session", .string("s_seven")), ("why", .string("check"))])
			eighth.sendLine(ControlLine.homeKey(HomeKey.random()).line)
			Check.expect(eighth.closesWithin(10), "a homeKey line sent by a phone, which only the Mac sends, closes its channel")
			Check.expect(engine.sessionLine(within: 1) == nil, "and never reaches the engine")
			engine.event("sessionClosed", [("session", .string("s_eight")), ("why", .string("check"))])
		} else {
			Check.expect(false, "a device attaches two connections more")
		}

		Check.section("a pair line RemoteKit cannot read goes to the engine; a pairing the engine could not save (#776's 26, 28)")
		let secret4 = Bytes.random(32)
		let expires4 = Int64(Date().timeIntervalSince1970) + 300
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret4))), ("tokenHash", .string("x")), ("expires", .integer(expires4 * 1000))])
		let payload4 = try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: secret4,
			relay: "ws://127.0.0.1:9/v1", addresses: [], expires: expires4)
		if let odd = Phone(port: mac.port) {
			let handshake = try! ChannelHandshake.pairingInitiator(payload: payload4, channelKey: PhoneKeys().channel)
			odd.send(try! handshake.writeMessage())
			if let answer = odd.message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel() {
				odd.channel = channel
				_ = odd.line()
				odd.sendLine(Data(#"{"pair":{"v":2}}"#.utf8))
				let passed = engine.request("remote.pairClaim")
				Check.expect(passed?.params["claim"] == .object([("v", .integer(2))]), "a pair line RemoteKit cannot read goes on as remote.pairClaim, for the engine to refuse", passed.map { JSON.text($0.params) } ?? "nothing")
				if let passed { engine.refuse(passed.id, "The claim is not in the form pi² Remote sends.") }
				Check.expect(odd.closesWithin(10) && odd.homeKey == nil, "refused by the engine, its channel ends with no home key")
			}
		}
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret4))), ("tokenHash", .string("x")), ("expires", .integer(expires4 * 1000))])
		let unsaved = Phone(port: mac.port)!
		if unsaved.pair(payload: payload4, keys: PhoneKeys(), team: team) != nil, let claimed = engine.request("remote.pairClaim") {
			engine.answer(claimed.id, .object([("claim", .string("claim_4"))]))
			usleep(300_000)
			// As pairConfirm does when the save fails: closeJoin, then pairRefused for the claim.
			engine.event("closeJoin")
			engine.event("pairRefused", [("claim", .string("claim_4")), ("why", .string("The Mac could not save the pairing. Start again.")), ("reason", .string("unsaved"))])
			if let line = unsaved.line(within: 10), case let .pairRefused(refusal)? = try? ControlLine.parse(line, from: .mac) {
				Check.expect(refusal.why == .unsaved && unsaved.event() == .bye && unsaved.homeKey == nil, "a claim the engine refuses after taking it (the pairing could not be saved) is told pairRefused unsaved, then ended, with no paired and no home key (#881)")
			} else {
				Check.expect(false, "a claim the engine could not save is told pairRefused unsaved")
			}
		} else {
			Check.expect(false, "a fifth claim reached the engine")
		}
		// Refused on the Mac with no word for the phone (a second claim, three wrong digits), or a word not on the list: bye alone.
		for (claimID, reason) in [("claim_5", nil), ("claim_6", "Unsaved")] as [(String, String?)] {
			engine.event("openJoin", [("secret", .string(Base64URL.encode(secret4))), ("tokenHash", .string("x")), ("expires", .integer(expires4 * 1000))])
			let quiet = Phone(port: mac.port)!
			guard quiet.pair(payload: payload4, keys: PhoneKeys(), team: team) != nil, let claimed = engine.request("remote.pairClaim") else {
				Check.expect(false, "claim \(claimID) reached the engine")
				continue
			}
			engine.answer(claimed.id, .object([("claim", .string(claimID))]))
			usleep(300_000)
			engine.event("pairRefused", [("claim", .string(claimID)), ("why", .string("Another device tried to use this code. Start again, and don't show the code on a shared or recorded screen."))] + (reason.map { [("reason", JSONValue.string($0))] } ?? []))
			Check.expect(quiet.event() == .bye && quiet.homeKey == nil, "a claim refused on the Mac with \(reason.map { "the reason \($0)" } ?? "no word for the phone") is ended with bye alone")
			engine.event("closeJoin")
		}
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret4))), ("tokenHash", .string("x")), ("expires", .integer(expires4 * 1000))])
		let cancelled = Phone(port: mac.port)!
		if cancelled.pair(payload: payload4, keys: PhoneKeys(), team: team) != nil, let claimed = engine.request("remote.pairClaim") {
			engine.answer(claimed.id, .object([("claim", .string("claim_8"))]))
			usleep(300_000)
			engine.event("pairRefused", [("claim", .string("claim_8")), ("why", .string("The pairing was closed on the Mac.")), ("reason", .string("cancelled"))])
			if let line = cancelled.line(within: 10), case let .pairRefused(refusal)? = try? ControlLine.parse(line, from: .mac) {
				Check.expect(refusal.why == .cancelled && cancelled.event() == .bye, "a claim the person cancelled on the Mac is told pairRefused cancelled, then ended")
			} else {
				Check.expect(false, "a claim the person cancelled on the Mac is told so")
			}
			engine.event("closeJoin")
		}

		Check.section("revocation: revoked, then a new home key to the phones that remain (#776's 25, #845)")
		guard let (staying, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_nine") else { Check.stop("the second phone attached again") }
		let oldKey = staying.homeKey
		guard let (revoked, _) = attach(engine, mac: mac, device: device, keys: keys, session: "s_four") else { Check.stop("attached once more") }
		engine.event("revoke", [("device", .string(device.text))])
		engine.event("sessionClosed", [("session", .string("s_four")), ("why", .string("revoked"))])
		if let line = revoked.line(), case let .revoked(revocation)? = try? ControlLine.parse(line) {
			Check.expect((try? revocation.verify(identityKey: mac.identity, pairing: mac.pairing, device: device)) != nil, "a revoked device is told so, signed by the Mac's identity key")
		} else {
			Check.expect(false, "a revoked device is told so")
		}
		Check.expect(revoked.event() == .bye, "then its channel ends")
		Check.expect(listed(home) == [other.text], "and it is dropped from pi² Remote's own list")
		let newKey = staying.readHomeKey()
		Check.expect(newKey != nil && newKey != oldKey && newKey == storedHomeKey(home), "the phone that remains attached is sent a new home key at once, the one pi² Remote now keeps")
		if let phone = Phone(port: mac.port) {
			let handshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: device, channelKey: keys.channel, remoteChannelKey: mac.channel)
			phone.send(try! handshake.writeMessage())
			Check.expect(phone.closesWithin(10), "a revoked device's handshake is closed")
			Check.expect(engine.quiet(for: 0.5), "before anything reaches the engine")
		}
		Check.section("pi² Remote's own list against the engine's start (3.4, 5.5)")
		close(engine.lines.descriptor)
		Check.expect(child.wait(15) == 0, "the engine's connection ended, pi² Remote stops")
		let (restarted, engine2) = Starts.start(helper: helper, home: home)
		defer { restarted.stop() }
		let written = DeviceID.random()
		let keptBefore = storedHomeKey(home)
		guard let mac2 = hello(engine2, pairing: pairing, devices: [written.text]) else { Check.stop("pi² Remote said hello again") }
		Check.expect(listed(home).isEmpty, "a device revoked while pi² Remote was not running is dropped at the next start, and a device the engine lists that was never paired through pi² Remote is not added")
		Check.expect(keptBefore != nil && storedHomeKey(home) == nil, "and with no device left, the home key it held goes, and none is made that no device holds (S3)")
		homeKeyKept(helper: helper, home: home, child: restarted, engine: engine2, mac: mac2)
	}

	/// The home key kept with the list of devices, in one write (#675's security read, S1 to S3): a first pairing whose
	/// key cannot be kept, a revocation whose write fails and then a crash, a crash just after a revocation's write, and
	/// the last device revoked. A write fails as it does in the relay key's check: the data folder made read-only.
	static func homeKeyKept(helper: URL, home: URL, child: Child, engine: FakeEngine, mac: Mac) {
		var child = child, engine = engine, mac = mac
		defer { child.stop() }
		/// A crash: pi² Remote killed where it is, then started again with the devices the engine lists.
		func crashAndStart(listing devices: [DeviceID]) {
			kill(child.pid, SIGKILL)
			child.wait(15)
			(child, engine) = Starts.start(helper: helper, home: home)
			guard let again = hello(engine, pairing: mac.pairing, devices: devices.map(\.text)) else { Check.stop("pi² Remote said hello after a crash") }
			mac = again
		}

		// First, on this pi² Remote just started, whose limits on first messages and handshakes no earlier step has used.
		engineRefusals(engine: engine, mac: mac, home: home)

		Check.section("a first pairing whose home key cannot be kept (S2)")
		chmod(home.path, 0o500)
		let secret = Bytes.random(32)
		let expires = Int64(Date().timeIntervalSince1970) + 300
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string("x")), ("expires", .integer(expires * 1000))])
		let payload = try! PairingPayload(
			pairing: mac.pairing, macName: "Check Mac", channelKey: mac.channel, identityKey: mac.identity, recordKey: mac.record, secret: secret,
			relay: "ws://127.0.0.1:9/v1", addresses: [], expires: expires)
		let unkept = Phone(port: mac.port)!
		Check.expect(unkept.pair(payload: payload, keys: PhoneKeys(), team: team) != nil, "a claimer that proved the secret sends its claim")
		let refused = engine.request("remote.pairRefused")
		Check.expect(refused?.params["why"]?.stringValue == "not-kept", "the first pairing's home key cannot be kept: the claim never reaches the engine, which is told remote.pairRefused not-kept and closes the window (#887)", refused.map { JSON.text($0.params) } ?? "nothing")
		if let refused { engine.answer(refused.id) }
		if let line = unkept.line(within: 10), case let .pairRefused(refusal)? = try? ControlLine.parse(line, from: .mac) {
			Check.expect(refusal.why == .unsaved && unkept.event() == .bye && unkept.closesWithin(5) && unkept.homeKey == nil, "the phone is told pairRefused unsaved, and its channel ends with no paired and no home key (#881)")
		} else {
			Check.expect(false, "the phone is told the Mac could not save the pairing")
		}
		Check.expect(engine.quiet(for: 1), "and no remote.pairClaim reaches the engine, so it pairs nothing")
		chmod(home.path, 0o700)
		Check.expect(listed(home).isEmpty && storedHomeKey(home) == nil, "no device and no home key are kept")
		engine.event("closeJoin")

		Check.section("a pairing the engine made that pi² Remote cannot keep (#887)")
		engine.event("openJoin", [("secret", .string(Base64URL.encode(secret))), ("tokenHash", .string("x")), ("expires", .integer(expires * 1000))])
		let lostKeys = PhoneKeys()
		let lost = Phone(port: mac.port)!
		if lost.pair(payload: payload, keys: lostKeys, team: team) != nil, let claimed = engine.request("remote.pairClaim") {
			engine.answer(claimed.id, .object([("claim", .string("claim_lost"))]))
			engine.event("closeJoin")
			usleep(300_000)
			// The claim's write of the home key went through; the device's, after the engine paired it, fails.
			chmod(home.path, 0o500)
			let device = DeviceID.random()
			engine.event("paired", [
				("claim", .string("claim_lost")), ("device", lostKeys.paired(id: device)),
				("paired", .object([("device", .string(device.text)), ("pairing", .string(mac.pairing.text)), ("name", .string("Check Mac")), ("addresses", .array([]))])),
			])
			let unkeptRequest = engine.request("remote.pairUnkept")
			Check.expect(unkeptRequest?.params == .object([("device", .string(device.text))]), "the engine is asked to take back that device's pairing, and only it: remote.pairUnkept", unkeptRequest.map { JSON.text($0.params) } ?? "nothing")
			if let unkeptRequest { engine.answer(unkeptRequest.id) }
			if let line = lost.line(within: 10), case let .pairRefused(refusal)? = try? ControlLine.parse(line, from: .mac) {
				Check.expect(refusal.why == .unsaved && lost.event() == .bye && lost.homeKey == nil, "the phone is told pairRefused unsaved, with no paired and no home key (#881)")
			} else {
				Check.expect(false, "the phone is told the Mac could not save the pairing")
			}
			chmod(home.path, 0o700)
			Check.expect(listed(home).isEmpty, "and the device is on no list of pi² Remote's")
		} else {
			chmod(home.path, 0o700)
			Check.expect(false, "a claim reached the engine")
		}

		Check.section("a revocation whose write fails, then a crash and a restart (S1)")
		let keysA = PhoneKeys(), keysB = PhoneKeys()
		guard let a = pair(engine, mac: mac, keys: keysA, claim: "claim_a"), let b = pair(engine, mac: mac, keys: keysB, claim: "claim_b") else { Check.stop("two phones paired") }
		guard let (staying, _) = attach(engine, mac: mac, device: b, keys: keysB, session: "s_b1"), let (leaving, _) = attach(engine, mac: mac, device: a, keys: keysA, session: "s_a1") else { Check.stop("both phones attached") }
		let old = staying.homeKey
		Check.expect(old != nil && leaving.homeKey == old, "both phones hold the home key")
		chmod(home.path, 0o500)
		engine.event("revoke", [("device", .string(a.text))])
		engine.event("sessionClosed", [("session", .string("s_a1")), ("why", .string("revoked"))])
		if let line = leaving.line(), case .revoked? = try? ControlLine.parse(line, from: .mac) {
			Check.expect(leaving.event() == .bye, "a revocation whose write fails still tells the phone it is revoked, and ends its channel")
		} else {
			Check.expect(false, "a revocation whose write fails still tells the phone it is revoked")
		}
		Check.expect(staying.line(within: 1) == nil, "the phone that remains is sent no key: none was kept")
		Check.expect(storedHomeKey(home) == old && Set(listed(home)) == [a.text, b.text], "on disk, the list and the old key are as they were, together")
		chmod(home.path, 0o700)
		crashAndStart(listing: [b])
		let renewed = storedHomeKey(home)
		Check.expect(listed(home) == [b.text] && renewed != nil && renewed != old, "after a crash, the next start drops the revoked device and keeps a new home key with the list before anything is advertised")
		if let (back, _) = attach(engine, mac: mac, device: b, keys: keysB, session: "s_b2") {
			Check.expect(back.homeKey == renewed && back.homeKey != old, "the phone that remains is sent the new key at its next attach")
			engine.event("sessionClosed", [("session", .string("s_b2")), ("why", .string("check"))])
		}
		if let phone = Phone(port: mac.port) {
			let handshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: a, channelKey: keysA.channel, remoteChannelKey: mac.channel)
			phone.send(try! handshake.writeMessage())
			Check.expect(phone.closesWithin(10) && engine.quiet(for: 0.5), "and the revoked phone's handshake is closed before anything reaches the engine")
		}

		Check.section("a crash just after a revocation's write")
		let keysC = PhoneKeys()
		guard let c = pair(engine, mac: mac, keys: keysC, claim: "claim_c") else { Check.stop("a third phone paired") }
		engine.event("revoke", [("device", .string(c.text))])
		let deadline = Date().addingTimeInterval(10)
		while listed(home) != [b.text], Date() < deadline { usleep(10000) }
		let written = storedHomeKey(home)
		Check.expect(listed(home) == [b.text] && written != nil && written != renewed, "the revocation keeps the list and a new key in one write")
		crashAndStart(listing: [b])
		Check.expect(storedHomeKey(home) == written && listed(home) == [b.text], "after a crash, the next start finds the two together, and has nothing to renew")
		if let (back, _) = attach(engine, mac: mac, device: b, keys: keysB, session: "s_b3") {
			Check.expect(back.homeKey == written, "the phone that remains is sent the key written with the revocation at its next attach")

			Check.section("the last device revoked (S3)")
			engine.event("revoke", [("device", .string(b.text))])
			engine.event("sessionClosed", [("session", .string("s_b3")), ("why", .string("revoked"))])
			if let line = back.line(), case .revoked? = try? ControlLine.parse(line, from: .mac) {
				Check.expect(back.event() == .bye, "the last device is told it is revoked, and its channel ends")
			} else {
				Check.expect(false, "the last device is told it is revoked")
			}
			Check.expect(listed(home).isEmpty && storedHomeKey(home) == nil, "with no device left, no home key is kept: none is made that no device holds, and nothing is advertised")
		} else {
			Check.expect(false, "the phone that remains attached after the crash")
		}
		guard pair(engine, mac: mac, keys: PhoneKeys(), claim: "claim_d") != nil else { return Check.expect(false, "a phone pairs after the last was revoked") }
		let fresh = storedHomeKey(home)
		Check.expect(fresh != nil && fresh != written && fresh != renewed && fresh != old, "the next first pairing makes a new home key, and gives it in paired")
	}

	/// An attach the engine refuses (#818): pi² Remote sends the phone the `refused` line with the engine's fixed word
	/// (`data.reason`), never its words, and `bye` alone for none or one that is not the engine's to give. Six attaches of
	/// one device paired for it, its six handshakes a minute; the device is revoked again at the end. The words read byte
	/// for byte, and those not on the list, are in the unit checks (`PhoneConnection.engineRefusal`).
	static func engineRefusals(engine: FakeEngine, mac: Mac, home: URL) {
		Check.section("an attach the engine refuses: its fixed reason to the phone, never its words (#818)")
		let cases: [(JSONValue?, Refusal.Reason?, String)] = [
			(.object([("reason", .string("suspended"))]), .suspended, "suspended"),
			(.object([("reason", .string("presence"))]), .presence, "presence"),
			(.object([("reason", .string("clock"))]), .clock, "clock"),
			(.object([("reason", .string("update"))]), .update, "update"),
			(nil, nil, "refusal with no reason (revoked, unknown, any other)"),
			(.object([("reason", .string("resume"))]), nil, "resume, which is pi² Remote's own"),
		]
		let keys = PhoneKeys()
		guard let device = pair(engine, mac: mac, keys: keys, claim: "claim_refusals") else { Check.stop("a phone paired for the engine's refusals") }
		for (data, expected, what) in cases {
			guard let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: device, keys: keys) else {
				Check.expect(false, "an attach begins for the engine's \(what)")
				continue
			}
			let claim = try! AttachClaim.make(
				pairing: mac.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: keys.build,
				deviceKey: keys.device, presenceKey: keys.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			guard let request = engine.request("remote.attach") else {
				Check.expect(false, "the attach reaches the engine for its \(what)")
				continue
			}
			engine.refuse(request.id, "This device is suspended. Resume it on the Mac's Devices page.", data: data)
			let first = phone.event(within: 10)
			if let expected {
				if case let .line(line)? = first, case let .refused(refusal)? = try? ControlLine.parse(line, from: .mac) {
					Check.expect(refusal.reason == expected && phone.event() == .bye && phone.closesWithin(10), "the engine's \(what): refused \(expected.rawValue), then bye")
				} else {
					Check.expect(false, "the engine's \(what) is sent as refused \(expected.rawValue)")
				}
			} else {
				Check.expect(first == .bye && phone.closesWithin(10), "the engine's \(what): bye alone, and nothing of its words")
			}
		}
		engine.event("revoke", [("device", .string(device.text))])
		let revokedBy = Date().addingTimeInterval(10)
		while !listed(home).isEmpty || storedHomeKey(home) != nil, Date() < revokedBy { usleep(10000) }
		Check.expect(listed(home).isEmpty && storedHomeKey(home) == nil, "the device is revoked again, and with it the home key")
	}

	/// What `pid` holds in memory, in kilobytes.
	static func rss(_ pid: pid_t) -> Int {
		let output = Pipe()
		let ps = Process()
		ps.executableURL = URL(fileURLWithPath: "/bin/ps")
		ps.arguments = ["-o", "rss=", "-p", String(pid)]
		ps.standardOutput = output
		try? ps.run()
		let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		ps.waitUntilExit()
		return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
	}

	/// The first steps of an attach: the handshake as `device`, the engine's challenge, the Mac's proof.
	static func beginAttach(_ phone: Phone, _ engine: FakeEngine, mac: Mac, device: DeviceID, keys: PhoneKeys) -> Data? {
		let handshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: device, channelKey: keys.channel, remoteChannelKey: mac.channel)
		phone.send(try! handshake.writeMessage())
		guard let begin = engine.request("remote.attachBegin") else { return nil }
		let challenge = Bytes.random(32)
		engine.answer(begin.id, .object([("challenge", .string(Base64URL.encode(challenge)))]))
		guard let answer = phone.message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel() else { return nil }
		phone.channel = channel
		guard phone.line() != nil else { return nil }
		return challenge
	}
}
