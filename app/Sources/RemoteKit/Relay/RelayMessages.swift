
import CryptoKit
import Foundation

// The relay's protocol as its client reads and writes it (iphone.md 5.3; relay/README.md, "The protocol", which has the
// exact form and wins where the two differ). Every text the relay sends is read strictly, as RemoteKit's other readers
// read: RemoteKit's JSON reader (no white space, no key twice, nothing after the value), every field present and none
// unknown, and the text exactly as JavaScript's `JSON.stringify` writes what it holds, which is how the relay writes
// it, so each message has one way of being written. What an end may be sent depends on what it is (`RelayEnd`): a Mac
// is never sent a phone's notice, and the other way round. Nothing is acted on until all of it has been read.

/// What one end is at the relay, which decides the messages it may be sent.
public enum RelayEnd: Sendable {
	/// A Mac registering a new pairing.
	case registering
	/// The pairing's Mac.
	case mac
	/// A listed phone.
	case device
	/// A phone with no slot, joining an open window; once the Mac adds it, the same socket is a listed phone's.
	case joining
}

/// An end of the relay's mailbox: the Mac, or one of the pairing's devices.
public enum RelayAddress: Hashable, Sendable, CustomStringConvertible {
	case mac
	case device(DeviceID)

	var text: String {
		switch self {
		case .mac: "mac"
		case let .device(device): device.text
		}
	}

	public var description: String { text }
}

/// A build as the relay compares them: up to three whole numbers with dots between (`CFBundleVersion`, or the Mac's build
/// number), as `readBuild` in `relay/src/protocol.ts` takes it.
public struct RelayBuild: Hashable, Sendable, CustomStringConvertible {
	public let text: String

	public init?(_ text: String) {
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		guard (1...3).contains(parts.count) else { return nil }
		for part in parts {
			guard (1...9).contains(part.utf8.count), part.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
			if part.utf8.count > 1, part.utf8.first == UInt8(ascii: "0") { return nil }
		}
		self.text = text
	}

	public var description: String { text }
}

/// An App Attest key's id as `DCAppAttestService` gives it: 32 bytes in standard base64, with its padding.
public struct AttestKeyID: Hashable, Sendable, CustomStringConvertible {
	public let text: String

	public init?(_ text: String) {
		guard text.utf8.count == 44, let bytes = Data(base64Encoded: text), bytes.count == 32, bytes.base64EncodedString() == text else { return nil }
		self.text = text
	}

	public init(bytes: Data) {
		precondition(bytes.count == 32, "an App Attest key id is 32 bytes")
		text = bytes.base64EncodedString()
	}

	public var description: String { text }
}

/// The fixed words of a refusal (`Why` in `relay/src/protocol.ts`). A word this client does not know is kept as it is,
/// so that a newer relay's refusal is still a refusal; it must be a word, never text the relay chose freely.
public struct RelayWhy: Hashable, Sendable, CustomStringConvertible {
	public let word: String

	public init?(word: String) {
		let bytes = Array(word.utf8)
		guard (1...32).contains(bytes.count), (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0]),
			bytes.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || $0 == UInt8(ascii: "-") })
		else { return nil }
		self.word = word
	}

	private init(_ word: String) { self.word = word }

	public static let malformed = RelayWhy("malformed")
	public static let unavailable = RelayWhy("unavailable")
	public static let unknownPairing = RelayWhy("unknown-pairing")
	public static let notListed = RelayWhy("not-listed")
	public static let signature = RelayWhy("signature")
	public static let updateRequired = RelayWhy("update-required")
	public static let anotherMac = RelayWhy("another-mac")
	public static let limits = RelayWhy("limits")
	public static let tooMany = RelayWhy("too-many")
	public static let timeout = RelayWhy("timeout")
	public static let windowClosed = RelayWhy("window-closed")
	public static let token = RelayWhy("token")
	public static let attestation = RelayWhy("attestation")
	public static let category = RelayWhy("category")
	public static let bundleVersion = RelayWhy("bundle-version")
	public static let attestKeyTaken = RelayWhy("attest-key-taken")
	public static let full = RelayWhy("full")
	public static let exists = RelayWhy("exists")
	public static let unknownDevice = RelayWhy("unknown-device")
	public static let deviceKey = RelayWhy("device-key")
	public static let notJoined = RelayWhy("not-joined")
	public static let mailboxFull = RelayWhy("mailbox-full")
	public static let busy = RelayWhy("busy")
	public static let removed = RelayWhy("removed")
	public static let left = RelayWhy("left")
	public static let deleted = RelayWhy("deleted")
	public static let replaced = RelayWhy("replaced")
	public static let windowEnded = RelayWhy("window-ended")

	public var description: String { word }
}

