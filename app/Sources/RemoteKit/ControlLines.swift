import CryptoKit
import Foundation

// The lines a channel carries on top of the engine's own (iphone.md 5.6): its first lines (the Mac's proof, `pair` and
// `paired` or `pairRefused`, `attach` and `attached` or `refused`, resuming through `attach`), `presence` inside `attach`, `sessionEnd`,
// `revoked` and `homeKey`; and the offer of a new presence key, `presenceKey`, answered `presenceKeyAccepted` or `refused`.
// Each is one JSON object with one member, named for what it is. Every byte string is base64url; every P-256 public
// key is SPKI DER, a channel key its 32 raw bytes; every signature is ECDSA P-256 over the exact `signed` text
// (SignedStatement), and every `signed` is checked field by field, with no field missing and none unknown.

/// The longest first line taken: a `pair` with its App Attest attestation is the longest, a few kilobytes.
public let maxControlLineLength = Lines.firstLinesMaxLength

/// How far `at` in an attach may be from the reader's clock (3.4).
public let attachClockWindow: TimeInterval = 2 * 60

/// The Mac's first transport message on every channel (3.3 step 4, 3.4): a fresh 32-byte challenge, and the identity
/// key's signature over `{"v":2,"kind":"mac","pairing":…,"binding":<the handshake hash>}`, which the phone checks
/// against `i`. On a connection the challenge is the engine's, for the attach.
public struct MacProof: Sendable {
	public let challenge: Data
	public let statement: SignedStatement

	public static func make(challenge: Data, pairing: PairingID, binding: Data, identity: some StatementSigner) throws -> MacProof {
		guard challenge.count == 32 else { throw RemoteKitError("mac proof", "a challenge that is not 32 bytes") }
		let signed = JSONValue.object([
			("v", .integer(2)), ("kind", .string("mac")), ("pairing", .string(pairing.text)), ("binding", .string(Base64URL.encode(binding))),
		])
		return MacProof(challenge: challenge, statement: try SignedStatement.make(signed, signer: identity))
	}

	/// The phone's check: the Mac's identity key signed this channel's binding for this pairing.
	public func verify(identityKey: P256.Signing.PublicKey, pairing: PairingID, binding: Data) throws {
		let part = "mac proof"
		guard statement.isSigned(by: identityKey) else { throw RemoteKitError(part, "not signed by the Mac's identity key") }
		let fields = try Fields(statement.value, part: part, keys: ["v", "kind", "pairing", "binding"])
		try fields.version()
		guard try fields.string("kind").sameBytes("mac") else { throw RemoteKitError(part, "not a Mac's proof") }
		guard try fields.string("pairing").sameBytes(pairing.text) else { throw RemoteKitError(part, "for another pairing") }
		guard Bytes.constantTimeEqual(try fields.bytes("binding", count: 32), binding) else { throw RemoteKitError(part, "for another channel") }
	}

	var json: JSONValue {
		.object([
			("challenge", .string(Base64URL.encode(challenge))),
			("mac", .object([("signed", .string(statement.text)), ("signature", .string(statement.signatureText))])),
		])
	}

	static func read(_ value: JSONValue) throws -> MacProof {
		let part = "mac proof"
		let fields = try Fields(value, part: part, keys: ["challenge", "mac"])
		let inner = try Fields(fields.value("mac")!, part: part, keys: ["signed", "signature"])
		return MacProof(
			challenge: try fields.bytes("challenge", count: 32),
			statement: try SignedStatement.read(text: inner.value("signed"), signature: inner.value("signature"), part: part))
	}
}

/// What the phone says of itself in `pair` (3.3 step 4).
public struct DeviceDescription: Sendable {
	public var name: String
	public var model: String
	public var system: String
	public var build: String
	public var deviceKey: P256.Signing.PublicKey
	public var presenceKey: P256.Signing.PublicKey
	public var channelKey: Curve25519.KeyAgreement.PublicKey
	public var recordKey: P256.KeyAgreement.PublicKey

	public init(
		name: String, model: String, system: String, build: String, deviceKey: P256.Signing.PublicKey, presenceKey: P256.Signing.PublicKey,
		channelKey: Curve25519.KeyAgreement.PublicKey, recordKey: P256.KeyAgreement.PublicKey
	) {
		self.name = name
		self.model = model
		self.system = system
		self.build = build
		self.deviceKey = deviceKey
		self.presenceKey = presenceKey
		self.channelKey = channelKey
		self.recordKey = recordKey
	}

	var json: JSONValue {
		.object([
			("name", .string(name)), ("model", .string(model)), ("system", .string(system)), ("build", .string(build)),
			("deviceKey", .string(PublicKeys.text(deviceKey))), ("presenceKey", .string(PublicKeys.text(presenceKey))),
			("channelKey", .string(PublicKeys.text(channelKey))), ("recordKey", .string(PublicKeys.text(recordKey))),
		])
	}

