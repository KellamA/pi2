import CryptoKit
import Foundation
import RemoteKit

/// A pairing and a connection between two ends of the check's own, a phone and a stand-in for pi² Remote, in memory
/// (#674: "a pair and a KK session run between two test ends"). Every key is made in software, here; nothing touches a
/// key store or the network.
enum Sessions {
	/// The Mac's keys (iphone.md 3.2).
	struct Mac {
		let identity = P256.Signing.PrivateKey()
		let channel = Curve25519.KeyAgreement.PrivateKey()
		let record = P256.KeyAgreement.PrivateKey()
	}

	/// The phone's keys (3.2). On a phone the device and presence keys are in the Secure Enclave.
	struct Phone {
		let device = P256.Signing.PrivateKey()
		let presence = P256.Signing.PrivateKey()
		let channel = Curve25519.KeyAgreement.PrivateKey()
		let record = P256.KeyAgreement.PrivateKey()

		var description: DeviceDescription {
			DeviceDescription(
				name: "Test iPhone", model: "iPhone 17 Pro", system: "iOS 27.1", build: "1.0.42", deviceKey: device.publicKey,
				presenceKey: presence.publicKey, channelKey: channel.publicKey, recordKey: record.publicKey)
		}
	}

	/// Every secret the two ends hold, as text in each form a log could hold it, for `errorsHoldNoSecret`.
	nonisolated(unsafe) static var secrets: [Data] = []

	static func run() {
		let mac = Mac()
		let phone = Phone()
		let pairing = PairingID.random()
		let secret = Bytes.random(32)
		secrets += [
			secret, mac.identity.rawRepresentation, mac.channel.rawRepresentation, mac.record.rawRepresentation, phone.device.rawRepresentation,
			phone.presence.rawRepresentation, phone.channel.rawRepresentation, phone.record.rawRepresentation,
		]
		Check.section("Pairing: a phone and pi² Remote, over the TCP path's framing")
		guard let paired = pair(mac: mac, phone: phone, pairing: pairing, secret: secret) else { return }
		Check.section("A connection: KK, the Mac's proof, attach, lines, acks, padding, bye")
		guard let session = connect(mac: mac, phone: phone, pairing: pairing, device: paired.device) else { return }
		Check.section("Resuming through attach, on a new channel")
		resume(mac: mac, phone: phone, pairing: pairing, device: paired.device, session: session)
		Check.section("Pairing and connecting refused")
		refusals(mac: mac, phone: phone, pairing: pairing, secret: secret, device: paired.device)
		Check.section("Sealed items, signed by their writer")
		sealing(mac: mac, phone: phone, pairing: pairing, device: paired.device)
	}

	/// Carries Noise messages from one end to the other as the TCP path does: each preceded by its length, the bytes in
	/// pieces of every size.
	struct Wire {
		var deframer = LengthFraming()
		var pieceSize = 1

		mutating func carry(_ message: Data) throws -> Data {
			let framed = try LengthFraming.encode(message)
			var out: [Data] = []
			var offset = framed.startIndex
			while offset < framed.endIndex {
				let end = min(offset + pieceSize, framed.endIndex)
				out += try deframer.push(Data(framed[offset..<end]))
				offset = end
			}
			pieceSize = pieceSize % 97 + 7
			guard out.count == 1, deframer.buffered == 0 else { throw RemoteKitError("wire", "did not carry one message") }
			return out[0]
		}
	}

	static func line(_ channel: inout Channel, _ event: ChannelEvent?) throws -> ControlLine {
		guard case let .line(bytes) = event else { throw RemoteKitError("check", "no line") }
		return try ControlLine.parse(bytes)
	}

	/// Sends one control line through both channels' ends and reads it on the other.
	static func send(_ line: ControlLine, from sender: inout Channel, to receiver: inout Channel, wire: inout Wire) throws -> ControlLine {
		var last: ChannelEvent?
		for message in try sender.seal(line: line.line) {
			last = try receiver.open(try wire.carry(message))
		}
		return try Self.line(&receiver, last)
	}

	struct PairResult {
		let device: DeviceID
	}

