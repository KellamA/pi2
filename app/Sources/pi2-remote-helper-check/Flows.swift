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
		guard let line = phone.line(), case let .paired(answer)? = try? ControlLine.parse(line) else {
			Check.expect(false, "the phone is told it is paired")
			return nil
		}
		Check.expect(answer.device == device && answer.pairing == mac.pairing && answer.addresses == ["127.0.0.1:\(mac.port)"], "the phone is told its device id, the pairing and the Mac's addresses")
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
		guard let line = phone.line(), case let .attached(attached)? = try? ControlLine.parse(line) else {
			Check.expect(false, "the phone is told it is attached")
			return nil
		}
		return (phone, attached)
	}

	static func run(helper: URL, home: URL) {
		Check.section("pi² Remote in loopback mode, this check its engine and a phone")
		let (child, engine) = Starts.start(helper: helper, home: home)
		defer { child.stop() }
		Check.expect(engine.quiet(for: 0.5), "pi² Remote says nothing before the engine's start")
		let pairing = PairingID.random()
		guard let mac = hello(engine, pairing: pairing) else { Check.stop("pi² Remote said hello") }
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

		guard let device = pair(engine, mac: mac, keys: keys, claim: "claim_1") else { Check.stop("a phone paired") }
		Check.expect(listed(home) == [device.text], "the device is on pi² Remote's own list once the engine paired it")

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
		third.sendLine(Data(#"{"sessionEnd":{}}"#.utf8))
		let ended = engine.request("remote.sessionEnd")
		Check.expect(ended?.params["session"]?.stringValue == "s_one", "the phone's sessionEnd ends its session in the engine")
		Check.expect(third.event() == .bye, "and its channel")

		Check.section("what pi² Remote refuses to pass on (3.4)")
		let stranger = P256.Signing.PrivateKey()
		if let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: device, keys: keys) {
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: "7", deviceKey: stranger, presenceKey: keys.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			Check.expect(phone.closesWithin(10), "an attach not signed by the device key on pi² Remote's own list is closed")
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}
		if let phone = Phone(port: mac.port), let challenge = beginAttach(phone, engine, mac: mac, device: device, keys: keys) {
			let claim = try! AttachClaim.make(pairing: mac.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: "0", deviceKey: keys.device, presenceKey: keys.presence)
			phone.sendLine(ControlLine.attach(claim).line)
			Check.expect(phone.closesWithin(10), "an attach from a build below the minimum is closed")
			Check.expect(engine.quiet(for: 1), "and never reaches the engine")
		}

		Check.section("the engine closes a session; the resume window; revocation")
		var second2 = PhoneKeys()
		second2.build = "8"
		guard let other = pair(engine, mac: mac, keys: second2, claim: "claim_2") else { Check.stop("a second phone paired") }
		Check.expect(Set(listed(home)) == [device.text, other.text], "both devices are on the list")
		guard let (closing, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_two") else { Check.stop("attached again") }
		engine.event("sessionClosed", [("session", .string("s_two")), ("why", .string("check"))])
		Check.expect(closing.event() == .bye, "a session the engine closes ends its channel")
		guard let (lapsing, _) = attach(engine, mac: mac, device: other, keys: second2, session: "s_three") else { Check.stop("the second phone attached") }
		let dropped = Date()
		lapsing.end()
		guard let (revoked, _) = attach(engine, mac: mac, device: device, keys: keys, session: "s_four") else { Check.stop("attached once more") }
		engine.event("revoke", [("device", .string(device.text))])
		if let line = revoked.line(), case let .revoked(revocation)? = try? ControlLine.parse(line) {
			Check.expect((try? revocation.verify(identityKey: mac.identity, pairing: mac.pairing, device: device)) != nil, "a revoked device is told so, signed by the Mac's identity key")
		} else {
			Check.expect(false, "a revoked device is told so")
		}
		Check.expect(revoked.event() == .bye, "then its channel ends")
		Check.expect(listed(home) == [other.text], "and it is dropped from pi² Remote's own list")
		if let phone = Phone(port: mac.port) {
			let handshake = try! ChannelHandshake.connection(initiator: true, pairing: mac.pairing, device: device, channelKey: keys.channel, remoteChannelKey: mac.channel)
			phone.send(try! handshake.writeMessage())
			Check.expect(phone.closesWithin(10), "a revoked device's handshake is closed")
			Check.expect(engine.quiet(for: 0.5), "before anything reaches the engine")
		}
		let lapsed = engine.request("remote.sessionEnd", within: 90)
		let after = Date().timeIntervalSince(dropped)
		Check.expect(lapsed?.params["session"]?.stringValue == "s_three" && after >= 59, "a session whose phone does not come back within 60 seconds is ended in the engine (remote.sessionEnd)", String(format: "after %.0f s", after))

		Check.section("pi² Remote's own list against the engine's start (3.4, 5.5)")
		close(engine.lines.descriptor)
		Check.expect(child.wait(15) == 0, "the engine's connection ended, pi² Remote stops")
		let (restarted, engine2) = Starts.start(helper: helper, home: home)
		defer { restarted.stop() }
		let written = DeviceID.random()
		guard hello(engine2, pairing: pairing, devices: [written.text]) != nil else { Check.stop("pi² Remote said hello again") }
		Check.expect(listed(home).isEmpty, "a device revoked while pi² Remote was not running is dropped at the next start, and a device the engine lists that was never paired through pi² Remote is not added")
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
