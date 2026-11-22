
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
	static let keyID = AttestKeyID(bytes: Data(repeating: 0xAB, count: 32))
	/// A sealed item as the relay takes one: HPKE's encapsulated key, an uncompressed point, first.
	static let sealed = Data([4]) + Data(repeating: 0x5A, count: 120)

	static func run() {
		Check.section("Formats")
		outgoing()
		incoming()
		refusals()
		proofAndHash()
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
		Check.equal(RelayOutgoing.leave(signature: signature).text, #"{"leave":{"signature":"\#(signatureText)"}}"#, "leave")
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
		Check.equal(try? RelayIncoming.parse(#"{"ready":{"mac":false,"mail":0}}"#, for: .device), .deviceReady(macOnline: false, mail: 0), "a phone's ready")
		Check.equal(try? RelayIncoming.parse(#"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, for: .joining), .joined(device), "joined, to the phone")
		Check.equal(
			try? RelayIncoming.parse(#"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw","deviceKey":"\#(keyText)","keyId":"\#(keyID.text)"}}"#, for: .mac),
			.phoneJoined(RelayJoinNotice(slot: device, deviceKey: key.publicKey, keyId: keyID)), "joined, to the Mac")
		Check.equal(try? RelayIncoming.parse(#"{"ok":{"what":"openJoin"}}"#, for: .mac), .ok(.openJoin), "ok")
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
		Check.equal(try? RelayIncoming.parse(#"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, for: .mac), .left(device), "left")
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
			("a count past what a take can bring", .mac, #"{"taken":{"count":1001}}"#),
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
			PairingSecrets.joinClientDataHash(challenge: challenge, deviceKey: key.publicKey).hex,
			"c3e46a7e9b3066c24a4353e2f51e841768431939a3bd82533722f63a2af57c1e", "the join's client data hash, as the relay's")
		Check.equal(key.publicKey.derRepresentation.count, 91, "a device key's SPKI DER is 91 bytes")
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
		Check.that(memory.isNew(one, at: now), "an item taken the first time")
		Check.that(!memory.isNew(same, at: now + 1000), "the same id from the same writer, taken again, is a repeat")
		Check.that(memory.isNew(fromDevice, at: now + 1000), "the same id from another writer is not")
		Check.that(!memory.isNew(one, at: now + RelayItemMemory.keptFor - 1), "a repeat within 25 hours")
		Check.that(memory.isNew(one, at: now + RelayItemMemory.keptFor + 1), "taken again after 25 hours, when the relay holds no copy")
		let encoded = try? JSONEncoder().encode(memory)
		Check.equal(encoded.flatMap { try? JSONDecoder().decode(RelayItemMemory.self, from: $0) }, memory, "the memory, kept and read back")
		Check.that((try? JSONDecoder().decode(RelayItemMemory.self, from: Data(#"{"mac x":1}"#.utf8))) == nil, "a memory holding what is not an item's id is refused")
		var full = RelayItemMemory()
		for index in 0..<(RelayItemMemory.most + 10) {
			_ = full.isNew(RelayMailItem(from: .mac, id: ItemID(Base64URL.encode(Data(count: 12) + withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) }))!, item: sealed, presence: false), at: now + Int64(index))
		}
		Check.equal(full.count, RelayItemMemory.most, "the memory keeps at most its number of ids")
	}
}
