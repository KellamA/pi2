
import CryptoKit
import Foundation
import RemoteKit

/// The relay's messages as the client writes and reads them, the proof's text, the join's client data hash, the backoff
/// and the memory of items taken: everything of the client that is not a connection.
enum Formats {
	static let pairing = PairingID("AAECAwQFBgcICQoLDA0ODw")!
	static let device = DeviceID("dev_EBESExQVFhcYGRobHB0eHw")!
	static let item = ItemID("ICEiIyQlJicoKSorLC0uLw")!
	/// The key whose private scalar is 32 bytes of 0x07, the one `relay/test/join-hash.test.ts` names by its public half.
	static let key = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
	static let keyText = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEHhhTL9R1TALzBB2cdc6zO4P_2BrHzk_ogsyxyYvFiW6kbDEcTi_0DdlqNlPm5FRF0y3-SG7O11x6kMahiIHAow"
	static let keyID = AttestKeyID(bytes: Data(repeating: 0xAB, count: 32))!
	/// A sealed item as the relay takes one: HPKE's encapsulated key, an uncompressed point, first.
	static let sealed = Data([4]) + Data(repeating: 0x5A, count: 120)
	/// A device that left, as the relay passes it on (#813): its time and a notice of 64 bytes, as written and as read.
	static let left = RelayLeft(device: device, at: 1_800_000_000_000, notice: Data(repeating: 3, count: 64))
	static let leftText = #"{"device":"dev_EBESExQVFhcYGRobHB0eHw","at":1800000000000,"notice":"\#(Base64URL.encode(left.notice))"}"#

	static func run() {
		Check.section("Formats")
		outgoing()
		incoming()
		refusals()
		proofAndHash()
		leaveNotice()
		backoff()
		memory()
	}

