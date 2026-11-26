import CryptoKit
import Foundation
@_spi(Vectors) import RemoteKit

/// Every parser in RemoteKit that reads bytes from the network (iphone.md 5.2: framing, handshake, frames, items, the
/// pairing payload), each with what must hold of what it takes.
enum Targets {
	static func all(seed: UInt64) throws -> [Target] {
		var rng = SplitMix64(state: seed)
		let world = try World(rng: &rng)
		return [
			base64url(),
			identifiers(),
			keys(world),
			json(world),
			frame(),
			lines(),
			tcpFraming(),
			payload(world),
			controlLines(world),
			homeTag(world),
			try kkResponder(world),
			try kkInitiator(world),
			try kkRespondByTrial(world),
			try pairingResponder(world),
			try pairingInitiator(world),
			try transport(world),
			try sealedItem(world),
			requestItem(world),
			macItem(world),
			relayMessages(world),
			relayLeave(world),
		]
	}

	/// The keys and ids every target shares, made from the seed, so that the same seed makes the same handshakes.
	struct World {
		let pairing: PairingID
		let device: DeviceID
		let otherDevice: DeviceID
		let secret: Data
		let macChannel: Curve25519.KeyAgreement.PrivateKey
		let phoneChannel: Curve25519.KeyAgreement.PrivateKey
		let otherChannel: Curve25519.KeyAgreement.PrivateKey
		let ephemerals: [Curve25519.KeyAgreement.PrivateKey]
		let identity: P256.Signing.PrivateKey
		let deviceKey: P256.Signing.PrivateKey
		let presenceKey: P256.Signing.PrivateKey
		let macRecord: P256.KeyAgreement.PrivateKey
		let phoneRecord: P256.KeyAgreement.PrivateKey
		let payload: PairingPayload
		let homeKey: HomeKey