	static func pair(mac: Mac, phone: Phone, pairing: PairingID, secret: Data) -> PairResult? {
		do {
			var wire = Wire()
			// The Mac makes the payload; the phone reads it from the QR code.
			let payload = try PairingPayload(
				pairing: pairing, macName: "Alex’s MacBook Pro", channelKey: mac.channel.publicKey, identityKey: mac.identity.publicKey,
				recordKey: mac.record.publicKey, secret: secret, relay: "wss://relay.example.dev/v1",
				addresses: ["192.168.1.20:52000", "[fd7a:115c:a1e0::1]:52000"], expires: Int64(Date().timeIntervalSince1970) + 300)
			let scanned = try PairingPayload.parse(payload.text)
			Check.that(scanned == payload, "the payload reads back as written")
			Check.that(!String(describing: scanned).contains(Base64URL.encode(secret)), "a payload's description leaves out its secret")

			// The handshake: IKpsk2, the phone first.
			var phoneHandshake = try ChannelHandshake.pairingInitiator(payload: scanned, channelKey: phone.channel)
			var macHandshake = try ChannelHandshake.pairingResponder(pairing: pairing, secret: secret, channelKey: mac.channel)
			let first = try phoneHandshake.writeMessage()
			Check.that(first.count == 96, "the first pairing message is e, s and two tags, with no payload (96 bytes)")
			try macHandshake.readMessage(try wire.carry(first))
			let second = try macHandshake.writeMessage()
			Check.that(second.count == 48, "the second pairing message is e and a tag (48 bytes)")
			try phoneHandshake.readMessage(try wire.carry(second))
			var phoneChannel = try phoneHandshake.channel()
			var macChannel = try macHandshake.channel()
			phoneChannel.padding = Frame.paddingBlock
			Check.that(Bytes.constantTimeEqual(phoneChannel.handshakeHash, macChannel.handshakeHash), "both ends have the same channel binding")
			Check.that(Bytes.constantTimeEqual(macChannel.remoteChannelKey, phone.channel.publicKey.rawRepresentation), "the Mac learns the phone's channel key")

			// The Mac's proof, then the phone's claim.
			let challenge = Bytes.random(32)
			let proof = try MacProof.make(challenge: challenge, pairing: pairing, binding: macChannel.handshakeHash, identity: mac.identity)
			guard case let .mac(receivedProof) = try send(.mac(proof), from: &macChannel, to: &phoneChannel, wire: &wire) else {
				throw RemoteKitError("check", "not a proof")
			}
			Check.runs("the phone takes the Mac's proof") {
				try receivedProof.verify(identityKey: scanned.identityKey, pairing: pairing, binding: phoneChannel.handshakeHash)
			}
			let claim = try PairClaim.make(
				device: phone.description, attestation: nil, keyId: nil, pairing: pairing, binding: phoneChannel.handshakeHash, deviceKey: phone.device)
			guard case let .pair(receivedClaim) = try send(.pair(claim), from: &phoneChannel, to: &macChannel, wire: &wire) else {
				throw RemoteKitError("check", "not a claim")
			}
			Check.runs("pi² Remote takes the phone's claim") {
				try receivedClaim.verify(pairing: pairing, binding: macChannel.handshakeHash, handshakeChannelKey: macChannel.remoteChannelKey)
			}
			Check.that(
				Bytes.constantTimeEqual(
					PairingSecrets.attestationClientDataHash(challenge: challenge, deviceKey: receivedClaim.device.deviceKey, binding: macChannel.handshakeHash),
					PairingSecrets.attestationClientDataHash(challenge: receivedProof.challenge, deviceKey: phone.device.publicKey, binding: phoneChannel.handshakeHash)),
				"both ends work out the same client data hash for App Attest")

			// The digits: the phone shows them, the person types them on the Mac.
			let shown = PairingSecrets.digits(secret: scanned.secret, binding: phoneChannel.handshakeHash)
			let expected = PairingSecrets.digits(secret: secret, binding: macChannel.handshakeHash)
			Check.that(shown.count == 6 && shown.allSatisfy(\.isNumber), "the digits are six digits")
			Check.that(PairingSecrets.digitsMatch(shown, expected), "the digits the phone shows are the ones the Mac expects")
			Check.that(!PairingSecrets.digitsMatch(shown, String(shown.reversed()) == shown ? "000000" : String(shown.reversed())), "other digits do not match")

			let device = DeviceID.random()
			let answer = try Paired(device: device, pairing: pairing, name: scanned.macName, addresses: scanned.addresses)
			guard case let .paired(received) = try send(.paired(answer), from: &macChannel, to: &phoneChannel, wire: &wire) else {
				throw RemoteKitError("check", "not paired")
			}
			Check.that(received == answer, "the phone reads paired as the Mac wrote it")
			print("ok   paired: one IKpsk2 handshake, the Mac's proof, pair, the digits, paired")
			return PairResult(device: device)
		} catch {
			Check.that(false, "pairing: \(error)")
			return nil
		}
	}