/// The Mac's requests and the ends' mailbox requests, as the relay names them in `ok { what }` and `refused { what }`.
public enum RelayRequestKind: String, Sendable, CaseIterable {
	case openJoin, closeJoin, addDevice, removeDevice, deletePairing, state, put, take, token
}

/// A device as the Mac's `ready` lists it.
public struct RelayDevicePresence: Equatable, Sendable {
	public let device: DeviceID
	public let online: Bool

	public init(device: DeviceID, online: Bool) {
		self.device = device
		self.online = online
	}
}

/// What the relay tells the Mac once it has proved itself.
public struct RelayMacReady: Equatable, Sendable {
	/// The listed devices, and whether each is connected.
	public let devices: [RelayDevicePresence]
	/// Devices that left while the Mac was away (3.6).
	public let left: [DeviceID]
	/// Whether the pairing is still pending: no device added yet, deleted 15 minutes after it was registered.
	public let pending: Bool
	/// How many items wait in its mailbox.
	public let mail: Int

	public init(devices: [RelayDevicePresence], left: [DeviceID], pending: Bool, mail: Int) {
		self.devices = devices
		self.left = left
		self.pending = pending
		self.mail = mail
	}
}

/// A phone that joined the open window, as the Mac is told (3.3 step 2): its slot, its device key, and the App Attest
/// key the relay checked.
public struct RelayJoinNotice: Equatable, Sendable {
	public let slot: DeviceID
	public let deviceKey: P256.Signing.PublicKey
	public let keyId: AttestKeyID

	public init(slot: DeviceID, deviceKey: P256.Signing.PublicKey, keyId: AttestKeyID) {
		self.slot = slot
		self.deviceKey = deviceKey
		self.keyId = keyId
	}

	public static func == (a: RelayJoinNotice, b: RelayJoinNotice) -> Bool {
		a.slot == b.slot && a.keyId == b.keyId && a.deviceKey.derRepresentation == b.deviceKey.derRepresentation
	}
}

/// A sealed item taken from the mailbox, as the relay hands it over. What it holds is RemoteKit's `SealedItem`'s to
/// open; the relay cannot read it.
public struct RelayMailItem: Equatable, Sendable {
	public let from: RelayAddress
	public let id: ItemID
	public let item: Data
	/// Whether its writer marked it `presence` (a `"face"` request, kept an hour).
	public let presence: Bool

	public init(from: RelayAddress, id: ItemID, item: Data, presence: Bool) {
		self.from = from
		self.id = id
		self.item = item
		self.presence = presence
	}
}

/// The Mac's latest state for a device, as the device takes it.
public struct RelayStateItem: Equatable, Sendable {
	public let id: ItemID
	public let item: Data

	public init(id: ItemID, item: Data) {
		self.id = id
		self.item = item
	}
}

/// One text message from the relay, read.
public enum RelayIncoming: Equatable, Sendable {
	/// The 32 bytes to sign, after `hello`, `register` or a phone's first `hello`.
	case challenge(Data)
	case registered(PairingID)
	case macReady(RelayMacReady)
	case deviceReady(macOnline: Bool, mail: Int)
	/// The joining phone's slot.
	case joined(DeviceID)
	case ok(RelayRequestKind)
	/// A refusal that closes the socket.
	case refused(RelayWhy)
	/// A request refused, on a socket that stays open.
	case requestRefused(RelayRequestKind, RelayWhy)
	/// Past a limit: the socket is closed, and may come back at `until` (ms since 1970, the relay's clock).
	case busy(until: Int64)
	case pong
	case item(RelayMailItem)
	case state(RelayStateItem)
	case taken(count: Int)
	/// Something arrived in this end's mailbox.
	case mail
	// The Mac's notices.
	case online(DeviceID)
	case offline(DeviceID)
	case phoneJoined(RelayJoinNotice)
	case left(DeviceID)
	case anotherMac
	case held(DeviceID, until: Int64)
	// A phone's.
	case macOnline(Bool)
}