	static func outgoing() {
		let build = RelayBuild("12.3")!
		Check.equal(PublicKeys.text(key.publicKey), keyText, "the shared key's public half")
		Check.equal(RelayOutgoing.register(build: build, relayKey: key.publicKey).text, #"{"register":{"v":1,"build":"12.3","relayKey":"\#(keyText)"}}"#, "register")
		Check.equal(
			RelayOutgoing.hello(pairing: pairing, device: nil, role: .mac, build: build).text,
			#"{"hello":{"v":1,"role":"mac","pairing":"AAECAwQFBgcICQoLDA0ODw","build":"12.3"}}"#, "a Mac's hello")
		Check.equal(
			RelayOutgoing.hello(pairing: pairing, device: device, role: .device, build: build).text,
			#"{"hello":{"v":1,"role":"device","pairing":"AAECAwQFBgcICQoLDA0ODw","device":"dev_EBESExQVFhcYGRobHB0eHw","build":"12.3"}}"#,
			"a phone's hello")
		Check.equal(
			RelayOutgoing.hello(pairing: pairing, device: nil, role: .device, build: build).text,
			#"{"hello":{"v":1,"role":"device","pairing":"AAECAwQFBgcICQoLDA0ODw","build":"12.3"}}"#, "a joining phone's hello")
		let signature = Data(repeating: 1, count: 64)
		let signatureText = Base64URL.encode(signature)
		Check.equal(RelayOutgoing.proof(signature: signature).text, #"{"proof":{"signature":"\#(signatureText)"}}"#, "proof")
		Check.equal(
			RelayOutgoing.leave(signature: signature, at: 1_800_000_000_000, notice: left.notice).text,
			#"{"leave":{"signature":"\#(signatureText)","at":1800000000000,"notice":"\#(Base64URL.encode(left.notice))"}}"#, "leave, with the time and the notice for the Mac")
		let token = Data(repeating: 2, count: 32)
		Check.equal(
			RelayOutgoing.join(pairing: pairing, deviceKey: key.publicKey, attestation: Data([1, 2, 3]), keyId: keyID, token: token).text,
			#"{"join":{"pairing":"AAECAwQFBgcICQoLDA0ODw","deviceKey":"\#(keyText)","attestation":"AQID","keyId":"\#(keyID.text)","token":"\#(Base64URL.encode(token))"}}"#,
			"join")
		Check.equal(
			RelayOutgoing.openJoin(tokenHash: token, expires: 1_800_000_300_000).text,
			#"{"openJoin":{"tokenHash":"\#(Base64URL.encode(token))","expires":1800000300000}}"#, "openJoin")
		Check.equal(RelayOutgoing.closeJoin.text, #"{"closeJoin":{}}"#, "closeJoin")
		Check.equal(RelayOutgoing.deletePairing.text, #"{"deletePairing":{}}"#, "deletePairing")
		Check.equal(RelayOutgoing.take.text, #"{"take":{}}"#, "take")
		Check.equal(
			RelayOutgoing.took(ids: [item, ItemID("AAECAwQFBgcICQoLDA0ODw")!]).text, #"{"took":{"ids":["ICEiIyQlJicoKSorLC0uLw","AAECAwQFBgcICQoLDA0ODw"]}}"#, "took")
		Check.that((try? RelayOutgoing.took(ids: (0..<RelayLimits.maxTook).map { _ in ItemID.random() }).validate()) != nil, "a took of 200 ids, the most a take brings")
		Check.refuses("a took of no ids") { try RelayOutgoing.took(ids: []).validate() }
		Check.refuses("a took of 201 ids") { try RelayOutgoing.took(ids: (0...RelayLimits.maxTook).map { _ in ItemID.random() }).validate() }
		Check.refuses("a took naming an id twice") { try RelayOutgoing.took(ids: [item, item]).validate() }
		Check.equal(RelayOutgoing.ping.text, #"{"ping":{}}"#, "ping, as the relay answers without waking its object")
		Check.equal(
			RelayOutgoing.addDevice(device, deviceKey: key.publicKey, attestKeyId: keyID).text,
			#"{"addDevice":{"device":"dev_EBESExQVFhcYGRobHB0eHw","deviceKey":"\#(keyText)","attestKeyId":"\#(keyID.text)"}}"#, "addDevice")
		Check.equal(RelayOutgoing.removeDevice(device).text, #"{"removeDevice":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, "removeDevice")
		let sealedText = Base64URL.encode(sealed)
		Check.equal(
			RelayOutgoing.state(device: device, id: item, item: sealed).text,
			#"{"state":{"device":"dev_EBESExQVFhcYGRobHB0eHw","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)"}}"#, "state")
		Check.equal(
			RelayOutgoing.put(to: .mac, id: item, item: sealed, presence: false).text,
			#"{"put":{"to":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)"}}"#, "put, with no flag")
		Check.equal(
			RelayOutgoing.put(to: .device(device), id: item, item: sealed, presence: true).text,
			#"{"put":{"to":"dev_EBESExQVFhcYGRobHB0eHw","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)","presence":true}}"#,
			"put, marked presence")
		let apns = String(repeating: "0a", count: 32)
		Check.equal(RelayOutgoing.token(apns: apns, environment: .production).text, #"{"token":{"apns":"\#(apns)","environment":"production"}}"#, "token")

		Check.that(RelayBuild("1") != nil && RelayBuild("0.12.300") != nil, "builds the relay takes")
		for text in ["", "1.", ".1", "01", "1.2.3.4", "1234567890", "1a", "+1", " 1"] {
			Check.that(RelayBuild(text) == nil, "a build the relay refuses: \(text.debugDescription)")
		}
		Check.that(AttestKeyID(keyID.text) == keyID, "an App Attest key id, read back")
		for text in [String(keyID.text.dropLast()), keyID.text.replacingOccurrences(of: "=", with: ""), Base64URL.encode(Data(repeating: 0xAB, count: 32)), "q" + keyID.text] {
			Check.that(AttestKeyID(text) == nil, "an App Attest key id the relay refuses: \(text)")
		}
	}

	static func incoming() {
		let challenge = Data((0..<32).map { UInt8($0) })
		Check.equal(try? RelayIncoming.parse(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#, for: .mac), .challenge(challenge), "a challenge")
		Check.equal(try? RelayIncoming.parse(#"{"registered":{"pairing":"AAECAwQFBgcICQoLDA0ODw"}}"#, for: .registering), .registered(pairing), "registered")
		Check.equal(
			try? RelayIncoming.parse(#"{"ready":{"devices":[{"device":"dev_EBESExQVFhcYGRobHB0eHw","online":true}],"left":[],"pending":false,"mail":3}}"#, for: .mac),
			.macReady(RelayMacReady(devices: [RelayDevicePresence(device: device, online: true)], left: [], pending: false, mail: 3)), "a Mac's ready")
		Check.equal(
			try? RelayIncoming.parse(#"{"ready":{"devices":[],"left":[\#(leftText)],"pending":false,"mail":0}}"#, for: .mac),
			.macReady(RelayMacReady(devices: [], left: [left], pending: false, mail: 0)), "a Mac's ready, with a device that left while it was away")
		Check.equal(try? RelayIncoming.parse(#"{"ready":{"mac":false,"mail":0}}"#, for: .device), .deviceReady(macOnline: false, mail: 0), "a phone's ready")
		Check.equal(try? RelayIncoming.parse(#"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, for: .joining), .joined(device), "joined, to the phone")
		Check.equal(
			try? RelayIncoming.parse(#"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw","deviceKey":"\#(keyText)","keyId":"\#(keyID.text)"}}"#, for: .mac),
			.phoneJoined(RelayJoinNotice(slot: device, deviceKey: key.publicKey, keyId: keyID)), "joined, to the Mac")
		Check.equal(try? RelayIncoming.parse(#"{"ok":{"what":"openJoin"}}"#, for: .mac), .ok(.openJoin), "ok")
		Check.equal(try? RelayIncoming.parse(#"{"ok":{"what":"took"}}"#, for: .mac), .ok(.took), "ok for a took, to the Mac")
		Check.equal(try? RelayIncoming.parse(#"{"ok":{"what":"took"}}"#, for: .device), .ok(.took), "ok for a took, to a phone")
		Check.equal(try? RelayIncoming.parse(#"{"refused":{"what":"put","why":"mailbox-full"}}"#, for: .device), .requestRefused(.put, .mailboxFull), "a request refused")
		Check.equal(try? RelayIncoming.parse(#"{"refused":{"why":"not-listed"}}"#, for: .device), .refused(.notListed), "a refusal")
		Check.equal((try? RelayIncoming.parse(#"{"refused":{"why":"some-new-word"}}"#, for: .mac)).map { "\($0)" }, "refused(some-new-word)", "a refusal with a word this client does not know")
		Check.equal(try? RelayIncoming.parse(#"{"busy":{"until":1800000001000}}"#, for: .mac), .busy(until: 1_800_000_001_000), "busy")
		Check.equal(try? RelayIncoming.parse(#"{"pong":{}}"#, for: .device), .pong, "pong")
		let sealedText = Base64URL.encode(sealed)
		Check.equal(
			try? RelayIncoming.parse(#"{"item":{"from":"dev_EBESExQVFhcYGRobHB0eHw","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)","presence":true}}"#, for: .mac),
			.item(RelayMailItem(from: .device(device), id: item, item: sealed, presence: true)), "an item, to the Mac")
		Check.equal(
			try? RelayIncoming.parse(#"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)","presence":false}}"#, for: .device),
			.item(RelayMailItem(from: .mac, id: item, item: sealed, presence: false)), "an item, to a phone")
		Check.equal(
			try? RelayIncoming.parse(#"{"state":{"id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)"}}"#, for: .device),
			.state(RelayStateItem(id: item, item: sealed)), "a state, to a phone")
		Check.equal(try? RelayIncoming.parse(#"{"taken":{"count":2}}"#, for: .mac), .taken(count: 2), "taken")
		Check.equal(try? RelayIncoming.parse(#"{"mail":{}}"#, for: .device), .mail, "mail")
		Check.equal(try? RelayIncoming.parse(#"{"online":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, for: .mac), .online(device), "online")
		Check.equal(try? RelayIncoming.parse(#"{"offline":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, for: .mac), .offline(device), "offline")
		Check.equal(try? RelayIncoming.parse(#"{"left":\#(leftText)}"#, for: .mac), .left(left), "left, with the phone's time and notice")
		Check.equal(try? RelayIncoming.parse(#"{"anotherMac":{}}"#, for: .mac), .anotherMac, "anotherMac")
		Check.equal(
			try? RelayIncoming.parse(#"{"held":{"device":"dev_EBESExQVFhcYGRobHB0eHw","until":1800000001000}}"#, for: .mac),
			.held(device, until: 1_800_000_001_000), "held")
		Check.equal(try? RelayIncoming.parse(#"{"mac":{"online":true}}"#, for: .device), .macOnline(true), "mac, to a phone")
		Check.equal(try? RelayIncoming.parse(#"{"mac":{"online":false}}"#, for: .joining), .macOnline(false), "mac, to a joining phone")
	}

	/// Everything the reader must refuse: what the relay never writes, what it never writes to that end, and what holds
	/// what it is not.
	static func refusals() {
		let sealedText = Base64URL.encode(sealed)
		let challenge = Base64URL.encode(Data(repeating: 9, count: 32))
		let cases: [(String, RelayEnd, String)] = [
			("white space", .mac, #"{"ok": {"what":"openJoin"}}"#),
			("a line break after", .mac, "{\"ok\":{\"what\":\"openJoin\"}}\n"),
			("bytes after the value", .mac, #"{"ok":{"what":"openJoin"}}{}"#),
			("two messages in one", .mac, #"{"ok":{"what":"openJoin"},"mail":{}}"#),
			("no message", .mac, "{}"),
			("not an object", .mac, #"["ok"]"#),
			("a key twice", .mac, #"{"ok":{"what":"openJoin","what":"openJoin"}}"#),
			("an unknown field", .mac, #"{"ok":{"what":"openJoin","extra":1}}"#),
			("a missing field", .mac, #"{"ready":{"devices":[],"left":[],"pending":false}}"#),
			("an escape JSON.stringify does not write", .mac, #"{"ok":{"what":"open\u004aoin"}}"#),
			("an escaped slash", .mac, #"{"refused":{"why":"a\/b"}}"#),
			("a number written otherwise", .mac, #"{"taken":{"count":2.0}}"#),
			("a number with an exponent", .mac, #"{"taken":{"count":2e0}}"#),
			("a negative count", .mac, #"{"taken":{"count":-1}}"#),
			("a count past what the Mac's mailbox holds", .mac, #"{"taken":{"count":201}}"#),
			("a count past what a phone's mailbox and state hold", .device, #"{"taken":{"count":102}}"#),
			("a time that is not one", .mac, #"{"busy":{"until":0}}"#),
			("a time as text", .mac, #"{"busy":{"until":"1800000001000"}}"#),
			("a challenge of 31 bytes", .mac, #"{"challenge":"\#(Base64URL.encode(Data(repeating: 9, count: 31)))"}"#),
			("a challenge of 33 bytes", .device, #"{"challenge":"\#(Base64URL.encode(Data(repeating: 9, count: 33)))"}"#),
			("a challenge in an object", .mac, #"{"challenge":{"challenge":"\#(challenge)"}}"#),
			("a challenge with padding", .mac, #"{"challenge":"\#(challenge)="}"#),
			("a phone's notice to the Mac", .mac, #"{"mac":{"online":true}}"#),
			("the Mac's notice to a phone", .device, #"{"online":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#),
			("the Mac's ready to a phone", .device, #"{"ready":{"devices":[],"left":[],"pending":false,"mail":0}}"#),
			("a phone's ready to the Mac", .mac, #"{"ready":{"mac":true,"mail":0}}"#),
			("registered to a Mac already registered", .mac, #"{"registered":{"pairing":"AAECAwQFBgcICQoLDA0ODw"}}"#),
			("a phone's joined to the Mac", .mac, #"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#),
			("a state to the Mac", .mac, #"{"state":{"id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)"}}"#),
			("an item to a joining phone", .joining, #"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)","presence":false}}"#),
			("an ok to a joining phone", .joining, #"{"ok":{"what":"put"}}"#),
			("an ok for the Mac's request to a phone", .device, #"{"ok":{"what":"openJoin"}}"#),
			("an ok for a phone's request to the Mac", .mac, #"{"ok":{"what":"token"}}"#),
			("an ok for what is not a request", .mac, #"{"ok":{"what":"hello"}}"#),
			("an item from the Mac to the Mac", .mac, #"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)","presence":false}}"#),
			("an item from a device to a phone", .device, #"{"item":{"from":"dev_EBESExQVFhcYGRobHB0eHw","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)","presence":false}}"#),
			("an item that is not sealed", .device, #"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(Base64URL.encode(Data([5]) + sealed.dropFirst()))","presence":false}}"#),
			("an item too short", .device, #"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(Base64URL.encode(sealed.prefix(80)))","presence":false}}"#),
			("an item too long", .device, #"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(Base64URL.encode(Data([4]) + Data(repeating: 1, count: 16 * 1024)))","presence":false}}"#),
			("an item without its flag", .device, #"{"item":{"from":"mac","id":"ICEiIyQlJicoKSorLC0uLw","item":"\#(sealedText)"}}"#),
			("an item's id that is not one", .device, #"{"item":{"from":"mac","id":"ICEi","item":"\#(sealedText)","presence":false}}"#),
			("a device's id that is not one", .mac, #"{"online":{"device":"dev_EBESExQVFhcYGRobHB0eH"}}"#),
			("a key that is not one", .mac, #"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw","deviceKey":"\#(String(keyText.dropLast(2)))","keyId":"\#(keyID.text)"}}"#),
			("a key id in base64url", .mac, #"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw","deviceKey":"\#(keyText)","keyId":"\#(Base64URL.encode(Data(repeating: 0xAB, count: 32)))"}}"#),
			("a refusal that is not a word", .mac, #"{"refused":{"why":"Not Listed"}}"#),
			("a refusal with what the client sent", .mac, #"{"refused":{"why":"malformed","said":"x"}}"#),
			("a flag that is not true or false", .mac, #"{"ready":{"devices":[],"left":[],"pending":1,"mail":0}}"#),
			// A device that left comes with its phone's time and notice, or not at all (#813).
			("a left without the phone's notice", .mac, #"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#),
			("a left without its time", .mac, #"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw","notice":"\#(Base64URL.encode(left.notice))"}}"#),
			("a left whose notice is 63 bytes", .mac, #"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw","at":1800000000000,"notice":"\#(Base64URL.encode(left.notice.prefix(63)))"}}"#),
			("a left whose time is not one", .mac, #"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw","at":0,"notice":"\#(Base64URL.encode(left.notice))"}}"#),
			("a left whose time is text", .mac, #"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw","at":"1800000000000","notice":"\#(Base64URL.encode(left.notice))"}}"#),
			("a left with more", .mac, #"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw","at":1800000000000,"notice":"\#(Base64URL.encode(left.notice))","why":"x"}}"#),
			("a left to a phone", .device, #"{"left":\#(leftText)}"#),
			("a ready listing a device that left without its notice", .mac, #"{"ready":{"devices":[],"left":["dev_EBESExQVFhcYGRobHB0eHw"],"pending":false,"mail":0}}"#),
			("a lone surrogate", .mac, #"{"refused":{"why":"\ud800"}}"#),
			("an unknown message", .mac, #"{"push":{}}"#),
			("too long", .mac, #"{"refused":{"why":"\#(String(repeating: "a", count: 48 * 1024))"}}"#),
		]
		for (name, end, text) in cases {
			Check.refuses("relay message: \(name)") { _ = try RelayIncoming.parse(text, for: end) }
		}
		Check.refuses("relay message: not UTF-8") {
			_ = try RelayIncoming.parse(String(decoding: [0x7B, 0xFF, 0x7D], as: UTF8.self), for: .mac)
		}

		// What the client refuses to send, before the relay would.
		let refusedSends: [(String, RelayOutgoing)] = [
			("a proof that is not 64 bytes", .proof(signature: Data(count: 63))),
			("a leave whose signature is not 64 bytes", .leave(signature: Data(count: 63), at: 1, notice: Data(count: 64))),
			("a leave whose notice is not 64 bytes", .leave(signature: Data(count: 64), at: 1, notice: Data(count: 65))),
			("a leave with no time", .leave(signature: Data(count: 64), at: 0, notice: Data(count: 64))),
			("a leave past the year 2286", .leave(signature: Data(count: 64), at: 10_000_000_000_000, notice: Data(count: 64))),
			("a token hash that is not 32 bytes", .openJoin(tokenHash: Data(count: 31), expires: 1)),
			("a window with no time", .openJoin(tokenHash: Data(count: 32), expires: 0)),
			("an item that is not sealed", .put(to: .mac, id: item, item: Data([5]) + sealed.dropFirst(), presence: false)),
			("an item too long", .put(to: .mac, id: item, item: Data([4]) + Data(count: 16 * 1024), presence: false)),
			("a push token not in hex", .token(apns: String(repeating: "0A", count: 32), environment: .development)),
			("a push token too short", .token(apns: "0a0a", environment: .development)),
			("a join without an attestation", .join(pairing: pairing, deviceKey: key.publicKey, attestation: Data(), keyId: keyID, token: Data(count: 32))),
			("a join with a short token", .join(pairing: pairing, deviceKey: key.publicKey, attestation: Data([1]), keyId: keyID, token: Data(count: 31))),
		]
		for (name, message) in refusedSends {
			Check.refuses("relay outgoing: \(name)") { try message.validate() }
		}
	}

	static func proofAndHash() {
		let challenge = Data((0..<32).map { UInt8($0) })
		let expected = "pi2-relay-v1\u{0}device\u{0}AAECAwQFBgcICQoLDA0ODw\u{0}dev_EBESExQVFhcYGRobHB0eHw\u{0}\(Base64URL.encode(challenge))"
		Check.equal(try? RelayProof.text(.device, pairing: pairing, device: device, challenge: challenge), Data(expected.utf8), "a phone's proof text")
		Check.equal(
			try? RelayProof.text(.register, pairing: nil, device: nil, challenge: challenge), Data("pi2-relay-v1\u{0}register\u{0}\u{0}\u{0}\(Base64URL.encode(challenge))".utf8),
			"register's proof text, with the pairing and the device empty")
		Check.refuses("a proof over a challenge of 31 bytes") { _ = try RelayProof.text(.mac, pairing: pairing, device: nil, challenge: challenge.prefix(31)) }
		Check.refuses("a proof over a challenge of 33 bytes") { _ = try RelayProof.text(.mac, pairing: pairing, device: nil, challenge: challenge + Data([1])) }

		// The one value relay/test/join-hash.test.ts holds the relay's TypeScript to.
		Check.equal(
			try? PairingSecrets.joinClientDataHash(challenge: challenge, deviceKey: key.publicKey).hex,
			"c3e46a7e9b3066c24a4353e2f51e841768431939a3bd82533722f63a2af57c1e", "the join's client data hash, as the relay's")
		Check.equal(key.publicKey.derRepresentation.count, 91, "a device key's SPKI DER is 91 bytes")
		Check.refuses("the join's client data hash over a challenge of 31 bytes") { _ = try PairingSecrets.joinClientDataHash(challenge: challenge.prefix(31), deviceKey: key.publicKey) }
		Check.that(AttestKeyID(bytes: Data(count: 31)) == nil && AttestKeyID(bytes: Data(count: 33)) == nil, "an App Attest key id from bytes that are not 32 is refused, not a trap")
	}

	/// The leave text for the Mac, and what the Mac takes as a device having left (#813): only the notice its device key
	/// signed for this pairing, this device and this Mac, within the window; nothing else the device key signs.
	static func leaveNotice() {
		let identity = key.publicKey
		let at: Int64 = 1_800_000_000_000
		let expected = #"{"v":2,"kind":"leave","pairing":"AAECAwQFBgcICQoLDA0ODw","device":"dev_EBESExQVFhcYGRobHB0eHw","mac":"\#(keyText)","at":1800000000000}"#
		Check.equal(try? RelayLeaveNotice.text(pairing: pairing, device: device, identityKey: identity, at: at), Data(expected.utf8), "the leave text for the Mac")
		Check.refuses("a leave text at no time") { _ = try RelayLeaveNotice.text(pairing: pairing, device: device, identityKey: identity, at: 0) }
		Check.refuses("a leave text past the year 2286") { _ = try RelayLeaveNotice.text(pairing: pairing, device: device, identityKey: identity, at: 10_000_000_000_000) }

		let phone = P256.Signing.PrivateKey()
		func sign(_ text: Data) -> Data { (try? phone.sign(text)) ?? Data() }
		let notice = sign(Data(expected.utf8))
		let now = at + 1000
		func taken(
			_ left: RelayLeft, pairing: PairingID = pairing, identity: P256.Signing.PublicKey = identity, deviceKey: P256.Signing.PublicKey = phone.publicKey, now: Int64 = now
		) -> Bool {
			left.verified(pairing: pairing, identityKey: identity, deviceKey: deviceKey, now: now) != nil
		}
		let signed = RelayLeft(device: device, at: at, notice: notice)
		let verified = signed.verified(pairing: pairing, identityKey: identity, deviceKey: phone.publicKey, now: now)
		Check.that(verified?.device == device && verified?.at == at, "a notice the device key signed for this pairing, device and Mac is a leave")
		Check.that(taken(signed, now: at + RelayLeaveNotice.longestAge), "61 days on, still")
		Check.that(!taken(signed, now: at + RelayLeaveNotice.longestAge + 1), "not a moment later")
		Check.that(taken(signed, now: at - RelayLeaveNotice.aheadAtMost), "ten minutes ahead of the Mac's clock")
		Check.that(!taken(signed, now: at - RelayLeaveNotice.aheadAtMost - 1), "not more")
		Check.that(!taken(signed, pairing: PairingID.random()), "not for another pairing")
		Check.that(!taken(RelayLeft(device: DeviceID.random(), at: at, notice: notice)), "nor another device")
		Check.that(!taken(signed, identity: P256.Signing.PrivateKey().publicKey), "nor another Mac")
		Check.that(!taken(signed, deviceKey: P256.Signing.PrivateKey().publicKey), "nor another device key: a phone paired again has a new one")
		Check.that(!taken(RelayLeft(device: device, at: at + 1, notice: notice)), "nor another time")
		var flipped = notice
		flipped[flipped.startIndex + 10] ^= 1
		Check.that(!taken(RelayLeft(device: device, at: at, notice: flipped)), "nor a notice with a bit changed")
		Check.that(!taken(RelayLeft(device: device, at: at, notice: notice.prefix(63))), "nor one of 63 bytes")
		Check.that(!taken(RelayLeft(device: device, at: at, notice: Data(count: 64))), "nor one of zeros")
		Check.that(!taken(RelayLeft(device: device, at: .min, notice: notice), now: .max), "times that are none are refused, not a trap")
		Check.that(!taken(RelayLeft(device: device, at: .max, notice: notice), now: .min), "either way")

		// What else the device key signs is never a leave: the relay's texts, and the JSON of other kinds.
		let challenge = Data(repeating: 9, count: 32)
		for purpose in [RelayProof.Purpose.leave, .device] {
			let relaySigned = sign((try? RelayProof.text(purpose, pairing: pairing, device: device, challenge: challenge)) ?? Data())
			Check.that(!taken(RelayLeft(device: device, at: at, notice: relaySigned)), "the relay's \(purpose.rawValue) signature is not a notice for the Mac")
		}
		let date = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
		if let attach = try? AttachClaim.make(
			pairing: pairing, device: device, session: nil, received: nil, binding: challenge, challenge: challenge, build: "1", at: date, deviceKey: phone,
			presenceKey: P256.Signing.PrivateKey())
		{
			Check.that(!taken(RelayLeft(device: device, at: at, notice: attach.statement.signature)), "an attach at the same time is not a leave")
		} else {
			Check.that(false, "an attach to compare with")
		}
		if let request = try? RequestItem.make(
			method: "devices.forgetSelf", params: .object([]), pairing: pairing, device: device, id: item, at: date, deviceKey: phone, presenceKey: P256.Signing.PrivateKey())
		{
			Check.that(!taken(RelayLeft(device: device, at: at, notice: request.statement.signature)), "nor a request to forget itself")
		} else {
			Check.that(false, "a request to compare with")
		}
		// Nor can the identity key's items take the kind: no Mac item is ever of kind `leave`.
		Check.refuses("a Mac item of kind leave") { _ = try MacItem.make(kind: "leave", body: .object([]), pairing: pairing, device: device, id: item, identity: key) }
	}

	static func backoff() {
		let backoff = RelayBackoff()
		Check.equal(backoff.delay(attempt: 0, random: 0), 500, "the first wait, at its shortest")
		Check.equal(backoff.delay(attempt: 0, random: 0.999_999), 999, "the first wait, at its longest")
		Check.equal(backoff.delay(attempt: 3, random: 0), 4000, "the fourth wait doubles three times")
		Check.equal(backoff.delay(attempt: 6, random: 1), 60_000, "the wait stops at a minute")
		Check.equal(backoff.delay(attempt: 200, random: 0), 30_000, "and stays there")
	}

	static func memory() {
		var memory = RelayItemMemory()
		let one = RelayMailItem(from: .mac, id: item, item: sealed, presence: false)
		let same = RelayMailItem(from: .mac, id: item, item: sealed + Data([1]), presence: true)
		let fromDevice = RelayMailItem(from: .device(device), id: item, item: sealed, presence: false)
		let now: Int64 = 1_800_000_000_000
		Check.that(!memory.contains(one, at: now), "an item not remembered")
		Check.that(memory.remember(one, at: now), "an item remembered once its reader verified it")
		Check.that(memory.contains(same, at: now + 1000), "the same id from the same writer is a repeat")
		Check.that(!memory.contains(fromDevice, at: now + 1000), "the same id from another writer is not")
		Check.that(memory.contains(one, at: now + RelayItemMemory.keptFor - 1), "a repeat within 25 hours")
		Check.that(!memory.contains(one, at: now + RelayItemMemory.keptFor + 1), "not after 25 hours, when the relay holds no copy")
		let encoded = try? JSONEncoder().encode(memory)
		Check.equal(encoded.flatMap { try? JSONDecoder().decode(RelayItemMemory.self, from: $0) }, memory, "the memory, kept and read back")
		Check.that((try? JSONDecoder().decode(RelayItemMemory.self, from: Data(#"{"mac x":1}"#.utf8))) == nil, "a memory holding what is not an item's id is refused")

		// Full of ids younger than 25 hours, it takes no more, and forgets none of them to make room.
		var full = RelayItemMemory()
		func numbered(_ index: Int) -> RelayMailItem {
			RelayMailItem(from: .mac, id: ItemID(Base64URL.encode(Data(count: 12) + withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) }))!, item: sealed, presence: false)
		}
		let started = Date()
		for index in 0..<RelayItemMemory.most { _ = full.remember(numbered(index), at: now + Int64(index)) }
		Check.that(Date().timeIntervalSince(started) < 30, "filling the memory sorts nothing for each id")
		Check.that(!full.remember(numbered(RelayItemMemory.most), at: now + 3_600_000), "a full memory takes no more")
		Check.that(full.contains(numbered(0), at: now + 3_600_000), "and keeps its oldest, an hour old")
		Check.that(full.remember(numbered(RelayItemMemory.most), at: now + RelayItemMemory.keptFor + 1), "it takes more once its oldest are 25 hours old")
		Check.that(!full.contains(numbered(0), at: now + RelayItemMemory.keptFor + 1), "and those are gone")
	}
}