	static func kk(mac: Mac, phone: Phone, pairing: PairingID, device: DeviceID) throws -> (Channel, Channel) {
		var wire = Wire()
		var phoneHandshake = try ChannelHandshake.connection(
			initiator: true, pairing: pairing, device: device, channelKey: phone.channel, remoteChannelKey: mac.channel.publicKey)
		let first = try phoneHandshake.writeMessage()
		// The TCP path does not say which device is calling: pi² Remote tries its paired devices' keys.
		let other = (DeviceID.random(), Curve25519.KeyAgreement.PrivateKey().publicKey)
		var (found, macHandshake) = try ChannelHandshake.respond(
			toFirstMessage: try wire.carry(first), pairing: pairing, channelKey: mac.channel, devices: [other, (device, phone.channel.publicKey)])
		guard found == device else { throw RemoteKitError("check", "the wrong device was found") }
		try phoneHandshake.readMessage(try wire.carry(try macHandshake.writeMessage()))
		var phoneChannel = try phoneHandshake.channel()
		phoneChannel.padding = Frame.paddingBlock
		return (phoneChannel, try macHandshake.channel())
	}

	static func connect(mac: Mac, phone: Phone, pairing: PairingID, device: DeviceID) -> SessionID? {
		do {
			var wire = Wire()
			var (phoneChannel, macChannel) = try kk(mac: mac, phone: phone, pairing: pairing, device: device)
			Check.that(Bytes.constantTimeEqual(phoneChannel.handshakeHash, macChannel.handshakeHash), "a KK connection: both ends have the same binding")

			// The engine's challenge comes with the Mac's proof; the phone attaches.
			let challenge = Bytes.random(32)
			let proof = try MacProof.make(challenge: challenge, pairing: pairing, binding: macChannel.handshakeHash, identity: mac.identity)
			guard case let .mac(receivedProof) = try send(.mac(proof), from: &macChannel, to: &phoneChannel, wire: &wire) else {
				throw RemoteKitError("check", "not a proof")
			}
			try receivedProof.verify(identityKey: mac.identity.publicKey, pairing: pairing, binding: phoneChannel.handshakeHash)
			let attach = try AttachClaim.make(
				pairing: pairing, device: device, session: nil, received: nil, binding: phoneChannel.handshakeHash, challenge: receivedProof.challenge,
				build: "1.0.42", deviceKey: phone.device, presenceKey: phone.presence)
			guard case let .attach(receivedAttach) = try send(.attach(attach), from: &phoneChannel, to: &macChannel, wire: &wire) else {
				throw RemoteKitError("check", "not an attach")
			}
			Check.runs("pi² Remote finds the attach signed by a device on its own list") {
				try receivedAttach.verifyDevice(deviceKey: phone.device.publicKey, pairing: pairing, device: device, binding: macChannel.handshakeHash)
			}
			Check.runs("the attach passes the engine's whole check: both signatures, binding, challenge, time") {
				try receivedAttach.verify(
					deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, pairing: pairing, device: device,
					binding: macChannel.handshakeHash, challenge: challenge)
			}
			let session = SessionID("s1")!
			guard case let .attached(attached) = try send(.attached(Attached(session: session, resume: false)), from: &macChannel, to: &phoneChannel, wire: &wire) else {
				throw RemoteKitError("check", "not attached")
			}
			Check.that(attached.session == session && !attached.resume, "the phone reads attached")

			// Engine lines both ways, a long one in pieces.
			let request = Data(#"{"id":1,"method":"projects.list","params":{}}"#.utf8)
			let phoneMessages = try phoneChannel.seal(line: request)
			Check.that(phoneMessages.allSatisfy { ($0.count - Noise.tagLength) % Frame.paddingBlock == 0 }, "the phone pads its frames to the next 256 bytes")
			var events: [ChannelEvent?] = []
			for message in phoneMessages { events.append(try macChannel.open(try wire.carry(message))) }
			Check.that(events.last == .line(request), "a line from the phone arrives whole")
			let long = Data((0..<200_000).map { _ in UInt8.random(in: 0x20...0x7e) })
			let longMessages = try macChannel.seal(line: long)
			Check.that(longMessages.count == 4, "a line longer than a frame goes as more frames and a data frame")
			events = []
			for message in longMessages { events.append(try phoneChannel.open(try wire.carry(message))) }
			Check.that(events.dropLast().allSatisfy { $0 == nil } && events.last == .line(long), "the long line arrives whole, once")
			Check.that(try macChannel.open(try wire.carry(try phoneChannel.sealAck(2))) == .ack(2), "an ack carries its count")
			Check.that(try phoneChannel.open(try wire.carry(try macChannel.sealPing())) == .ping, "a ping arrives")
			Check.that(try ControlLine.parse(ControlLine.sessionEnd.line).line == ControlLine.sessionEnd.line, "sessionEnd reads back")

			// A message changed on the way, played twice, or out of order is refused, and the channel is over.
			var copy = phoneChannel
			var macCopy = macChannel
			let one = try copy.seal(line: request)[0]
			let two = try copy.seal(line: request)[0]
			Check.refuses("a message out of order") { _ = try macCopy.open(two) }
			Check.refuses("a channel that refused a message takes nothing more") { _ = try macCopy.open(one) }
			macCopy = macChannel
			var changed = one
			changed[changed.startIndex + 5] ^= 0x40
			Check.refuses("a message with one bit changed") { _ = try macCopy.open(changed) }
			macCopy = macChannel
			_ = try macCopy.open(one)
			Check.refuses("a message played twice") { _ = try macCopy.open(one) }

			// A day old, the channel is made again.
			var old = macChannel
			Check.refuses("a channel over a day old") { _ = try old.seal(line: request, at: Date().addingTimeInterval(Channel.lifetime + 1)) }
			// bye ends it.
			Check.that(try macChannel.open(try wire.carry(try phoneChannel.sealBye())) == .bye, "bye arrives")
			Check.that(macChannel.isOver && phoneChannel.isOver, "after bye both ends are over")
			Check.refuses("nothing is sent after bye") { _ = try phoneChannel.seal(line: request) }
			print("ok   a KK session: the Mac's proof, attach with presence, attached, lines, acks, pings, padding and bye")
			return session
		} catch {
			Check.that(false, "connecting: \(error)")
			return nil
		}
	}

	static func resume(mac: Mac, phone: Phone, pairing: PairingID, device: DeviceID, session: SessionID) {
		do {
			var wire = Wire()
			let (first, _) = try kk(mac: mac, phone: phone, pairing: pairing, device: device)
			var (phoneChannel, macChannel) = try kk(mac: mac, phone: phone, pairing: pairing, device: device)
			Check.that(!Bytes.constantTimeEqual(first.handshakeHash, phoneChannel.handshakeHash), "every channel has its own binding")
			let challenge = Bytes.random(32)
			let oldAttach = try AttachClaim.make(
				pairing: pairing, device: device, session: session, received: 9, binding: first.handshakeHash, challenge: challenge, build: "1.0.42",
				deviceKey: phone.device, presenceKey: phone.presence)
			Check.refuses("an attach made for another channel is refused on this one") {
				try oldAttach.verify(
					deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, pairing: pairing, device: device,
					binding: macChannel.handshakeHash, challenge: challenge)
			}
			let resume = try AttachClaim.make(
				pairing: pairing, device: device, session: session, received: 9, binding: phoneChannel.handshakeHash, challenge: challenge,
				build: "1.0.42", deviceKey: phone.device, presenceKey: phone.presence)
			guard case let .attach(received) = try send(.attach(resume), from: &phoneChannel, to: &macChannel, wire: &wire) else {
				throw RemoteKitError("check", "not an attach")
			}
			Check.that(received.session == session && received.received == 9, "a resume names its session and the lines the phone has")
			Check.runs("a resume, freshly signed over the new channel, passes the whole check") {
				try received.verify(
					deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, pairing: pairing, device: device,
					binding: macChannel.handshakeHash, challenge: challenge)
			}
			let other = P256.Signing.PrivateKey()
			Check.refuses("an attach with another challenge") {
				try received.verify(
					deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, pairing: pairing, device: device,
					binding: macChannel.handshakeHash, challenge: Bytes.random(32))
			}
			Check.refuses("an attach whose presence signature is another key's") {
				let forged = try AttachClaim.make(
					pairing: pairing, device: device, session: session, received: 9, binding: phoneChannel.handshakeHash, challenge: challenge,
					build: "1.0.42", deviceKey: phone.device, presenceKey: other)
				try forged.verify(
					deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, pairing: pairing, device: device,
					binding: macChannel.handshakeHash, challenge: challenge)
			}
			Check.refuses("an attach signed by a key not on pi² Remote's list") {
				try received.verifyDevice(deviceKey: other.publicKey, pairing: pairing, device: device, binding: macChannel.handshakeHash)
			}
			Check.refuses("an attach for another device") {
				try received.verifyDevice(deviceKey: phone.device.publicKey, pairing: pairing, device: DeviceID.random(), binding: macChannel.handshakeHash)
			}
			Check.refuses("an attach signed three minutes ago") {
				let stale = try AttachClaim.make(
					pairing: pairing, device: device, session: nil, received: nil, binding: phoneChannel.handshakeHash, challenge: challenge,
					build: "1.0.42", at: Date().addingTimeInterval(-180), deviceKey: phone.device, presenceKey: phone.presence)
				try stale.verify(
					deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, pairing: pairing, device: device,
					binding: macChannel.handshakeHash, challenge: challenge)
			}
			Check.refuses("a resume without its count") {
				_ = try AttachClaim.make(
					pairing: pairing, device: device, session: session, received: nil, binding: phoneChannel.handshakeHash, challenge: challenge,
					build: "1.0.42", deviceKey: phone.device, presenceKey: phone.presence)
			}
			// The signed text is the text: an attach whose signed text is changed, even only its spacing, is not signed.
			let line = String(decoding: ControlLine.attach(received).line, as: UTF8.self)
			let respaced = line.replacingOccurrences(of: #"\"v\":2"#, with: #"\"v\": 2"#)
			Check.that(respaced != line, "the check can change an attach's spacing")
			if case let .attach(changed) = try ControlLine.parse(Data(respaced.utf8)) {
				Check.refuses("an attach whose signed text was changed") {
					try changed.verifyDevice(deviceKey: phone.device.publicKey, pairing: pairing, device: device, binding: macChannel.handshakeHash)
				}
			}
			let revocation = try Revocation.make(pairing: pairing, device: device, identity: mac.identity)
			guard case let .revoked(receivedRevocation) = try send(.revoked(revocation), from: &macChannel, to: &phoneChannel, wire: &wire) else {
				throw RemoteKitError("check", "not revoked")
			}
			Check.runs("the phone takes a revocation its Mac signed") {
				try receivedRevocation.verify(identityKey: mac.identity.publicKey, pairing: pairing, device: device)
			}
			Check.refuses("a revocation not signed by the Mac's identity key") {
				try Revocation.make(pairing: pairing, device: device, identity: other).verify(identityKey: mac.identity.publicKey, pairing: pairing, device: device)
			}
			Check.refuses("a revocation of another device") {
				try receivedRevocation.verify(identityKey: mac.identity.publicKey, pairing: pairing, device: DeviceID.random())
			}
		} catch {
			Check.that(false, "resuming: \(error)")
		}
	}

	static func refusals(mac: Mac, phone: Phone, pairing: PairingID, secret: Data, device: DeviceID) {
		do {
			let payload = try PairingPayload(
				pairing: pairing, macName: "Mac", channelKey: mac.channel.publicKey, identityKey: mac.identity.publicKey, recordKey: mac.record.publicKey,
				secret: secret, relay: "ws://127.0.0.1:8787/v1", addresses: [], expires: 1)

			// A wrong secret: the claimer cannot read the Mac's answer, and the Mac cannot read what it sends next.
			var wrong = payload
			wrong.secret = Bytes.random(32)
			var attacker = try ChannelHandshake.pairingInitiator(payload: wrong, channelKey: Curve25519.KeyAgreement.PrivateKey())
			var macSide = try ChannelHandshake.pairingResponder(pairing: pairing, secret: secret, channelKey: mac.channel)
			try macSide.readMessage(try attacker.writeMessage())
			let answer = try macSide.writeMessage()
			Check.refuses("a claimer without the secret cannot complete the pairing handshake") { try attacker.readMessage(answer) }
			// The Mac's side completes; the first transport message a claimer without the secret sends fails, which is
			// where pi² Remote counts a wrong try (3.1).
			var macChannel = try macSide.channel()
			let forgedKeys = SymmetricKey(size: .bits256)
			let garbage = try ChaChaPoly.seal(Data([1, 0, 1, 0x7b]), using: forgedKeys).ciphertext + Data(repeating: 0, count: 16)
			Check.refuses("the Mac refuses the first message of a claimer without the secret") { _ = try macChannel.open(garbage) }

			// A pairing handshake made for another pairing.
			var elsewhere = payload
			elsewhere.pairing = PairingID.random()
			var other = try ChannelHandshake.pairingInitiator(payload: elsewhere, channelKey: phone.channel)
			var macOther = try ChannelHandshake.pairingResponder(pairing: pairing, secret: secret, channelKey: mac.channel)
			let otherFirst = try other.writeMessage()
			Check.refuses("a pairing handshake made for another pairing") { try macOther.readMessage(otherFirst) }

			// A handshake message with a payload: Noise allows one, the channel takes none.
			var withPayload = try NoiseHandshake(
				pattern: .kk, initiator: true, prologue: Data("pi2-v2".utf8) + Data([0]) + Data(pairing.text.utf8) + Data([0]) + Data(device.text.utf8),
				localStatic: phone.channel, remoteStatic: mac.channel.publicKey.rawRepresentation, psk: nil)
			let carrying = try withPayload.writeMessage(payload: Data("hello".utf8))
			var macKK = try ChannelHandshake.connection(
				initiator: false, pairing: pairing, device: device, channelKey: mac.channel, remoteChannelKey: phone.channel.publicKey)
			Check.refuses("a handshake message that carries a payload") { try macKK.readMessage(carrying) }

			// KK from a key that is not paired, and for another device.
			let stranger = Curve25519.KeyAgreement.PrivateKey()
			var strangerSide = try ChannelHandshake.connection(
				initiator: true, pairing: pairing, device: device, channelKey: stranger, remoteChannelKey: mac.channel.publicKey)
			let strangerFirst = try strangerSide.writeMessage()
			Check.refuses("a connection from a channel key that is not paired") {
				_ = try ChannelHandshake.respond(
					toFirstMessage: strangerFirst, pairing: pairing, channelKey: mac.channel, devices: [(device, phone.channel.publicKey)])
			}
			var otherDevice = try ChannelHandshake.connection(
				initiator: true, pairing: pairing, device: DeviceID.random(), channelKey: phone.channel, remoteChannelKey: mac.channel.publicKey)
			let otherDeviceFirst = try otherDevice.writeMessage()
			Check.refuses("a connection made for another device's prologue") {
				_ = try ChannelHandshake.respond(
					toFirstMessage: otherDeviceFirst, pairing: pairing, channelKey: mac.channel, devices: [(device, phone.channel.publicKey)])
			}
			// An ephemeral key of small order (all zeros) is refused.
			var zeroes = Data(repeating: 0, count: 48)
			var macZero = try ChannelHandshake.connection(
				initiator: false, pairing: pairing, device: device, channelKey: mac.channel, remoteChannelKey: phone.channel.publicKey)
			Check.refuses("an ephemeral key of small order") { try macZero.readMessage(zeroes) }
			zeroes[0] = 1
			var macOne = try ChannelHandshake.connection(
				initiator: false, pairing: pairing, device: device, channelKey: mac.channel, remoteChannelKey: phone.channel.publicKey)
			Check.refuses("an ephemeral key of small order (one)") { try macOne.readMessage(zeroes) }
			// Every single byte of a good first message changed is refused.
			var good = try ChannelHandshake.connection(
				initiator: true, pairing: pairing, device: device, channelKey: phone.channel, remoteChannelKey: mac.channel.publicKey)
			let goodFirst = try good.writeMessage()
			var allRefused = true
			for index in 0..<goodFirst.count {
				var changed = goodFirst
				changed[changed.startIndex + index] ^= 0x01
				var side = try ChannelHandshake.connection(
					initiator: false, pairing: pairing, device: device, channelKey: mac.channel, remoteChannelKey: phone.channel.publicKey)
				if (try? side.readMessage(changed)) != nil { allRefused = false }
			}
			Check.that(allRefused, "a first KK message with any one byte changed is refused")
			Check.refuses("a handshake read out of turn") {
				var side = try ChannelHandshake.connection(
					initiator: true, pairing: pairing, device: device, channelKey: phone.channel, remoteChannelKey: mac.channel.publicKey)
				try side.readMessage(goodFirst)
			}
			Check.refuses("a second message written out of turn") { var side = good; _ = try side.writeMessage() }

			// A pairing claim that names a channel key other than the handshake's, or is signed by another key.
			let binding = Bytes.random(32)
			let claim = try PairClaim.make(device: phone.description, attestation: nil, keyId: nil, pairing: pairing, binding: binding, deviceKey: phone.device)
			Check.refuses("a claim naming a channel key the handshake was not made with") {
				try claim.verify(pairing: pairing, binding: binding, handshakeChannelKey: stranger.publicKey.rawRepresentation)
			}
			Check.refuses("a claim for another channel") {
				try claim.verify(pairing: pairing, binding: Bytes.random(32), handshakeChannelKey: phone.channel.publicKey.rawRepresentation)
			}
			Check.refuses("a claim signed by a key that is not the device key") {
				_ = try PairClaim.make(device: phone.description, attestation: nil, keyId: nil, pairing: pairing, binding: binding, deviceKey: phone.presence)
			}
			let proof = try MacProof.make(challenge: Bytes.random(32), pairing: pairing, binding: binding, identity: P256.Signing.PrivateKey())
			Check.refuses("a Mac's proof not signed by the identity key in the payload") {
				try proof.verify(identityKey: mac.identity.publicKey, pairing: pairing, binding: binding)
			}
		} catch {
			Check.that(false, "refusals: \(error)")
		}
	}

	static func sealing(mac: Mac, phone: Phone, pairing: PairingID, device: DeviceID) {
		do {
			// The phone leaves an answer for the Mac.
			let id = ItemID.random()
			let address = ItemAddress(pairing: pairing, reader: .mac, id: id)
			let request = try RequestItem.make(
				method: "needs.answer", params: .object([("need", .string("n_1")), ("answer", .object([("choice", .string("yes"))]))]), pairing: pairing,
				device: device, id: id, deviceKey: phone.device, presenceKey: phone.presence)
			let item = try SealedItem.seal(request.plaintext, to: address, readerKey: mac.record.publicKey, writerKey: phone.record)
			Check.that(item.count <= SealedItem.maxLength, "a sealed request fits the mailbox")
			let opened = try RequestItem.read(try SealedItem.open(item, at: address, readerKey: mac.record, writerKey: phone.record.publicKey))
			Check.runs("the Mac opens the phone's item and finds it signed by the device key, with presence") {
				try opened.verify(deviceKey: phone.device.publicKey, presenceKey: phone.presence.publicKey, writer: device, address: address)
			}
			Check.that(opened.method == "needs.answer" && opened.nonce == id, "the request reads back")
			Check.refuses("an item moved to another id") {
				_ = try SealedItem.open(item, at: ItemAddress(pairing: pairing, reader: .mac, id: ItemID.random()), readerKey: mac.record, writerKey: phone.record.publicKey)
			}
			Check.refuses("an item moved to another reader") {
				_ = try SealedItem.open(item, at: ItemAddress(pairing: pairing, reader: .device(device), id: id), readerKey: mac.record, writerKey: phone.record.publicKey)
			}
			Check.refuses("an item said to be from another writer") {
				_ = try SealedItem.open(item, at: address, readerKey: mac.record, writerKey: P256.KeyAgreement.PrivateKey().publicKey)
			}
			Check.refuses("an item opened with another reader's key") {
				_ = try SealedItem.open(item, at: address, readerKey: phone.record, writerKey: phone.record.publicKey)
			}
			var changed = item
			changed[changed.startIndex + 70] ^= 0x01
			Check.refuses("an item with one bit changed") { _ = try SealedItem.open(changed, at: address, readerKey: mac.record, writerKey: phone.record.publicKey) }
			Check.refuses("an item from another device than the relay says") {
				try opened.verify(deviceKey: phone.device.publicKey, presenceKey: nil, writer: DeviceID.random(), address: address)
			}
			// Someone with the Mac's record key can seal as the phone, but cannot sign as it.
			let forger = P256.Signing.PrivateKey()
			let forged = try RequestItem.make(
				method: "github.merge", params: .object([]), pairing: pairing, device: device, id: id, deviceKey: forger, presenceKey: nil)
			let forgedItem = try SealedItem.seal(forged.plaintext, to: address, readerKey: mac.record.publicKey, writerKey: phone.record)
			let forgedOpened = try RequestItem.read(try SealedItem.open(forgedItem, at: address, readerKey: mac.record, writerKey: phone.record.publicKey))
			Check.refuses("a request sealed with the right keys but not signed by the device key") {
				try forgedOpened.verify(deviceKey: phone.device.publicKey, presenceKey: nil, writer: device, address: address)
			}
			Check.refuses("a request whose presence signature is required and missing") {
				try forgedOpened.verify(deviceKey: forger.publicKey, presenceKey: phone.presence.publicKey, writer: device, address: address)
			}
			// What request says must be what signed says.
			let text = String(decoding: request.plaintext, as: UTF8.self).replacingOccurrences(of: #""request":{"method":"needs.answer""#, with: #""request":{"method":"github.merge""#)
			Check.refuses("a request item whose request is not what was signed") { _ = try RequestItem.read(Data(text.utf8)) }

			// The Mac's states, with numbers that only rise.
			var numbers = StateNumbers()
			for number: Int64 in [1, 2] {
				let stateID = ItemID.random()
				let stateAddress = ItemAddress(pairing: pairing, reader: .device(device), id: stateID)
				let state = try MacItem.make(
					kind: "state", number: number, body: .object([("needs", .integer(number))]), pairing: pairing, device: device, id: stateID, identity: mac.identity)
				let sealed = try SealedItem.seal(state.plaintext, to: stateAddress, readerKey: phone.record.publicKey, writerKey: mac.record)
				let read = try MacItem.read(try SealedItem.open(sealed, at: stateAddress, readerKey: phone.record, writerKey: mac.record.publicKey))
				try read.verify(identityKey: mac.identity.publicKey, address: stateAddress)
				Check.that(numbers.take(read.number!) == .newer, "state \(number) is newer")
			}
			Check.that(numbers.take(2) == .same && numbers.take(1) == .older && numbers.shown == 2, "an old state handed back is refused")
			let stateID = ItemID.random()
			let stateAddress = ItemAddress(pairing: pairing, reader: .device(device), id: stateID)
			let notMac = try MacItem.make(kind: "receipt", body: .string("done"), pairing: pairing, device: device, id: stateID, identity: P256.Signing.PrivateKey())
			Check.refuses("a Mac item not signed by the Mac's identity key") { try notMac.verify(identityKey: mac.identity.publicKey, address: stateAddress) }
			Check.refuses("a state without its number") {
				_ = try MacItem.make(kind: "state", body: .null, pairing: pairing, device: device, id: stateID, identity: mac.identity)
			}
			Check.refuses("a Mac item of a kind the identity key signs elsewhere") {
				_ = try MacItem.make(kind: "attach", body: .null, pairing: pairing, device: device, id: stateID, identity: mac.identity)
			}
			Check.refuses("an item longer than the mailbox takes") {
				let big = try RequestItem.make(
					method: "submit", params: .object([("text", .string(String(repeating: "a", count: 15_000)))]), pairing: pairing, device: device,
					id: id, deviceKey: phone.device, presenceKey: nil)
				_ = try SealedItem.seal(big.plaintext, to: address, readerKey: mac.record.publicKey, writerKey: phone.record)
			}
			print("ok   sealed items both ways, each signed by its writer, and states that only rise")
		} catch {
			Check.that(false, "sealing: \(error)")
		}
	}

	/// A record key in the Secure Enclave can seal and open (3.2: "which P6 finds out"): checked when this compiles,
	/// since `SealedItem` takes any key CryptoKit's HPKE takes, and the Secure Enclave's is one. No key is made.
	static func secureEnclaveRecordKeyCompiles() {
		func takes<Key: HPKEDiffieHellmanPrivateKey>(_: Key.Type) -> Bool where Key.PublicKey == P256.KeyAgreement.PublicKey { true }
		Check.that(takes(SecureEnclave.P256.KeyAgreement.PrivateKey.self), "CryptoKit's HPKE takes a Secure Enclave record key")
	}

	/// No error RemoteKit threw in these checks holds a secret, in hex, base64 or base64url.
	static func errorsHoldNoSecret() {
		Check.section("Errors hold no secret")
		let forms = secrets.flatMap { [$0.hex, $0.base64EncodedString(), Base64URL.encode($0)] }
		let leaking = Check.errors.filter { error in forms.contains { error.contains($0) } }
		Check.that(!Check.errors.isEmpty && leaking.isEmpty, "none of \(Check.errors.count) refusals' errors holds a key or the secret")
	}
}