/// The limits of what the relay sends and takes (`relay/src/protocol.ts`).
public enum RelayLimits {
	/// The longest text message either way.
	public static let maxText = 48 * 1024
	/// The longest binary message either way: a Noise message (at most 65,535 bytes) and a device's id.
	public static let maxBinary = 70 * 1024
	/// A sealed item: at least HPKE's encapsulated key (65 bytes) and a tag, at most 16 KB.
	public static let minItem = 65 + 16
	public static let maxItem = 16 * 1024
	/// An App Attest attestation, at most (App Attest makes some 6 KB).
	public static let maxAttestation = 32 * 1024
	/// The most items a `take` can bring: the Mac's mailbox holds at most 200, a device's 100 and its state.
	static let maxTaken = 1000
	/// A time in `busy` and `held`, at most: the year 2286, in ms. Anything larger is not a time.
	static let maxTime: Int64 = 9_999_999_999_999
}

extension RelayIncoming {
	/// Reads one text message the relay sent to an end of this kind. Throws `RemoteKitError` for anything that is not
	/// exactly one of the protocol's messages for that end.
	public static func parse(_ text: String, for end: RelayEnd) throws -> RelayIncoming {
		let part = "relay message"
		guard text.utf8.count <= RelayLimits.maxText else { throw RemoteKitError(part, "too long") }
		let value: JSONValue
		do {
			value = try JSON.parse(text)
		} catch {
			throw RemoteKitError(part, "not JSON as RemoteKit reads it")
		}
		// One way of writing each message: the text JavaScript writes for what it holds.
		guard JSON.text(value).sameBytes(text) else { throw RemoteKitError(part, "not written as the relay writes it") }
		guard case let .object(members) = value, members.count == 1 else { throw RemoteKitError(part, "not one named message") }
		let (name, body) = members[0]

		// The challenge alone holds its bytes directly, not an object.
		if name.sameBytes("challenge") {
			guard let encoded = body.stringValue, let bytes = Base64URL.decode(encoded, count: 32) else {
				throw RemoteKitError("relay challenge", "not 32 bytes of base64url")
			}
			return .challenge(bytes)
		}
		guard case .object = body else { throw RemoteKitError(part, "not one named message") }

		switch (name, end) {
		case ("registered", .registering):
			let fields = try Fields(body, part: "relay registered", keys: ["pairing"])
			return .registered(try pairing(fields, "pairing"))
		case ("ready", .mac):
			let fields = try Fields(body, part: "relay ready", keys: ["devices", "left", "pending", "mail"])
			guard case let .array(listed)? = fields.value("devices"), listed.count <= 16 else { throw RemoteKitError(fields.part, "devices is not a list") }
			let devices = try listed.map { entry in
				let device = try Fields(entry, part: "relay ready", keys: ["device", "online"])
				return RelayDevicePresence(device: try deviceID(device, "device"), online: try bool(device, "online"))
			}
			guard case let .array(gone)? = fields.value("left"), gone.count <= 64 else { throw RemoteKitError(fields.part, "left is not a list") }
			let left = try gone.map { entry in
				guard let text = entry.stringValue, let device = DeviceID(text) else { throw RemoteKitError(fields.part, "left holds what is not a device") }
				return device
			}
			return .macReady(RelayMacReady(devices: devices, left: left, pending: try bool(fields, "pending"), mail: try count(fields, "mail")))
		case ("ready", .device):
			let fields = try Fields(body, part: "relay ready", keys: ["mac", "mail"])
			return .deviceReady(macOnline: try bool(fields, "mac"), mail: try count(fields, "mail"))
		case ("joined", .joining):
			let fields = try Fields(body, part: "relay joined", keys: ["device"])
			return .joined(try deviceID(fields, "device"))
		case ("joined", .mac):
			let fields = try Fields(body, part: "relay joined", keys: ["device", "deviceKey", "keyId"])
			guard let key = PublicKeys.signingKey(fromBase64URL: try fields.string("deviceKey")) else { throw RemoteKitError(fields.part, "deviceKey is not a P-256 key") }
			guard let keyId = AttestKeyID(try fields.string("keyId")) else { throw RemoteKitError(fields.part, "keyId is not an App Attest key's id") }
			return .phoneJoined(RelayJoinNotice(slot: try deviceID(fields, "device"), deviceKey: key, keyId: keyId))
		case ("ok", .mac), ("ok", .device):
			let fields = try Fields(body, part: "relay ok", keys: ["what"])
			return .ok(try kind(fields, for: end))
		case ("refused", _):
			if body["what"] != nil {
				guard end == .mac || end == .device else { throw RemoteKitError("relay refused", "a request refused to an end that sends none") }
				let fields = try Fields(body, part: "relay refused", keys: ["what", "why"])
				return .requestRefused(try kind(fields, for: end), try why(fields))
			}
			let fields = try Fields(body, part: "relay refused", keys: ["why"])
			return .refused(try why(fields))
		case ("busy", _):
			let fields = try Fields(body, part: "relay busy", keys: ["until"])
			return .busy(until: try time(fields, "until"))
		case ("pong", _):
			_ = try Fields(body, part: "relay pong", keys: [])
			return .pong
		case ("item", .mac), ("item", .device):
			let fields = try Fields(body, part: "relay item", keys: ["from", "id", "item", "presence"])
			let fromText = try fields.string("from")
			let from: RelayAddress
			if end == .mac {
				guard let device = DeviceID(fromText) else { throw RemoteKitError(fields.part, "from is not a device") }
				from = .device(device)
			} else {
				guard fromText.sameBytes("mac") else { throw RemoteKitError(fields.part, "from is not the Mac") }
				from = .mac
			}
			return .item(RelayMailItem(from: from, id: try itemID(fields, "id"), item: try item(fields, "item"), presence: try bool(fields, "presence")))
		case ("state", .device):
			let fields = try Fields(body, part: "relay state", keys: ["id", "item"])
			return .state(RelayStateItem(id: try itemID(fields, "id"), item: try item(fields, "item")))
		case ("taken", .mac), ("taken", .device):
			let fields = try Fields(body, part: "relay taken", keys: ["count"])
			let taken = try count(fields, "count")
			guard taken <= RelayLimits.maxTaken else { throw RemoteKitError(fields.part, "count is too large") }
			return .taken(count: taken)
		case ("mail", .mac), ("mail", .device), ("mail", .joining):
			_ = try Fields(body, part: "relay mail", keys: [])
			return .mail
		case ("online", .mac):
			return .online(try deviceID(try Fields(body, part: "relay online", keys: ["device"]), "device"))
		case ("offline", .mac):
			return .offline(try deviceID(try Fields(body, part: "relay offline", keys: ["device"]), "device"))
		case ("left", .mac):
			return .left(try deviceID(try Fields(body, part: "relay left", keys: ["device"]), "device"))
		case ("anotherMac", .mac):
			_ = try Fields(body, part: "relay anotherMac", keys: [])
			return .anotherMac
		case ("held", .mac):
			let fields = try Fields(body, part: "relay held", keys: ["device", "until"])
			return .held(try deviceID(fields, "device"), until: try time(fields, "until"))
		case ("mac", .device), ("mac", .joining):
			let fields = try Fields(body, part: "relay mac", keys: ["online"])
			return .macOnline(try bool(fields, "online"))
		default:
			throw RemoteKitError(part, "not a message this end is sent")
		}
	}