	static func read(_ value: JSONValue) throws -> DeviceDescription {
		let part = "pair"
		let fields = try Fields(value, part: part, keys: ["name", "model", "system", "build", "deviceKey", "presenceKey", "channelKey", "recordKey"])
		func key<K>(_ name: String, _ read: (String) -> K?) throws -> K {
			guard let key = read(try fields.string(name)) else { throw RemoteKitError(part, "\(name) is not a key") }
			return key
		}
		let description = DeviceDescription(
			name: try fields.nonEmpty("name", maxLength: 128), model: try fields.nonEmpty("model", maxLength: 128),
			system: try fields.nonEmpty("system", maxLength: 128), build: try readBuild(fields, part: part),
			deviceKey: try key("deviceKey", PublicKeys.signingKey), presenceKey: try key("presenceKey", PublicKeys.signingKey),
			channelKey: try key("channelKey", PublicKeys.channelKey), recordKey: try key("recordKey", PublicKeys.agreementKey))
		guard !Bytes.constantTimeEqual(description.deviceKey.derRepresentation, description.presenceKey.derRepresentation) else {
			throw RemoteKitError(part, "the device key and the presence key are one key")
		}
		return description
	}
}

/// An app's build: 1 to 32 letters, digits, `.`, `-` and `+`.
func readBuild(_ fields: Fields, part: String) throws -> String {
	let build = try fields.string("build", maxLength: 32)
	guard !build.isEmpty, build.utf8.allSatisfy({ byte in
		switch byte {
		case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
			UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "+"):
			true
		default: false
		}
	}) else { throw RemoteKitError(part, "build is not a build") }
	return build
}

/// The phone's claim to pair (3.3 step 4): `{"pair":{"v":2,"device":{…},"attestation":…,"keyId":…,"signed":…,"signature":…}}`,
/// `signed` being `{"v":2,"kind":"pair","pairing":…,"binding":<the handshake hash>}` signed by the device key.
/// `attestation` and `keyId` are null only from a build without App Attest, which only a throwaway copy's engine takes (10).
public struct PairClaim: Sendable {
	public static let maxAttestationLength = 32 * 1024

	public let device: DeviceDescription
	/// App Attest's attestation object, as `attestKey` gives it.
	public let attestation: Data?
	/// App Attest's key id, as `generateKey` gives it (standard base64).
	public let keyId: String?
	public let statement: SignedStatement

	public static func make(
		device: DeviceDescription, attestation: Data?, keyId: String?, pairing: PairingID, binding: Data, deviceKey: some StatementSigner
	) throws -> PairClaim {
		guard (attestation == nil) == (keyId == nil) else { throw RemoteKitError("pair", "an attestation without its key id") }
		guard Bytes.constantTimeEqual(deviceKey.publicKey.derRepresentation, device.deviceKey.derRepresentation) else {
			throw RemoteKitError("pair", "signed by a key that is not the device key")
		}
		let signed = JSONValue.object([
			("v", .integer(2)), ("kind", .string("pair")), ("pairing", .string(pairing.text)), ("binding", .string(Base64URL.encode(binding))),
		])
		return PairClaim(device: device, attestation: attestation, keyId: keyId, statement: try SignedStatement.make(signed, signer: deviceKey))
	}

	/// pi² Remote's check, before it passes the claim to the engine, which checks it again with the attestation
	/// (3.3 step 5): the device key signed this channel's binding for this pairing, and the channel key the phone names
	/// is the one the handshake proved it holds.
	public func verify(pairing: PairingID, binding: Data, handshakeChannelKey: Data) throws {
		let part = "pair"
		guard statement.isSigned(by: device.deviceKey) else { throw RemoteKitError(part, "not signed by the device key it names") }
		let fields = try Fields(statement.value, part: part, keys: ["v", "kind", "pairing", "binding"])
		try fields.version()
		guard try fields.string("kind").sameBytes("pair") else { throw RemoteKitError(part, "not a claim to pair") }
		guard try fields.string("pairing").sameBytes(pairing.text) else { throw RemoteKitError(part, "for another pairing") }
		guard Bytes.constantTimeEqual(try fields.bytes("binding", count: 32), binding) else { throw RemoteKitError(part, "for another channel") }
		guard Bytes.constantTimeEqual(device.channelKey.rawRepresentation, handshakeChannelKey) else {
			throw RemoteKitError(part, "names a channel key the handshake was not made with")
		}
	}

	var json: JSONValue {
		.object([("pair", .object([
			("v", .integer(2)), ("device", device.json),
			("attestation", attestation.map { .string(Base64URL.encode($0)) } ?? .null), ("keyId", keyId.map(JSONValue.string) ?? .null),
			("signed", .string(statement.text)), ("signature", .string(statement.signatureText)),
		]))])
	}

	static func read(_ value: JSONValue) throws -> PairClaim {
		let part = "pair"
		let fields = try Fields(value, part: part, keys: ["v", "device", "attestation", "keyId", "signed", "signature"])
		try fields.version()
		var attestation: Data?
		var keyId: String?
		if !fields.value("attestation")!.isNull { attestation = try fields.bytes("attestation", maxCount: maxAttestationLength) }
		if !fields.value("keyId")!.isNull {
			let text = try fields.string("keyId", maxLength: 128)
			guard !text.isEmpty, text.utf8.allSatisfy({ SessionID.allowed($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "=") }) else {
				throw RemoteKitError(part, "keyId is not a key id")
			}
			keyId = text
		}
		guard (attestation == nil) == (keyId == nil) else { throw RemoteKitError(part, "an attestation without its key id") }
		return PairClaim(
			device: try DeviceDescription.read(fields.value("device")!), attestation: attestation, keyId: keyId,
			statement: try SignedStatement.read(text: fields.value("signed"), signature: fields.value("signature"), part: part))
	}
}