		init(rng: inout SplitMix64) throws {
			func bytes(_ count: Int) -> Data { Data(rng.bytes(count)) }
			func p256() throws -> Data {
				// A P-256 scalar must be below the group's order; 31 random bytes after a zero byte always are.
				Data([0]) + bytes(31)
			}
			pairing = PairingID(Base64URL.encode(bytes(16)))!
			device = DeviceID("dev_" + Base64URL.encode(bytes(16)))!
			otherDevice = DeviceID("dev_" + Base64URL.encode(bytes(16)))!
			secret = bytes(32)
			macChannel = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(32))
			phoneChannel = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(32))
			otherChannel = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(32))
			ephemerals = try (0..<8).map { _ in try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(32)) }
			identity = try P256.Signing.PrivateKey(rawRepresentation: try p256())
			deviceKey = try P256.Signing.PrivateKey(rawRepresentation: try p256())
			presenceKey = try P256.Signing.PrivateKey(rawRepresentation: try p256())
			macRecord = try P256.KeyAgreement.PrivateKey(rawRepresentation: try p256())
			phoneRecord = try P256.KeyAgreement.PrivateKey(rawRepresentation: try p256())
			payload = try PairingPayload(
				pairing: pairing, macName: "Alex’s Mac", channelKey: macChannel.publicKey, identityKey: identity.publicKey,
				recordKey: macRecord.publicKey, secret: secret, relay: "wss://relay.example.dev/v1",
				addresses: ["192.168.1.2:52000", "[fd7a:115c:a1e0::1]:52000"], expires: 1_800_000_000)
			// Made last, so that every key before it is what the same seed made before #845.
			homeKey = HomeKey(rawRepresentation: bytes(32))!
		}

		var description: DeviceDescription {
			DeviceDescription(
				name: "Phone", model: "iPhone 17", system: "iOS 27.1", build: "1.0.1", deviceKey: deviceKey.publicKey,
				presenceKey: presenceKey.publicKey, channelKey: phoneChannel.publicKey, recordKey: phoneRecord.publicKey)
		}
	}

	static func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

	static func words(_ list: [String]) -> [[UInt8]] { list.map { Array($0.utf8) } }

	// MARK: Texts

	static func base64url() -> Target {
		var rng = SplitMix64(state: 1)
		return Target(name: "base64url", seeds: (0..<40).map { Array(Base64URL.encode(Data(rng.bytes($0))).utf8) }, dictionary: words(["-", "_", "=", "+", "/", "A", "w"]), maxLength: 256) { input in
			let text = text(input)
			guard let data = Base64URL.decode(text) else { return false }
			// One text for each run of bytes: what it read, written again, is what it read.
			if !Base64URL.encode(data).sameBytesAs(text) { Fuzz.violation("base64url", "took a text it would not write", input) }
			if Base64URL.decode(text, count: data.count) != data { Fuzz.violation("base64url", "read a different length the second way", input) }
			return true
		}
	}

	static func identifiers() -> Target {
		var rng = SplitMix64(state: 2)
		let seeds = [Base64URL.encode(Data(rng.bytes(16))), "dev_" + Base64URL.encode(Data(rng.bytes(16))), "s_123-abc", "mac"].map { Array($0.utf8) }
		return Target(name: "identifiers", seeds: seeds, dictionary: words(["dev_", "-", "_", "=", "\u{212A}"]), maxLength: 128) { input in
			let text = text(input)
			var taken = false
			for id in [PairingID(text)?.text, DeviceID(text)?.text, ItemID(text)?.text, SessionID(text)?.text] {
				if let id {
					taken = true
					if !id.sameBytesAs(text) { Fuzz.violation("identifiers", "an id is not the text it was read from", input) }
				}
			}
			return taken
		}
	}

	static func keys(_ world: World) -> Target {
		let seeds = [
			PublicKeys.text(world.identity.publicKey), PublicKeys.text(world.macRecord.publicKey), PublicKeys.text(world.macChannel.publicKey),
			Base64URL.encode(world.identity.publicKey.x963Representation),
		].map { Array($0.utf8) }
		return Target(name: "keys", seeds: seeds, maxLength: 512) { input in
			let text = text(input)
			var taken = false
			if let key = PublicKeys.signingKey(fromBase64URL: text) {
				taken = true
				if !PublicKeys.text(key).sameBytesAs(text) { Fuzz.violation("keys", "a signing key with two texts", input) }
			}
			if let key = PublicKeys.agreementKey(fromBase64URL: text) {
				taken = true
				if !PublicKeys.text(key).sameBytesAs(text) { Fuzz.violation("keys", "an agreement key with two texts", input) }
			}
			if let key = PublicKeys.channelKey(fromBase64URL: text) {
				taken = true
				if !PublicKeys.text(key).sameBytesAs(text) { Fuzz.violation("keys", "a channel key with two texts", input) }
			}
			return taken
		}
	}

	static func json(_ world: World) -> Target {
		var seeds = words([
			#"{"a":[1,-2.5e3,true,false,null,"x\"\\\/\b\f\n\r\t\u00e9\ud83d\ude00"],"b":{}}"#, "[]", "{}", "0", "-0.0e+0", #""\u0000""#,
			#"{"v":2,"kind":"attach","pairing":"AAAAAAAAAAAAAAAAAAAAAA","session":null,"at":1700000000000}"#, "[[[[[[[[[[1]]]]]]]]]]",
		])
		seeds += controlLineSeeds(world)
		return Target(name: "json", seeds: seeds, dictionary: words(["{", "}", "[", "]", ",", ":", "\"", "\\u", "\\ud800", "\\udc00", "true", "null", "-", "e+", ".", " ", "\u{212A}", "\u{0}"])) { input in
			var value = JSONValue.null
			guard Fuzz.takes("json", input, { value = try JSON.parse(input) }) else { return false }
			let written = JSON.write(value)
			var again = JSONValue.null
			guard Fuzz.takes("json", input, { again = try JSON.parse(written) }) else { Fuzz.violation("json", "could not read what it wrote", input) }
			if again != value { Fuzz.violation("json", "read back as another value", input) }
			if JSON.write(again) != written { Fuzz.violation("json", "wrote one value two ways", input) }
			return true
		}
	}

	// MARK: Framing

	static func frame() -> Target {
		var seeds: [[UInt8]] = []
		for frame in [try! Frame(.data, Data("{\"id\":1}".utf8)), try! Frame(.more, Data(repeating: 0x61, count: 40)), Frame.ack(7), try! Frame(.ping), try! Frame(.bye), try! Frame(.data)] {
			seeds.append(Array(frame.encoded()))
			seeds.append(Array(frame.encoded(padTo: 64)))
		}
		return Target(name: "frame", seeds: seeds, maxLength: Noise.maxPlaintextLength + 8) { input in
			var frame: Frame?
			guard Fuzz.takes("frame", input, { frame = try Frame.decode(Data(input)) }) else { return false }
			// What it took is the frame written again and zeros, nothing else.
			let written = Array(frame!.encoded())
			if Array(input.prefix(written.count)) != written || input.dropFirst(written.count).contains(where: { $0 != 0 }) {
				Fuzz.violation("frame", "took bytes that are not the frame and its padding", input)
			}
			return true
		}
	}

	/// Frames one after another, each preceded by its length in one byte, put back together into lines.
	static func lines() -> Target {
		func pack(_ frames: [Frame]) -> [UInt8] {
			frames.flatMap { frame -> [UInt8] in
				let bytes = Array(frame.encoded())
				return [UInt8(bytes.count)] + bytes
			}
		}
		let seeds = [
			pack(try! Lines.frames(for: Data(repeating: 0x7b, count: 100), maxBody: 30)),
			pack([try! Frame(.data, Data("{}".utf8)), Frame.ack(1), try! Frame(.data, Data("[]".utf8))]),
		]
		return Target(name: "lines", seeds: seeds, maxLength: 4096) { input in
			var assembler = LineAssembler(maxLength: 300)
			var offset = 0
			var any = false
			while offset < input.count {
				let length = Int(input[offset])
				offset += 1
				let piece = Array(input[offset..<min(input.count, offset + length)])
				offset += length
				guard let frame = try? Frame.decode(Data(piece)) else { continue }
				var line: Data?
				guard Fuzz.takes("lines", input, { line = try assembler.take(frame) }) else {
					assembler = LineAssembler(maxLength: 300)
					continue
				}
				if let line {
					any = true
					if line.isEmpty || line.count > 300 || line.contains(0x0a) || line.contains(0x0d) {
						Fuzz.violation("lines", "gave a line it should have refused", input)
					}
				}
			}
			return any
		}
	}

	static func tcpFraming() -> Target {
		let seeds: [[UInt8]] = [
			Array(try! LengthFraming.encode(Data(repeating: 1, count: 48)) + LengthFraming.encode(Data(repeating: 2, count: 96))),
			Array(try! LengthFraming.encode(Data(repeating: 3, count: 16))),
		]
		return Target(name: "tcp-framing", seeds: seeds, maxLength: 70_000) { input in
			// In pieces of a size the input chooses, so the same bytes arrive split in many ways.
			let size = max(1, Int(input.first ?? 1))
			var framing = LengthFraming()
			var messages: [Data] = []
			var offset = 0
			var refused = false
			while offset < input.count, !refused {
				let piece = Data(input[offset..<min(input.count, offset + size)])
				offset += size
				refused = !Fuzz.takes("tcp-framing", input, { messages += try framing.push(piece) })
			}
			if !refused {
				// What it gave is a prefix of what came, written again; the rest waits.
				var written = Data()
				for message in messages { written += try! LengthFraming.encode(message) }
				if Array(written) != Array(input.prefix(written.count)) || written.count + framing.buffered != input.count {
					Fuzz.violation("tcp-framing", "gave messages that are not what came", input)
				}
			}
			return !refused && !messages.isEmpty
		}
	}

	// MARK: The pairing payload and the channel's lines

	static func payload(_ world: World) -> Target {
		var other = world.payload
		other.addresses = []
		other.relay = "ws://127.0.0.1:8787/v1"
		other.macName = "Mac & 'Studio' (2) é ☃"
		let seeds = [world.payload.text, other.text].map { Array($0.utf8) }
		return Target(
			name: "payload", seeds: seeds,
			dictionary: words(["&", "=", "%", "%25", "%2C", "%3A", "%5B", "%5D", "+", "v=2", "&a=", "&n=", "pi2://pair?", "wss%3A%2F%2F", "%C3%A9", "%FF", "::", "%E2%80%AE"]),
			maxLength: 5000
		) { input in
			var payload: PairingPayload?
			guard Fuzz.takes("payload", input, { payload = try PairingPayload.parse(text(input)) }) else { return false }
			var again: PairingPayload?
			guard Fuzz.takes("payload", input, { again = try PairingPayload.parse(payload!.text) }) else { Fuzz.violation("payload", "could not read what it wrote", input) }
			if again != payload { Fuzz.violation("payload", "read back as another payload", input) }
			return true
		}
	}

	static func controlLineSeeds(_ world: World) -> [[UInt8]] {
		let binding = Data(repeating: 7, count: 32)
		let challenge = Data(repeating: 9, count: 32)
		var lines: [ControlLine] = []
		lines.append(.mac(try! MacProof.make(challenge: challenge, pairing: world.pairing, binding: binding, identity: world.identity)))
		lines.append(.pair(try! PairClaim.make(device: world.description, attestation: Data(repeating: 0xa3, count: 120), keyId: "abc+/=", pairing: world.pairing, binding: binding, deviceKey: world.deviceKey)))
		lines.append(.pair(try! PairClaim.make(device: world.description, attestation: nil, keyId: nil, pairing: world.pairing, binding: binding, deviceKey: world.deviceKey)))
		lines.append(.paired(try! Paired(device: world.device, pairing: world.pairing, name: "Mac", addresses: ["10.0.0.1:1"], homeKey: world.homeKey)))
		lines.append(.homeKey(world.homeKey))
		lines.append(.attach(try! AttachClaim.make(
			pairing: world.pairing, device: world.device, session: SessionID("s1"), received: 3, binding: binding, challenge: challenge, build: "1.0",
			deviceKey: world.deviceKey, presenceKey: world.presenceKey)))
		lines.append(.attach(try! AttachClaim.make(
			pairing: world.pairing, device: world.device, session: nil, received: nil, binding: binding, challenge: challenge, build: "1.0",
			deviceKey: world.deviceKey, presenceKey: world.presenceKey)))
		lines.append(.attached(Attached(session: SessionID("s1")!, resume: true)))
		// The offer of a new presence key (#891), signed by the device key and by the key it offers; and the Mac's answer.
		lines.append(.presenceKey(try! PresenceKeyOffer.make(
			pairing: world.pairing, device: world.device, binding: binding, challenge: challenge, build: "1.0", deviceKey: world.deviceKey,
			offeredKey: world.presenceKey)))
		lines.append(.presenceKeyAccepted)
		lines.append(.revoked(try! Revocation.make(pairing: world.pairing, device: world.device, identity: world.identity)))
		lines.append(.sessionEnd)
		lines += Refusal.Reason.allCases.map { .refused(Refusal($0)) }
		lines += PairRefusal.Why.allCases.map { .pairRefused(PairRefusal($0)) }
		// A reason and a word from a newer Mac, which this build reads as a plain refusal.
		return lines.map { Array($0.line) } + [Array(#"{"refused":{"reason":"later"}}"#.utf8), Array(#"{"pairRefused":{"why":"later"}}"#.utf8)]
	}

	static func controlLines(_ world: World) -> Target {
		Target(
			name: "control-lines", seeds: controlLineSeeds(world),
			dictionary: words([
				"\\\"", "\\\\", "null", "true", "\"v\\\":2", "\"session\"", "\"received\":", "dev_", ",", "{}", "\\u0000", "\"refused\"", "\"reason\"",
				"\"update\"", "\"pairRefused\"", "\"why\"", "\"unsaved\"", "\\u0061", "\"homeKey\"", "\"key\"", "=", "AA",
				"\"presenceKey\"", "\"presenceKeyAccepted\"", "\\\"presenceKey\\\":", "\\\"build\\\":", "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE",
			]),
			maxLength: 8192
		) { input in
			var line: ControlLine?
			guard Fuzz.takes("control-lines", input, { line = try ControlLine.parse(Data(input)) }) else { return false }
			let written = line!.line
			var again: ControlLine?
			guard Fuzz.takes("control-lines", input, { again = try ControlLine.parse(written) }) else { Fuzz.violation("control-lines", "could not read what it wrote", input) }
			if again!.line != written { Fuzz.violation("control-lines", "wrote one line two ways", input) }
			if case let .refused(refusal) = line!, let reason = refusal.reason, written != ControlLine.refused(Refusal(reason)).line {
				Fuzz.violation("control-lines", "read a refusal as a reason it does not say", input)
			}
			if case let .pairRefused(refusal) = line!, let why = refusal.why, written != ControlLine.pairRefused(PairRefusal(why)).line {
				Fuzz.violation("control-lines", "read a pairing's refusal as a word it does not say", input)
			}
			// A home key, in paired or in homeKey, is exactly 32 bytes, and what was written is what it holds.
			switch line! {
			case let .homeKey(key):
				if key.rawRepresentation.count != HomeKey.length || written != ControlLine.homeKey(HomeKey(rawRepresentation: key.rawRepresentation)!).line {
					Fuzz.violation("control-lines", "read a home key that is not 32 bytes, or not as written", input)
				}
			case let .paired(paired):
				if paired.homeKey.rawRepresentation.count != HomeKey.length { Fuzz.violation("control-lines", "read a paired whose home key is not 32 bytes", input) }
			case let .presenceKey(offer):
				// An offer is taken only with its signed text in the engine's order and its key in the one form RemoteKit reads,
				// written back as the text said.
				guard case let .object(members) = offer.statement.value, members.map(\.0) == ["v", "kind", "pairing", "device", "binding", "challenge", "presenceKey", "build", "at"],
				      members[6].1.stringValue.map({ $0.utf8.elementsEqual(PublicKeys.text(offer.presenceKey).utf8) }) == true
				else { Fuzz.violation("control-lines", "read an offer whose signed text the engine would not read, or whose key is not as written", input) }
			default: break
			}
			// Each line has one writer: read as from it, it is taken; as from the other end, refused.
			let other: ControlLine.Side = line!.sender == .mac ? .phone : .mac
			if (try? ControlLine.parse(Data(input), from: line!.sender)) == nil { Fuzz.violation("control-lines", "refused a line from its own writer", input) }
			if (try? ControlLine.parse(Data(input), from: other)) != nil { Fuzz.violation("control-lines", "took a line from the end that never sends it", input) }
			return true
		}
	}

	/// The relay's text messages, as its client reads them (RemoteKit/Relay, #678). The first byte chooses the end that
	/// reads (a Mac registering, the Mac, a phone, a joining phone); a message taken is read again the same.
	static func relayMessages(_ world: World) -> Target {
		let ends: [RelayEnd] = [.registering, .mac, .device, .joining]
		let sealed = Base64URL.encode(Data([4]) + Data(repeating: 0x5A, count: 100))
		let device = world.device.text
		let item = Base64URL.encode(Data(repeating: 1, count: 16))
		let key = PublicKeys.text(world.deviceKey.publicKey)
		let keyID = Data(repeating: 2, count: 32).base64EncodedString()
		let left = #"{"device":"\#(device)","at":1800000000000,"notice":"\#(Base64URL.encode(Data(repeating: 4, count: 64)))"}"#
		let texts: [(UInt8, String)] = [
			(0, #"{"challenge":"\#(Base64URL.encode(Data(repeating: 3, count: 32)))"}"#),
			(0, #"{"registered":{"pairing":"\#(world.pairing.text)"}}"#),
			(1, #"{"ready":{"devices":[{"device":"\#(device)","online":true}],"left":[\#(left)],"pending":false,"mail":2}}"#),
			(1, #"{"left":\#(left)}"#),
			(2, #"{"ready":{"mac":true,"mail":0}}"#),
			(3, #"{"joined":{"device":"\#(device)"}}"#),
			(1, #"{"joined":{"device":"\#(device)","deviceKey":"\#(key)","keyId":"\#(keyID)"}}"#),
			(1, #"{"ok":{"what":"addDevice"}}"#),
			(2, #"{"refused":{"what":"put","why":"mailbox-full"}}"#),
			(1, #"{"refused":{"why":"another-mac"}}"#),
			(2, #"{"busy":{"until":1800000001000}}"#),
			(1, #"{"item":{"from":"\#(device)","id":"\#(item)","item":"\#(sealed)","presence":true}}"#),
			(2, #"{"item":{"from":"mac","id":"\#(item)","item":"\#(sealed)","presence":false}}"#),
			(2, #"{"state":{"id":"\#(item)","item":"\#(sealed)"}}"#),
			(1, #"{"taken":{"count":2}}"#),
			(1, #"{"held":{"device":"\#(device)","until":1800000001000}}"#),
			(3, #"{"mac":{"online":false}}"#),
			(1, #"{"anotherMac":{}}"#),
		]
		return Target(
			name: "relay-messages", seeds: texts.map { [$0.0] + Array($0.1.utf8) },
			dictionary: words(["\\\"", "\\u00", "true", "false", "null", "dev_", "\"mac\"", ",", "{}", "[]", "\"why\":", "\"what\":"]), maxLength: 2048
		) { input in
			guard let first = input.first else { return false }
			let end = ends[Int(first) % ends.count]
			let text = String(decoding: input.dropFirst(), as: UTF8.self)
			var message: RelayIncoming?
			guard Fuzz.takes("relay-messages", input, { message = try RelayIncoming.parse(text, for: end) }) else { return false }
			var again: RelayIncoming?
			guard Fuzz.takes("relay-messages", input, { again = try RelayIncoming.parse(text, for: end) }), again == message else {
				Fuzz.violation("relay-messages", "read one text two ways", input)
			}
			return true
		}
	}

	/// The Mac's check of a phone's leave notice (#813): the input is a device's 16 bytes, a time's 8 and a notice's 64,
	/// as the relay could pass them on; only the very notice the device key signed, for that device and time, is taken.
	static func relayLeave(_ world: World) -> Target {
		let at: Int64 = 1_800_000_000_000
		let text = try! RelayLeaveNotice.text(pairing: world.pairing, device: world.device, identityKey: world.identity.publicKey, at: at)
		let notice = try! world.deviceKey.sign(text)
		let deviceBytes = Base64URL.decode(String(world.device.text.dropFirst(4)), count: 16)!
		let seed = Array(deviceBytes) + withUnsafeBytes(of: at.bigEndian) { Array($0) } + Array(notice)
		return Target(name: "relay-leave", seeds: [seed], maxLength: 88) { input in
			guard input.count == 88 else { return false }
			let device = DeviceID("dev_" + Base64URL.encode(Data(input[0..<16])))!
			let time = input[16..<24].reduce(Int64(0)) { $0 << 8 | Int64($1) }
			let left = RelayLeft(device: device, at: time, notice: Data(input[24...]))
			let taken = left.verified(pairing: world.pairing, identityKey: world.identity.publicKey, deviceKey: world.deviceKey.publicKey, now: at) != nil
			if taken, input != seed { Fuzz.violation("relay-leave", "took a leave the device key did not sign", input) }
			return taken
		}
	}

	/// The phone's check of the tag in a TXT record (#815, #845): it takes the three days' tags of its home key and nothing
	/// else.
	static func homeTag(_ world: World) -> Target {
		let now = Date(timeIntervalSince1970: 1_795_000_000)
		let seeds = [-1.0, 0, 1].map { Array(HomeTag.tag(key: world.homeKey, pairing: world.pairing, date: now.addingTimeInterval($0 * 86_400)).utf8) }
		return Target(name: "home-tag", seeds: seeds, dictionary: words(["0", "f", "F"]), maxLength: 64) { input in
			let taken = HomeTag.recognises(text(input), key: world.homeKey, pairing: world.pairing, now: now)
			if taken, !seeds.contains(input) { Fuzz.violation("home-tag", "took a tag that is not one of the three days'", input) }
			return taken
		}
	}

	// MARK: Handshakes: only the very messages made for them may be taken

	static func refuseAllBut(_ name: String, _ seeds: [[UInt8]], _ input: [UInt8], taken: Bool) -> Bool {
		if taken, !seeds.contains(input) { Fuzz.violation(name, "took a handshake message that was not made for it", input) }
		return taken
	}

	static func kkInitiatorSide(_ world: World, _ ephemeral: Int) throws -> ChannelHandshake {
		try ChannelHandshake.connection(
			initiator: true, pairing: world.pairing, device: world.device, channelKey: world.phoneChannel,
			remoteChannelKey: world.macChannel.publicKey, ephemeral: world.ephemerals[ephemeral])
	}

	static func kkResponderSide(_ world: World, _ ephemeral: Int) throws -> ChannelHandshake {
		try ChannelHandshake.connection(
			initiator: false, pairing: world.pairing, device: world.device, channelKey: world.macChannel,
			remoteChannelKey: world.phoneChannel.publicKey, ephemeral: world.ephemerals[ephemeral])
	}

	// A handshake or a channel is one state shared by all its holders (Noise.swift), so each input gets a side of its
	// own, made again from the same keys and ephemeral keys: the same seed makes the same sides.

	static func kkResponder(_ world: World) throws -> Target {
		let seeds = try (0..<3).map { index -> [UInt8] in Array(try kkInitiatorSide(world, index).writeMessage()) }
		return Target(name: "kk-responder", seeds: seeds, maxLength: 256) { input in
			guard let side = try? kkResponderSide(world, 3) else { Fuzz.violation("kk-responder", "could not make its side", input) }
			let taken = Fuzz.takes("kk-responder", input) { try side.readMessage(Data(input)) }
			return refuseAllBut("kk-responder", seeds, input, taken: taken)
		}
	}

	static func kkInitiator(_ world: World) throws -> Target {
		let first = try kkInitiatorSide(world, 0).writeMessage()
		let seeds = try (3..<6).map { index -> [UInt8] in
			let side = try kkResponderSide(world, index)
			try side.readMessage(first)
			return Array(try side.writeMessage())
		}
		return Target(name: "kk-initiator", seeds: seeds, maxLength: 256) { input in
			guard let side = try? kkInitiatorSide(world, 0), (try? side.writeMessage()) != nil else { Fuzz.violation("kk-initiator", "could not make its side", input) }
			let taken = Fuzz.takes("kk-initiator", input) { try side.readMessage(Data(input)) }
			return refuseAllBut("kk-initiator", seeds, input, taken: taken)
		}
	}

	static func kkRespondByTrial(_ world: World) throws -> Target {
		let seeds = try (0..<2).map { index -> [UInt8] in Array(try kkInitiatorSide(world, index).writeMessage()) }
		let devices = [(world.otherDevice, world.otherChannel.publicKey), (world.device, world.phoneChannel.publicKey)]
		return Target(name: "kk-respond-by-trial", seeds: seeds, maxLength: 256) { input in
			var found: DeviceID?
			let taken = Fuzz.takes("kk-respond-by-trial", input) {
				found = try ChannelHandshake.respond(toFirstMessage: Data(input), pairing: world.pairing, channelKey: world.macChannel, devices: devices).0
			}
			if taken, found != world.device { Fuzz.violation("kk-respond-by-trial", "found the wrong device", input) }
			return refuseAllBut("kk-respond-by-trial", seeds, input, taken: taken)
		}
	}

	static func pairingResponderSide(_ world: World) throws -> ChannelHandshake {
		try ChannelHandshake.pairingResponder(pairing: world.pairing, secret: world.secret, channelKey: world.macChannel, ephemeral: world.ephemerals[3])
	}

	static func pairingResponder(_ world: World) throws -> Target {
		let seeds = try (0..<3).map { index -> [UInt8] in
			Array(try ChannelHandshake.pairingInitiator(payload: world.payload, channelKey: world.phoneChannel, ephemeral: world.ephemerals[index]).writeMessage())
		}
		return Target(name: "ikpsk2-responder", seeds: seeds, maxLength: 256) { input in
			guard let side = try? pairingResponderSide(world) else { Fuzz.violation("ikpsk2-responder", "could not make its side", input) }
			let taken = Fuzz.takes("ikpsk2-responder", input) { try side.readMessage(Data(input)) }
			if taken, !Bytes.constantTimeEqual(side.remoteChannelKey!.rawRepresentation, world.phoneChannel.publicKey.rawRepresentation) {
				Fuzz.violation("ikpsk2-responder", "learnt another channel key", input)
			}
			return refuseAllBut("ikpsk2-responder", seeds, input, taken: taken)
		}
	}

	static func pairingInitiatorSide(_ world: World) throws -> ChannelHandshake {
		try ChannelHandshake.pairingInitiator(payload: world.payload, channelKey: world.phoneChannel, ephemeral: world.ephemerals[0])
	}

	static func pairingInitiator(_ world: World) throws -> Target {
		let first = try pairingInitiatorSide(world).writeMessage()
		let seeds = try (3..<6).map { index -> [UInt8] in
			let side = try ChannelHandshake.pairingResponder(pairing: world.pairing, secret: world.secret, channelKey: world.macChannel, ephemeral: world.ephemerals[index])
			try side.readMessage(first)
			return Array(try side.writeMessage())
		}
		return Target(name: "ikpsk2-initiator", seeds: seeds, maxLength: 256) { input in
			guard let side = try? pairingInitiatorSide(world), (try? side.writeMessage()) != nil else { Fuzz.violation("ikpsk2-initiator", "could not make its side", input) }
			let taken = Fuzz.takes("ikpsk2-initiator", input) { try side.readMessage(Data(input)) }
			return refuseAllBut("ikpsk2-initiator", seeds, input, taken: taken)
		}
	}

	// MARK: Transport and items

	/// A fresh pair of channels, always with the same keys, both opened at `opened`.
	static func channels(_ world: World, opened: ContinuousClock.Instant) throws -> (phone: Channel, mac: Channel) {
		let phone = try kkInitiatorSide(world, 6)
		let mac = try kkResponderSide(world, 7)
		try mac.readMessage(try phone.writeMessage())
		try phone.readMessage(try mac.writeMessage())
		let sender = try phone.channel(openedAt: opened, maxLineLength: Lines.defaultMaxLength)
		sender.padding = Frame.paddingBlock
		return (sender, try mac.channel(openedAt: opened))
	}

	static func transport(_ world: World) throws -> Target {
		let opened = ContinuousClock.now
		// Each seed is a first message, made from a fresh sender.
		var seeds: [[UInt8]] = []
		for make in [
			{ (channel: Channel) in try channel.seal(line: Data("{\"id\":1}".utf8), at: opened)[0] },
			{ (channel: Channel) in try channel.seal(line: Data(repeating: 0x61, count: 70_000), at: opened)[0] },
			{ (channel: Channel) in try channel.sealAck(5, at: opened) },
			{ (channel: Channel) in try channel.sealPing(at: opened) },
			{ (channel: Channel) in try channel.sealBye() },
		] {
			seeds.append(Array(try make(try channels(world, opened: opened).phone)))
		}
		return Target(name: "transport", seeds: seeds, maxLength: Noise.maxMessageLength + 4) { input in
			guard let receiver = try? channels(world, opened: opened).mac else { Fuzz.violation("transport", "could not make its channel", input) }
			let taken = Fuzz.takes("transport", input) { _ = try receiver.open(Data(input), at: opened) }
			if taken, !seeds.contains(input) { Fuzz.violation("transport", "took a transport message that was not made for it", input) }
			return taken
		}
	}

	static func sealedItem(_ world: World) throws -> Target {
		let address = ItemAddress(pairing: world.pairing, reader: .mac, id: ItemID(Base64URL.encode(Data(repeating: 5, count: 16)))!)
		let seeds = try requestSeeds(world, address).map { Array(try SealedItem.seal(Data($0), to: address, readerKey: world.macRecord.publicKey, writerKey: world.phoneRecord)) }
		return Target(name: "sealed-item", seeds: seeds, maxLength: SealedItem.maxLength + 16) { input in
			var plaintext = Data()
			let taken = Fuzz.takes("sealed-item", input) {
				plaintext = try SealedItem.open(Data(input), at: address, readerKey: world.macRecord, writerKey: world.phoneRecord.publicKey)
			}
			if taken, !seeds.contains(input) { Fuzz.violation("sealed-item", "opened an item that was not sealed for it", input) }
			if taken, (try? RequestItem.read(plaintext)) == nil { Fuzz.violation("sealed-item", "opened to something other than what was sealed", input) }
			return taken
		}
	}

	static func requestSeeds(_ world: World, _ address: ItemAddress) throws -> [[UInt8]] {
		[
			try RequestItem.make(
				method: "needs.answer", params: .object([("need", .string("n1")), ("answer", .array([.integer(1), .null, .bool(true)]))]), pairing: world.pairing,
				device: world.device, id: address.id, deviceKey: world.deviceKey, presenceKey: world.presenceKey),
			try RequestItem.make(
				method: "submit", params: .object([("text", .string("hello \u{1F600}"))]), pairing: world.pairing, device: world.device, id: address.id,
				deviceKey: world.deviceKey, presenceKey: world.presenceKey),
		].map { Array($0.plaintext) }
	}

	static func requestItem(_ world: World) -> Target {
		let address = ItemAddress(pairing: world.pairing, reader: .mac, id: ItemID(Base64URL.encode(Data(repeating: 5, count: 16)))!)
		let seeds = (try? requestSeeds(world, address)) ?? []
		// What the keys signed: an item that verifies must hold one of these texts, signed, and nothing else.
		let signed = Set(seeds.compactMap { try? RequestItem.read(Data($0)).statement.text })
		return Target(name: "request-item", seeds: seeds, dictionary: words(["\\\"", "\"presence\":", "\"params\":", "null", ","]), maxLength: 16384) { input in
			var item: RequestItem?
			guard Fuzz.takes("request-item", input, { item = try RequestItem.read(Data(input)) }) else { return false }
			var again: RequestItem?
			guard Fuzz.takes("request-item", input, { again = try RequestItem.read(item!.plaintext) }) else { Fuzz.violation("request-item", "could not read what it wrote", input) }
			if again!.plaintext != item!.plaintext { Fuzz.violation("request-item", "wrote one item two ways", input) }
			// Signatures that verify are over exactly what the device key and the presence key signed.
			if (try? item!.verify(deviceKey: world.deviceKey.publicKey, presenceKey: world.presenceKey.publicKey, writer: world.device, address: address)) != nil,
				!signed.contains(item!.statement.text)
			{
				Fuzz.violation("request-item", "verified a text the device key never signed", input)
			}
			return true
		}
	}

	static func macItem(_ world: World) -> Target {
		let address = ItemAddress(pairing: world.pairing, reader: .device(world.device), id: ItemID(Base64URL.encode(Data(repeating: 6, count: 16)))!)
		let seeds = [
			try? MacItem.make(kind: "state", number: 3, body: .object([("needs", .array([]))]), pairing: world.pairing, device: world.device, id: address.id, identity: world.identity),
			try? MacItem.make(kind: "receipt", body: .string("This is no longer waiting."), pairing: world.pairing, device: world.device, id: address.id, identity: world.identity),
		].compactMap { $0.map { Array($0.plaintext) } }
		let signed = Set(seeds.compactMap { try? MacItem.read(Data($0)).statement.text })
		return Target(name: "mac-item", seeds: seeds, dictionary: words(["\\\"", "\"number\\\":", "\"state\"", ","]), maxLength: 16384) { input in
			var item: MacItem?
			guard Fuzz.takes("mac-item", input, { item = try MacItem.read(Data(input)) }) else { return false }
			var again: MacItem?
			guard Fuzz.takes("mac-item", input, { again = try MacItem.read(item!.plaintext) }) else { Fuzz.violation("mac-item", "could not read what it wrote", input) }
			if again!.plaintext != item!.plaintext { Fuzz.violation("mac-item", "wrote one item two ways", input) }
			// A signature that verifies is over exactly what the identity key signed.
			if (try? item!.verify(identityKey: world.identity.publicKey, address: address)) != nil, !signed.contains(item!.statement.text) {
				Fuzz.violation("mac-item", "verified a text the identity key never signed", input)
			}
			return true
		}
	}
}

extension String {
	/// Byte for byte, as RemoteKit compares texts.
	func sameBytesAs(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }
}