	private static func pairing(_ fields: Fields, _ key: String) throws -> PairingID {
		guard let id = PairingID(try fields.string(key)) else { throw RemoteKitError(fields.part, "\(key) is not a pairing's id") }
		return id
	}

	private static func deviceID(_ fields: Fields, _ key: String) throws -> DeviceID {
		guard let id = DeviceID(try fields.string(key)) else { throw RemoteKitError(fields.part, "\(key) is not a device's id") }
		return id
	}

	private static func itemID(_ fields: Fields, _ key: String) throws -> ItemID {
		guard let id = ItemID(try fields.string(key)) else { throw RemoteKitError(fields.part, "\(key) is not an item's id") }
		return id
	}

	private static func bool(_ fields: Fields, _ key: String) throws -> Bool {
		guard let flag = fields.value(key)?.boolValue else { throw RemoteKitError(fields.part, "\(key) is not true or false") }
		return flag
	}

	private static func count(_ fields: Fields, _ key: String) throws -> Int {
		let number = try fields.integer(key)
		guard number >= 0, number <= Int64(Int32.max) else { throw RemoteKitError(fields.part, "\(key) is not a count") }
		return Int(number)
	}

	private static func time(_ fields: Fields, _ key: String) throws -> Int64 {
		let number = try fields.integer(key)
		guard number > 0, number <= RelayLimits.maxTime else { throw RemoteKitError(fields.part, "\(key) is not a time") }
		return number
	}