/// The Mac's answer once the person typed the digits (3.3 step 8), the last line of a pairing channel:
/// `{"paired":{"device":…,"pairing":…,"name":…,"addresses":[…],"homeKey":<32 bytes>}}`. It is sent only once the Mac
/// proved itself, the engine took the claim and the digits matched, so a claim refused at any step never reads the home
/// key, which travels in it and nowhere else at pairing (#845).
public struct Paired: Sendable, Equatable {
	public let device: DeviceID
	public let pairing: PairingID
	/// The Mac's name.
	public let name: String
	public let addresses: [String]
	/// The key of the home path's tag (5.4), which the phone keeps in its Keychain.
	public let homeKey: HomeKey

	public init(device: DeviceID, pairing: PairingID, name: String, addresses: [String], homeKey: HomeKey) throws {
		guard !name.isEmpty, name.utf8.count <= PairingPayload.maxNameLength, ShownText.isShowable(name) else {
			throw RemoteKitError("paired", "name is not a Mac's name")
		}
		guard addresses.count <= PairingPayload.maxAddresses, addresses.allSatisfy(PairingPayload.isHostAndPort) else {
			throw RemoteKitError("paired", "addresses are not addresses")
		}
		self.device = device
		self.pairing = pairing
		self.name = name
		self.addresses = addresses
		self.homeKey = homeKey
	}

	public static func == (lhs: Paired, rhs: Paired) -> Bool {
		lhs.device == rhs.device && lhs.pairing == rhs.pairing && lhs.name.sameBytes(rhs.name)
			&& lhs.addresses.count == rhs.addresses.count && zip(lhs.addresses, rhs.addresses).allSatisfy { $0.sameBytes($1) }
			&& lhs.homeKey == rhs.homeKey
	}

	var json: JSONValue {
		.object([("paired", .object([
			("device", .string(device.text)), ("pairing", .string(pairing.text)), ("name", .string(name)),
			("addresses", .array(addresses.map(JSONValue.string))), ("homeKey", .string(homeKey.text)),
		]))])
	}

	static func read(_ value: JSONValue) throws -> Paired {
		let part = "paired"
		let fields = try Fields(value, part: part, keys: ["device", "pairing", "name", "addresses", "homeKey"])
		guard let device = DeviceID(try fields.string("device")) else { throw RemoteKitError(part, "device is not a device's id") }
		guard let pairing = PairingID(try fields.string("pairing")) else { throw RemoteKitError(part, "pairing is not a pairing's id") }
		guard case let .array(items) = fields.value("addresses")!, items.count <= PairingPayload.maxAddresses else {
			throw RemoteKitError(part, "addresses are not addresses")
		}
		let addresses = try items.map { item -> String in
			guard let text = item.stringValue else { throw RemoteKitError(part, "addresses are not addresses") }
			return text
		}
		return try Paired(
			device: device, pairing: pairing, name: try fields.string("name", maxLength: PairingPayload.maxNameLength), addresses: addresses,
			homeKey: try HomeKey.read(fields, "homeKey"))
	}
}

/// The phone's attach, afresh or resuming a session, on every new channel (3.4, 4.3, 5.8):
/// `{"attach":{"signed":…,"signature":…,"presence":…}}`, with `"received":<count>` beside them when it resumes. `signed`
/// is `{"v":2,"kind":"attach","pairing":…,"device":…,"session":<null or the session>,"binding":…,"challenge":…,"build":…,"at":…}`,
/// signed by the device key; `presence` is the presence key's signature over the same text. `received`, the count of
/// lines the phone has had in the session, is for pi² Remote's buffer and needs no signature: the channel carries it.
public struct AttachClaim: Sendable {
	public let statement: SignedStatement
	public let presence: Data
	public let received: UInt64?

	public let pairing: PairingID
	public let device: DeviceID
	public let session: SessionID?
	public let binding: Data
	public let challenge: Data
	public let build: String
	/// The phone's clock when it signed, in milliseconds since 1970.
	public let at: Int64