	private static func item(_ fields: Fields, _ key: String) throws -> Data {
		let bytes = try fields.bytes(key, maxCount: RelayLimits.maxItem)
		guard bytes.count >= RelayLimits.minItem, bytes.first == 0x04 else { throw RemoteKitError(fields.part, "\(key) is not a sealed item") }
		return bytes
	}

	private static func why(_ fields: Fields) throws -> RelayWhy {
		guard let why = RelayWhy(word: try fields.string("why", maxLength: 32)) else { throw RemoteKitError(fields.part, "why is not a word") }
		return why
	}

	private static func kind(_ fields: Fields, for end: RelayEnd) throws -> RelayRequestKind {
		guard let kind = RelayRequestKind(rawValue: try fields.string("what", maxLength: 32)) else {
			throw RemoteKitError(fields.part, "what is not a request")
		}
		// A phone sends only its own requests; the Mac sends no `token`.
		let mine: Bool
		switch kind {
		case .openJoin, .closeJoin, .addDevice, .removeDevice, .deletePairing, .state: mine = end == .mac
		case .token: mine = end == .device
		case .put, .take: mine = true
		}
		guard mine else { throw RemoteKitError(fields.part, "what is not a request this end sends") }
		return kind
	}
}

/// One text message to the relay, written exactly as the relay reads it: one JSON object with one member, named for the
/// message, compact, as `JSON.stringify` writes it.
public enum RelayOutgoing: Sendable {
	case register(build: RelayBuild, relayKey: P256.Signing.PublicKey)
	case hello(pairing: PairingID, device: DeviceID?, role: RelayHelloRole, build: RelayBuild)
	case proof(signature: Data)
	case join(pairing: PairingID, deviceKey: P256.Signing.PublicKey, attestation: Data, keyId: AttestKeyID, token: Data)
	case openJoin(tokenHash: Data, expires: Int64)
	case closeJoin
	case addDevice(DeviceID, deviceKey: P256.Signing.PublicKey, attestKeyId: AttestKeyID)
	case removeDevice(DeviceID)
	case deletePairing
	case state(device: DeviceID, id: ItemID, item: Data)
	case put(to: RelayAddress, id: ItemID, item: Data, presence: Bool)
	case take
	case token(apns: String, environment: RelayPushEnvironment)
	case leave(signature: Data)
	case ping

	public var text: String {
		JSON.text(.object([(name, .object(body))]))
	}

	var name: String {
		switch self {
		case .register: "register"
		case .hello: "hello"
		case .proof: "proof"
		case .join: "join"
		case .openJoin: "openJoin"
		case .closeJoin: "closeJoin"
		case .addDevice: "addDevice"
		case .removeDevice: "removeDevice"
		case .deletePairing: "deletePairing"
		case .state: "state"
		case .put: "put"
		case .take: "take"
		case .token: "token"
		case .leave: "leave"
		case .ping: "ping"
		}
	}