	public static func make(
		pairing: PairingID, device: DeviceID, session: SessionID?, received: UInt64?, binding: Data, challenge: Data, build: String,
		at date: Date = Date(), deviceKey: some StatementSigner, presenceKey: some StatementSigner
	) throws -> AttachClaim {
		guard (session == nil) == (received == nil) else { throw RemoteKitError("attach", "a resume without its count, or a count without a session") }
		if let received, received > UInt64(JSON.maxSafeInteger) { throw RemoteKitError("attach", "received is not a count") }
		let signed = JSONValue.object([
			("v", .integer(2)), ("kind", .string("attach")), ("pairing", .string(pairing.text)), ("device", .string(device.text)),
			("session", session.map { .string($0.text) } ?? .null), ("binding", .string(Base64URL.encode(binding))),
			("challenge", .string(Base64URL.encode(challenge))), ("build", .string(build)),
			("at", .integer(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
		])
		let statement = try SignedStatement.make(signed, signer: deviceKey)
		let presence: Data
		do {
			presence = try presenceKey.sign(Data(statement.text.utf8))
		} catch {
			throw RemoteKitError("attach", "the presence key could not sign")
		}
		guard presence.count == SignedStatement.signatureLength else { throw RemoteKitError("attach", "a presence signature of the wrong length") }
		return try AttachClaim(statement: statement, presence: presence, received: received)
	}

	private init(statement: SignedStatement, presence: Data, received: UInt64?) throws {
		let part = "attach"
		let fields = try Fields(statement.value, part: part, keys: ["v", "kind", "pairing", "device", "session", "binding", "challenge", "build", "at"])
		try fields.version()
		guard try fields.string("kind").sameBytes("attach") else { throw RemoteKitError(part, "not an attach") }
		guard let pairing = PairingID(try fields.string("pairing")) else { throw RemoteKitError(part, "pairing is not a pairing's id") }
		guard let device = DeviceID(try fields.string("device")) else { throw RemoteKitError(part, "device is not a device's id") }
		var session: SessionID?
		if !fields.value("session")!.isNull {
			guard let id = SessionID(try fields.string("session")) else { throw RemoteKitError(part, "session is not a session's id") }
			session = id
		}
		guard (session == nil) == (received == nil) else { throw RemoteKitError(part, "a resume without its count, or a count without a session") }
		self.statement = statement
		self.presence = presence
		self.received = received
		self.pairing = pairing
		self.device = device
		self.session = session
		binding = try fields.bytes("binding", count: 32)
		challenge = try fields.bytes("challenge", count: 32)
		build = try readBuild(fields, part: part)
		at = try fields.integer("at")
	}

	/// pi² Remote's own check against its list of device keys (3.4): this device's key signed an attach for this
	/// pairing and device, bound to this channel.
	public func verifyDevice(deviceKey: P256.Signing.PublicKey, pairing: PairingID, device: DeviceID, binding: Data) throws {
		let part = "attach"
		guard statement.isSigned(by: deviceKey) else { throw RemoteKitError(part, "not signed by the device key") }
		guard self.pairing == pairing else { throw RemoteKitError(part, "for another pairing") }
		guard self.device == device else { throw RemoteKitError(part, "for another device") }
		guard Bytes.constantTimeEqual(self.binding, binding) else { throw RemoteKitError(part, "for another channel") }
	}

	/// The whole check the engine makes (3.4), for a test end or a reader in Swift: both signatures, the binding, the
	/// challenge issued for this channel, and `at` within two minutes of `now`.
	public func verify(
		deviceKey: P256.Signing.PublicKey, presenceKey: P256.Signing.PublicKey, pairing: PairingID, device: DeviceID, binding: Data,
		challenge: Data, now: Date = Date()
	) throws {
		try verifyDevice(deviceKey: deviceKey, pairing: pairing, device: device, binding: binding)
		guard SignedStatement.verify(presence, over: Data(statement.text.utf8), by: presenceKey) else {
			throw RemoteKitError("attach", "no valid presence signature")
		}
		guard Bytes.constantTimeEqual(self.challenge, challenge) else { throw RemoteKitError("attach", "for another challenge") }
		let skew = abs(Double(at) / 1000 - now.timeIntervalSince1970)
		guard skew <= attachClockWindow else { throw RemoteKitError("attach", "signed more than two minutes from now") }
	}

	var json: JSONValue {
		var members: [(String, JSONValue)] = [
			("signed", .string(statement.text)), ("signature", .string(statement.signatureText)), ("presence", .string(Base64URL.encode(presence))),
		]
		if let received { members.append(("received", .integer(Int64(received)))) }
		return .object([("attach", .object(members))])
	}

	static func read(_ value: JSONValue) throws -> AttachClaim {
		let part = "attach"
		let fields = try Fields(value, part: part, keys: ["signed", "signature", "presence"], optional: ["received"])
		var received: UInt64?
		if fields.value("received") != nil {
			let count = try fields.integer("received")
			guard count >= 0 else { throw RemoteKitError(part, "received is not a count") }
			received = UInt64(count)
		}
		return try AttachClaim(
			statement: try SignedStatement.read(text: fields.value("signed"), signature: fields.value("signature"), part: part),
			presence: try fields.bytes("presence", count: SignedStatement.signatureLength), received: received)
	}
}

/// The phone's offer of a new presence key, in place of `attach` on a connection's channel, when Face ID was enrolled
/// again and the old key no longer signs (iphone.md 3.2, #891): `{"presenceKey":{"signed":…,"signature":…,"presence":…}}`.
/// `signed` is `{"v":2,"kind":"presenceKey","pairing":…,"device":…,"binding":…,"challenge":…,"presenceKey":…,"build":…,"at":…}`,
/// in exactly that order, as the engine's `readSigned` reads it (devices.ts, `offerPresenceKey`), signed by the device key;
/// `presence` is the offered key's own signature over the same text, so that the phone proves it holds it. The key is
/// the uncompressed SPKI DER CryptoKit writes, 91 bytes, the one form `PublicKeys.signingKey` reads. The challenge is the
/// one the Mac's proof carried on this channel, as an attach's.
public struct PresenceKeyOffer: Sendable {
	public let statement: SignedStatement
	/// The offered key's signature over the signed text.
	public let presence: Data

	public let pairing: PairingID
	public let device: DeviceID
	public let binding: Data
	public let challenge: Data
	/// The new presence key.
	public let presenceKey: P256.Signing.PublicKey
	public let build: String
	/// The phone's clock when it signed, in milliseconds since 1970.
	public let at: Int64

	static let fields = ["v", "kind", "pairing", "device", "binding", "challenge", "presenceKey", "build", "at"]

	/// The exact text the device key and the offered key sign, for a signer that signs asynchronously (the phone's
	/// presence session) and must sign it before `make` is called with what it made.
	public static func signedText(
		pairing: PairingID, device: DeviceID, binding: Data, challenge: Data, presenceKey: P256.Signing.PublicKey, build: String, at date: Date
	) -> String {
		JSON.text(signedValue(pairing: pairing, device: device, binding: binding, challenge: challenge, presenceKey: presenceKey, build: build, at: date))
	}

	private static func signedValue(
		pairing: PairingID, device: DeviceID, binding: Data, challenge: Data, presenceKey: P256.Signing.PublicKey, build: String, at date: Date
	) -> JSONValue {
		.object([
			("v", .integer(2)), ("kind", .string("presenceKey")), ("pairing", .string(pairing.text)), ("device", .string(device.text)),
			("binding", .string(Base64URL.encode(binding))), ("challenge", .string(Base64URL.encode(challenge))),
			("presenceKey", .string(PublicKeys.text(presenceKey))), ("build", .string(build)),
			("at", .integer(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
		])
	}

	/// Signs an offer of `offeredKey`'s public half with the device key and with the offered key itself.
	public static func make(
		pairing: PairingID, device: DeviceID, binding: Data, challenge: Data, build: String, at date: Date = Date(), deviceKey: some StatementSigner,
		offeredKey: some StatementSigner
	) throws -> PresenceKeyOffer {
		let part = "presenceKey"
		guard !Bytes.constantTimeEqual(deviceKey.publicKey.derRepresentation, offeredKey.publicKey.derRepresentation) else {
			throw RemoteKitError(part, "the device key and the offered key are one key")
		}
		let signed = signedValue(pairing: pairing, device: device, binding: binding, challenge: challenge, presenceKey: offeredKey.publicKey, build: build, at: date)
		let statement = try SignedStatement.make(signed, signer: deviceKey)
		let presence: Data
		do {
			presence = try offeredKey.sign(Data(statement.text.utf8))
		} catch {
			throw RemoteKitError(part, "the offered key could not sign")
		}
		guard presence.count == SignedStatement.signatureLength else { throw RemoteKitError(part, "a presence signature of the wrong length") }
		return try PresenceKeyOffer(statement: statement, presence: presence)
	}

	private init(statement: SignedStatement, presence: Data) throws {
		let part = "presenceKey"
		let fields = try Fields(statement.value, part: part, keys: Self.fields)
		// In the engine's order too, as `readSigned` reads it: one written otherwise would only be refused there.
		guard case let .object(members) = statement.value, members.count == Self.fields.count, zip(members, Self.fields).allSatisfy({ $0.0.sameBytes($1) }) else {
			throw RemoteKitError(part, "fields not in the order the engine reads")
		}
		try fields.version()
		guard try fields.string("kind").sameBytes("presenceKey") else { throw RemoteKitError(part, "not an offer of a presence key") }
		guard let pairing = PairingID(try fields.string("pairing")) else { throw RemoteKitError(part, "pairing is not a pairing's id") }
		guard let device = DeviceID(try fields.string("device")) else { throw RemoteKitError(part, "device is not a device's id") }
		guard let key = PublicKeys.signingKey(fromBase64URL: try fields.string("presenceKey")) else { throw RemoteKitError(part, "presenceKey is not a key") }
		self.statement = statement
		self.presence = presence
		self.pairing = pairing
		self.device = device
		presenceKey = key
		binding = try fields.bytes("binding", count: 32)
		challenge = try fields.bytes("challenge", count: 32)
		build = try readBuild(fields, part: part)
		at = try fields.integer("at")
	}

	/// pi² Remote's own check against its list of device keys (3.4), as for an attach: this device's key signed an offer
	/// for this pairing and device, bound to this channel. The rest is the engine's to check, and to count.
	public func verifyDevice(deviceKey: P256.Signing.PublicKey, pairing: PairingID, device: DeviceID, binding: Data) throws {
		let part = "presenceKey"
		guard statement.isSigned(by: deviceKey) else { throw RemoteKitError(part, "not signed by the device key") }
		guard self.pairing == pairing else { throw RemoteKitError(part, "for another pairing") }
		guard self.device == device else { throw RemoteKitError(part, "for another device") }
		guard Bytes.constantTimeEqual(self.binding, binding) else { throw RemoteKitError(part, "for another channel") }
	}

	/// The whole check the engine makes (devices.ts, `offerPresenceKey`), for a test end or a reader in Swift: the device
	/// key's signature, the offered key's own, a key that is not the device key, the binding, the challenge issued for
	/// this channel, and `at` within two minutes of `now`.
	public func verify(deviceKey: P256.Signing.PublicKey, pairing: PairingID, device: DeviceID, binding: Data, challenge: Data, now: Date = Date()) throws {
		let part = "presenceKey"
		try verifyDevice(deviceKey: deviceKey, pairing: pairing, device: device, binding: binding)
		guard SignedStatement.verify(presence, over: Data(statement.text.utf8), by: presenceKey) else { throw RemoteKitError(part, "not signed by the key it offers") }
		guard !Bytes.constantTimeEqual(presenceKey.derRepresentation, deviceKey.derRepresentation) else { throw RemoteKitError(part, "offers the device key") }
		guard Bytes.constantTimeEqual(self.challenge, challenge) else { throw RemoteKitError(part, "for another challenge") }
		let skew = abs(Double(at) / 1000 - now.timeIntervalSince1970)
		guard skew <= attachClockWindow else { throw RemoteKitError(part, "signed more than two minutes from now") }
	}

	var json: JSONValue {
		.object([("presenceKey", .object([
			("signed", .string(statement.text)), ("signature", .string(statement.signatureText)), ("presence", .string(Base64URL.encode(presence))),
		]))])
	}

	static func read(_ value: JSONValue) throws -> PresenceKeyOffer {
		let part = "presenceKey"
		let fields = try Fields(value, part: part, keys: ["signed", "signature", "presence"])
		return try PresenceKeyOffer(
			statement: try SignedStatement.read(text: fields.value("signed"), signature: fields.value("signature"), part: part),
			presence: try fields.bytes("presence", count: SignedStatement.signatureLength))
	}
}

/// pi² Remote's answer to an attach: the session, and whether it was resumed (5.8: `resume: false` sends the phone to
/// attach afresh).
public struct Attached: Sendable, Equatable {
	public let session: SessionID
	public let resume: Bool

	public init(session: SessionID, resume: Bool) {
		self.session = session
		self.resume = resume
	}

	var json: JSONValue { .object([("attached", .object([("session", .string(session.text)), ("resume", .bool(resume))]))]) }

	static func read(_ value: JSONValue) throws -> Attached {
		let part = "attached"
		let fields = try Fields(value, part: part, keys: ["session", "resume"])
		guard let session = SessionID(try fields.string("session")) else { throw RemoteKitError(part, "session is not a session's id") }
		guard let resume = fields.value("resume")?.boolValue else { throw RemoteKitError(part, "resume is not true or false") }
		return Attached(session: session, resume: resume)
	}
}

/// The Mac's word that a device is revoked (3.6), signed by its identity key: `{"revoked":{"signed":…,"signature":…}}`
/// with `signed` = `{"v":2,"kind":"revoked","pairing":…,"device":…,"at":…}`. The phone acts on no other.
public struct Revocation: Sendable {
	public let statement: SignedStatement
	public let pairing: PairingID
	public let device: DeviceID
	public let at: Int64

	public static func make(pairing: PairingID, device: DeviceID, at date: Date = Date(), identity: some StatementSigner) throws -> Revocation {
		let signed = JSONValue.object([
			("v", .integer(2)), ("kind", .string("revoked")), ("pairing", .string(pairing.text)), ("device", .string(device.text)),
			("at", .integer(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
		])
		return try Revocation(statement: try SignedStatement.make(signed, signer: identity))
	}

	private init(statement: SignedStatement) throws {
		let part = "revoked"
		let fields = try Fields(statement.value, part: part, keys: ["v", "kind", "pairing", "device", "at"])
		try fields.version()
		guard try fields.string("kind").sameBytes("revoked") else { throw RemoteKitError(part, "not a revocation") }
		guard let pairing = PairingID(try fields.string("pairing")) else { throw RemoteKitError(part, "pairing is not a pairing's id") }
		guard let device = DeviceID(try fields.string("device")) else { throw RemoteKitError(part, "device is not a device's id") }
		self.statement = statement
		self.pairing = pairing
		self.device = device
		at = try fields.integer("at")
	}

	/// The phone's check: its Mac's identity key revoked this very device.
	public func verify(identityKey: P256.Signing.PublicKey, pairing: PairingID, device: DeviceID) throws {
		guard statement.isSigned(by: identityKey) else { throw RemoteKitError("revoked", "not signed by the Mac's identity key") }
		guard self.pairing == pairing, self.device == device else { throw RemoteKitError("revoked", "for another device") }
	}

	var json: JSONValue {
		.object([("revoked", .object([("signed", .string(statement.text)), ("signature", .string(statement.signatureText))]))])
	}

	static func read(_ value: JSONValue) throws -> Revocation {
		let part = "revoked"
		let fields = try Fields(value, part: part, keys: ["signed", "signature"])
		return try Revocation(statement: try SignedStatement.read(text: fields.value("signed"), signature: fields.value("signature"), part: part))
	}
}

/// pi² Remote's word that it did not attach the phone, and why, from a fixed list: `{"refused":{"reason":…}}`, sent
/// just before the channel's `bye` (`Channel.sealRefusal`). Never free text: the engine's own words stay on the Mac.
/// It travels inside the channel, so only a device that completed the handshake with a channel key on pi² Remote's list
/// reads it, and pi² Remote sends it only once the attach is signed by that device's key; what each reason tells the
/// device, and what the phone does on each, is in remotekit.md ("The refused line"). A reason this build does not
/// know, from a newer Mac, is read as a plain refusal (`reason` nil), never as an error.
public struct Refusal: Sendable, Equatable {
	public enum Reason: String, Sendable, CaseIterable {
		/// The phone's build is below the lowest this Mac attaches (5.3, 6.5).
		case update
		/// The device is suspended until the person resumes it on the Mac's Devices page (3.6).
		case suspended
		/// The presence signature was not taken: the presence key's signature was refused, or a new presence key waits to
		/// be accepted on the Mac (4.3).
		case presence
		/// The attach's `at` is more than two minutes from the Mac's clock (3.4).
		case clock
		/// The session the attach named cannot be resumed on this channel: the phone attaches afresh (5.8).
		case resume
	}

	/// Nil for a reason this build does not know.
	public var reason: Reason? { Reason.allCases.first { $0.rawValue.sameBytes(text) } }

	/// The reason as written: a reason this build knows, or one of the same form it does not.
	private let text: String

	public init(_ reason: Reason) { text = reason.rawValue }

	private init(text: String) { self.text = text }

	/// The longest reason read: lower-case letters, as many as a Mac item's kind.
	static let maxReasonLength = 32

	public static func == (lhs: Refusal, rhs: Refusal) -> Bool { lhs.text.sameBytes(rhs.text) }

	var json: JSONValue { .object([("refused", .object([("reason", .string(text))]))]) }

	static func read(_ value: JSONValue) throws -> Refusal {
		let part = "refused"
		let fields = try Fields(value, part: part, keys: ["reason"])
		let text = try fields.string("reason", maxLength: maxReasonLength)
		guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else {
			throw RemoteKitError(part, "reason is not a reason")
		}
		return Refusal(text: text)
	}
}

/// pi² Remote's word to a phone whose claim to pair did not end paired, and why, from a fixed list (#881):
/// `{"pairRefused":{"why":…}}`, sent just before the pairing channel's `bye` (`Channel.sealPairRefusal`), in place of
/// `paired`. Never free text: the engine's words stay on the Mac. Only a phone that proved the code's secret and sent a
/// claim reads it, and only for a refusal the Mac gives a word for; any other refusal ends the channel with `bye` alone.
/// A word this build does not know, from a newer Mac, is read as no word (`why` nil), never as an error.
public struct PairRefusal: Sendable, Equatable {
	public enum Why: String, Sendable, CaseIterable {
		/// The Mac could not save the pairing: the engine's record, or pi² Remote's own list of devices and the home key.
		case unsaved
		/// The person closed the pairing on the Mac (Cancel, a new code, Reach from an iPhone turned off).
		case cancelled
	}

	/// Nil for a word this build does not know.
	public var why: Why? { Why.allCases.first { $0.rawValue.sameBytes(text) } }

	/// The word as written: one this build knows, or one of the same form it does not.
	private let text: String

	public init(_ why: Why) { text = why.rawValue }

	private init(text: String) { self.text = text }

	public static func == (lhs: PairRefusal, rhs: PairRefusal) -> Bool { lhs.text.sameBytes(rhs.text) }

	var json: JSONValue { .object([("pairRefused", .object([("why", .string(text))]))]) }

	static func read(_ value: JSONValue) throws -> PairRefusal {
		let part = "pairRefused"
		let fields = try Fields(value, part: part, keys: ["why"])
		let text = try fields.string("why", maxLength: Refusal.maxReasonLength)
		guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else {
			throw RemoteKitError(part, "why is not a word")
		}
		return PairRefusal(text: text)
	}
}

/// The home path's new key, which pi² Remote gives each remaining device after it revoked one (3.6, 5.4, #845):
/// `{"homeKey":{"key":<32 bytes>}}`. Mac to phone only, and only on a connection channel after `attached`, so only a
/// device that proved its device key and presence key reads it; the phone keeps the one it read last, in place of the
/// one it had. What each end does with one that comes where it should not is in remotekit.md ("The home key").
enum HomeKeyLine {
	static func read(_ value: JSONValue) throws -> HomeKey {
		let fields = try Fields(value, part: "homeKey", keys: ["key"])
		return try HomeKey.read(fields, "key")
	}

	static func json(_ key: HomeKey) -> JSONValue { .object([("homeKey", .object([("key", .string(key.text))]))]) }
}

/// One of a channel's own lines (5.6), as read from or written to the channel.
public enum ControlLine: Sendable {
	/// The Mac's first message: a challenge and its proof.
	case mac(MacProof)
	case pair(PairClaim)
	case paired(Paired)
	case attach(AttachClaim)
	case attached(Attached)
	case revoked(Revocation)
	/// pi² Remote did not attach the phone, and says why; the channel's `bye` follows.
	case refused(Refusal)
	/// The phone's claim to pair did not end paired, and the Mac says why; the pairing channel's `bye` follows.
	case pairRefused(PairRefusal)
	/// The phone's session ended (4.5): `{"sessionEnd":{}}`.
	case sessionEnd
	/// The home path's new key, after a revocation (3.6): Mac to phone, on an attached channel.
	case homeKey(HomeKey)
	/// The phone's offer of a new presence key, in place of `attach` (3.2, #891).
	case presenceKey(PresenceKeyOffer)
	/// The Mac's answer to an offer of the presence key it already uses: `{"presenceKeyAccepted":{}}`, then `bye`. While the
	/// key waits, the answer is `refused` with `presence`.
	case presenceKeyAccepted

	/// The two ends of a channel.
	public enum Side: Sendable, Equatable {
		/// pi² Remote.
		case mac
		case phone
	}

	/// Which end writes this line: every line of the channel's own has one writer, and the other end never sends it.
	public var sender: Side {
		switch self {
		case .mac, .paired, .attached, .revoked, .refused, .pairRefused, .homeKey, .presenceKeyAccepted: .mac
		case .pair, .attach, .sessionEnd, .presenceKey: .phone
		}
	}

	/// Reads one of these lines from `sender`'s end, as the other end reads it: a line the other end does not send is
	/// refused as well as anything `parse(_:)` refuses, so a phone that sends `homeKey` or `refused`, or a Mac that sends
	/// `pair`, is never taken. Which lines may come at which point of a channel stays the caller's to keep.
	public static func parse(_ line: Data, from sender: Side) throws -> ControlLine {
		let read = try parse(line)
		guard read.sender == sender else {
			throw RemoteKitError("channel line", sender == .phone ? "a line the phone never sends" : "a line the Mac never sends")
		}
		return read
	}

	/// Reads one of these lines and nothing else: the line must be exactly one of them. It does not say which end wrote
	/// it; `parse(_:from:)` does.
	public static func parse(_ line: Data) throws -> ControlLine {
		guard line.count <= maxControlLineLength else { throw RemoteKitError("channel line", "too long") }
		let value: JSONValue
		do {
			value = try JSON.parse(line)
		} catch {
			throw RemoteKitError("channel line", "not JSON as RemoteKit reads it")
		}
		guard case let .object(members) = value, !members.isEmpty else { throw RemoteKitError("channel line", "not one of the channel's lines") }
		if members.count == 2, value["challenge"] != nil, value["mac"] != nil { return .mac(try MacProof.read(value)) }
		guard members.count == 1 else { throw RemoteKitError("channel line", "not one of the channel's lines") }
		let (name, inner) = members[0]
		// Names compared byte for byte, as everywhere a text from outside is compared (String.sameBytes).
		if name.sameBytes("pair") { return .pair(try PairClaim.read(inner)) }
		if name.sameBytes("paired") { return .paired(try Paired.read(inner)) }
		if name.sameBytes("attach") { return .attach(try AttachClaim.read(inner)) }
		if name.sameBytes("attached") { return .attached(try Attached.read(inner)) }
		if name.sameBytes("revoked") { return .revoked(try Revocation.read(inner)) }
		if name.sameBytes("refused") { return .refused(try Refusal.read(inner)) }
		if name.sameBytes("pairRefused") { return .pairRefused(try PairRefusal.read(inner)) }
		if name.sameBytes("homeKey") { return .homeKey(try HomeKeyLine.read(inner)) }
		if name.sameBytes("sessionEnd") {
			guard case let .object(fields) = inner, fields.isEmpty else { throw RemoteKitError("sessionEnd", "not empty") }
			return .sessionEnd
		}
		if name.sameBytes("presenceKey") { return .presenceKey(try PresenceKeyOffer.read(inner)) }
		if name.sameBytes("presenceKeyAccepted") {
			guard case let .object(fields) = inner, fields.isEmpty else { throw RemoteKitError("presenceKeyAccepted", "not empty") }
			return .presenceKeyAccepted
		}
		throw RemoteKitError("channel line", "not one of the channel's lines")
	}

	/// The line's bytes, ready for `Channel.seal(line:)`.
	public var line: Data {
		switch self {
		case let .mac(proof): JSON.write(proof.json)
		case let .pair(claim): JSON.write(claim.json)
		case let .paired(paired): JSON.write(paired.json)
		case let .attach(claim): JSON.write(claim.json)
		case let .attached(attached): JSON.write(attached.json)
		case let .revoked(revocation): JSON.write(revocation.json)
		case let .refused(refusal): JSON.write(refusal.json)
		case let .pairRefused(refusal): JSON.write(refusal.json)
		case .sessionEnd: JSON.write(.object([("sessionEnd", .object([]))]))
		case let .homeKey(key): JSON.write(HomeKeyLine.json(key))
		case let .presenceKey(offer): JSON.write(offer.json)
		case .presenceKeyAccepted: JSON.write(.object([("presenceKeyAccepted", .object([]))]))
		}
	}
}