	private var body: [(String, JSONValue)] {
		switch self {
		case let .register(build, relayKey):
			return [("v", .integer(1)), ("build", .string(build.text)), ("relayKey", .string(PublicKeys.text(relayKey)))]
		case let .hello(pairing, device, role, build):
			var body: [(String, JSONValue)] = [("v", .integer(1)), ("role", .string(role.rawValue)), ("pairing", .string(pairing.text))]
			if let device { body.append(("device", .string(device.text))) }
			body.append(("build", .string(build.text)))
			return body
		case let .proof(signature), let .leave(signature):
			return [("signature", .string(Base64URL.encode(signature)))]
		case let .join(pairing, deviceKey, attestation, keyId, token):
			return [
				("pairing", .string(pairing.text)), ("deviceKey", .string(PublicKeys.text(deviceKey))),
				("attestation", .string(Base64URL.encode(attestation))), ("keyId", .string(keyId.text)), ("token", .string(Base64URL.encode(token))),
			]
		case let .openJoin(tokenHash, expires):
			return [("tokenHash", .string(Base64URL.encode(tokenHash))), ("expires", .integer(expires))]
		case .closeJoin, .deletePairing, .take, .ping:
			return []
		case let .addDevice(device, deviceKey, attestKeyId):
			return [("device", .string(device.text)), ("deviceKey", .string(PublicKeys.text(deviceKey))), ("attestKeyId", .string(attestKeyId.text))]
		case let .removeDevice(device):
			return [("device", .string(device.text))]
		case let .state(device, id, item):
			return [("device", .string(device.text)), ("id", .string(id.text)), ("item", .string(Base64URL.encode(item)))]
		case let .put(to, id, item, presence):
			var body: [(String, JSONValue)] = [("to", .string(to.text)), ("id", .string(id.text)), ("item", .string(Base64URL.encode(item)))]
			// The flag is left out rather than written false: the relay takes only `true` for it.
			if presence { body.append(("presence", .bool(true))) }
			return body
		case let .token(apns, environment):
			return [("apns", .string(apns)), ("environment", .string(environment.rawValue))]
		}
	}

	/// Checks what the relay would refuse before it is sent, so that a caller's mistake is not a refusal that closes the
	/// socket.
	public func validate() throws {
		let part = "relay \(name)"
		switch self {
		case let .proof(signature), let .leave(signature):
			guard signature.count == SignedStatement.signatureLength else { throw RemoteKitError(part, "a signature is not 64 bytes") }
		case let .join(_, _, attestation, _, token):
			guard !attestation.isEmpty, attestation.count <= RelayLimits.maxAttestation else { throw RemoteKitError(part, "an attestation of a wrong size") }
			guard token.count == 32 else { throw RemoteKitError(part, "a token is not 32 bytes") }
		case let .openJoin(tokenHash, expires):
			guard tokenHash.count == 32 else { throw RemoteKitError(part, "a token hash is not 32 bytes") }
			guard expires > 0, expires <= JSON.maxSafeInteger else { throw RemoteKitError(part, "expires is not a time") }
		case let .state(_, _, item), let .put(_, _, item, _):
			guard item.count >= RelayLimits.minItem, item.count <= RelayLimits.maxItem, item.first == 0x04 else {
				throw RemoteKitError(part, "not a sealed item")
			}
		case let .token(apns, _):
			let bytes = Array(apns.utf8)
			let hex = bytes.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
			guard hex, bytes.count % 2 == 0, (64...200).contains(bytes.count) else { throw RemoteKitError(part, "not a push token") }
		default:
			break
		}
		guard text.utf8.count <= RelayLimits.maxText else { throw RemoteKitError(part, "too long") }
	}
}

public enum RelayHelloRole: String, Sendable {
	case mac
	case device
}

public enum RelayPushEnvironment: String, Sendable {
	case development
	case production
}

/// What an end signs to prove itself at the relay, and to leave (relay/README.md, "Proving"): the UTF-8 bytes of
/// `pi2-relay-v1`, then, each after a zero byte, what it proves, the pairing's id (empty at `register`), the device's
/// id (empty for a Mac) and the challenge as base64url.
///
/// The label is what keeps the device key's signature here from being taken for a statement of another kind: every
/// other text the device key signs is a JSON object (`pair`, `attach`, requests), which cannot begin with `pi2-relay-v1`.
/// The client also signs only a challenge of exactly 32 bytes.
public enum RelayProof {
	public enum Purpose: String, Sendable {
		case register, mac, device, leave
	}

	public static func text(_ purpose: Purpose, pairing: PairingID?, device: DeviceID?, challenge: Data) throws -> Data {
		guard challenge.count == 32 else { throw RemoteKitError("relay proof", "a challenge is not 32 bytes") }
		let parts = ["pi2-relay-v1", purpose.rawValue, pairing?.text ?? "", device?.text ?? "", Base64URL.encode(challenge)]
		return Data(parts.joined(separator: "\u{0}").utf8)
	}
}
