import CryptoKit
import Foundation

// Sealed items (iphone.md 5.3): what waits in the relay's mailbox, sealed for its one reader with HPKE (RFC 9180) in
// its authenticated mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM, as CryptoKit provides it. The writer
// authenticates with its record key; HPKE's `info` is "pi2-item-v2", the pairing, the reader and the item's id, each
// after a zero byte, so an item cannot be moved and still open. Inside the seal, every item is also signed by its
// writer (the Mac's identity key, or the phone's device key), since HPKE's sender authentication does not hold against
// someone with the reader's private key. A sealed push (`PushSealing`) is sealed as a Mac item is, but its `info`
// begins "pi2-push-v1" in place of "pi2-item-v2" (`SealLabel`, #937): a push's bytes open as no mailbox item, nor a
// mailbox item's as a push.
//
// An item's bytes are HPKE's encapsulated key (65 bytes, an uncompressed P-256 point) and then the ciphertext.
//
// CryptoKit's HPKE takes a Secure Enclave key as a reader's or a writer's private key
// (SecureEnclave.P256.KeyAgreement.PrivateKey conforms to HPKEDiffieHellmanPrivateKey from iOS 17 and macOS 14), so a
// record key may live there (3.2): `seal` and `open` take any such key.

/// Who an item is for.
public enum ItemReader: Hashable, Sendable {
	case mac
	case device(DeviceID)

	public var text: String {
		switch self {
		case .mac: "mac"
		case let .device(id): id.text
		}
	}
}

/// What HPKE's `info` begins with: what the sealed bytes are. A mailbox item's (`pi2-item-v2`, as it has been since
/// v2) and a sealed push's (`pi2-push-v1`, #937) are apart, so that neither opens as the other: the same pairing,
/// reader and id give two different `info`s. Only `PushSealing` seals and opens with `push`.
@_spi(Vectors)
public enum SealLabel: String, Sendable, CaseIterable {
	case item = "pi2-item-v2"
	case push = "pi2-push-v1"
}

/// Where an item is going: what HPKE's `info` binds it to.
public struct ItemAddress: Hashable, Sendable {
	public let pairing: PairingID
	public let reader: ItemReader
	public let id: ItemID

	public init(pairing: PairingID, reader: ItemReader, id: ItemID) {
		self.pairing = pairing
		self.reader = reader
		self.id = id
	}

	/// The label, then a zero byte before each of the pairing's id, the reader and the item's id, as text.
	@_spi(Vectors)
	public func info(_ label: SealLabel) -> Data {
		var info = Data(label.rawValue.utf8)
		for part in [pairing.text, reader.text, id.text] {
			info.append(0)
			info.append(Data(part.utf8))
		}
		return info
	}
}

public enum SealedItem {
	/// The relay takes no item longer (5.3).
	public static let maxLength = 16 * 1024
	public static let encapsulatedKeyLength = 65
	public static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

	/// Seals `plaintext` for the reader whose record key is `readerKey`, authenticated by the writer's record key.
	public static func seal<Key: HPKEDiffieHellmanPrivateKey>(
		_ plaintext: Data, to address: ItemAddress, readerKey: P256.KeyAgreement.PublicKey, writerKey: Key
	) throws -> Data where Key.PublicKey == P256.KeyAgreement.PublicKey {
		try seal(plaintext, to: address, label: .item, readerKey: readerKey, writerKey: writerKey)
	}

	/// As `seal`, under `label`: `PushSealing`'s with `push`, and the checks'.
	@_spi(Vectors)
	public static func seal<Key: HPKEDiffieHellmanPrivateKey>(
		_ plaintext: Data, to address: ItemAddress, label: SealLabel, readerKey: P256.KeyAgreement.PublicKey, writerKey: Key
	) throws -> Data where Key.PublicKey == P256.KeyAgreement.PublicKey {
		let item: Data
		do {
			var sender = try HPKE.Sender(recipientKey: readerKey, ciphersuite: ciphersuite, info: address.info(label), authenticatedBy: writerKey)
			item = sender.encapsulatedKey + (try sender.seal(plaintext))
		} catch {
			throw RemoteKitError("sealed item", "could not seal")
		}
		guard item.count <= maxLength else { throw RemoteKitError("sealed item", "too long for the mailbox") }
		return item
	}

	/// Opens an item sealed for `address` by the writer whose record key is `writerKey`, without reading or verifying
	/// what it holds: for the checks only. Everyone else opens with `openRequest` or `openMacItem`, which give nothing
	/// unverified. A mailbox item's label unless `label` says otherwise.
	@_spi(Vectors)
	public static func open<Key: HPKEDiffieHellmanPrivateKey>(
		_ item: Data, at address: ItemAddress, label: SealLabel = .item, readerKey: Key, writerKey: P256.KeyAgreement.PublicKey
	) throws -> Data where Key.PublicKey == P256.KeyAgreement.PublicKey {
		guard item.count <= maxLength else { throw RemoteKitError("sealed item", "too long") }
		guard item.count >= encapsulatedKeyLength + 16 else { throw RemoteKitError("sealed item", "too short") }
		let start = item.startIndex
		let encapsulated = Data(item[start..<(start + encapsulatedKeyLength)])
		guard encapsulated.first == 0x04 else { throw RemoteKitError("sealed item", "not an uncompressed P-256 point") }
		do {
			var recipient = try HPKE.Recipient(
				privateKey: readerKey, ciphersuite: ciphersuite, info: address.info(label), encapsulatedKey: encapsulated, authenticatedBy: writerKey)
			return try recipient.open(Data(item[(start + encapsulatedKeyLength)...]))
		} catch {
			throw RemoteKitError("sealed item", "does not open for this reader, writer and address")
		}
	}
}

extension SealedItem {
	/// Opens a request the phone left in the Mac's mailbox, reads it and checks it, in one call, so that nothing acts on
	/// one that is not verified: sealed for this address by the device's record key, signed by its device key, for this
	/// pairing, from the device the relay says wrote it, with the item's own id as its nonce, and signed by its presence
	/// key too, which every item for the Mac must be (4.3). How old it may be (an hour for a `"face"` request, a day for
	/// any other) and whether its nonce was seen are the engine's.
	public static func openRequest<Key: HPKEDiffieHellmanPrivateKey>(
		_ item: Data, at address: ItemAddress, readerKey: Key, writer: DeviceID, writerRecordKey: P256.KeyAgreement.PublicKey,
		deviceKey: P256.Signing.PublicKey, presenceKey: P256.Signing.PublicKey
	) throws -> RequestItem where Key.PublicKey == P256.KeyAgreement.PublicKey {
		let request = try RequestItem.read(try open(item, at: address, readerKey: readerKey, writerKey: writerRecordKey))
		try request.verify(deviceKey: deviceKey, presenceKey: presenceKey, writer: writer, address: address)
		return request
	}

	/// Opens an item the Mac left for this device, reads it and checks it, in one call: sealed for this address by the
	/// Mac's record key, signed by its identity key, for this pairing and device, with the item's own id as its nonce.
	/// Whether a state is newer than the one shown is `StateNumbers`'.
	///
	/// A mailbox item's label alone: a sealed push opens here never, since it is sealed under the push's (#937). Behind
	/// the label, a second line: a Mac item of a push's kind (`push`, `pushGone`) is refused here too, as `PushSealing.open`
	/// refuses every other kind, so that the two keep apart even if a label were ever shared again.
	public static func openMacItem<Key: HPKEDiffieHellmanPrivateKey>(
		_ item: Data, at address: ItemAddress, readerKey: Key, writerRecordKey: P256.KeyAgreement.PublicKey, identityKey: P256.Signing.PublicKey
	) throws -> MacItem where Key.PublicKey == P256.KeyAgreement.PublicKey {
		let macItem = try openMacItem(item, at: address, label: .item, readerKey: readerKey, writerRecordKey: writerRecordKey, identityKey: identityKey)
		guard PushSealing.Kind(itemKind: macItem.kind) == nil else { throw RemoteKitError("mac item", "a push's kind, never a mailbox item's") }
		return macItem
	}

	/// As `openMacItem`, under `label`: `PushSealing.open`'s with `push`, which checks the kind itself.
	static func openMacItem<Key: HPKEDiffieHellmanPrivateKey>(
		_ item: Data, at address: ItemAddress, label: SealLabel, readerKey: Key, writerRecordKey: P256.KeyAgreement.PublicKey, identityKey: P256.Signing.PublicKey
	) throws -> MacItem where Key.PublicKey == P256.KeyAgreement.PublicKey {
		let macItem = try MacItem.read(try open(item, at: address, label: label, readerKey: readerKey, writerKey: writerRecordKey))
		try macItem.verify(identityKey: identityKey, address: address)
		return macItem
	}
}

/// A request the phone leaves in the Mac's mailbox (4.3, 5.3): `{"v":2,"request":{"method":…,"params":…},"signed":…,
/// "signature":…,"presence":…}`, `signed` being `{"v":2,"kind":"request","pairing":…,"device":…,"method":…,"params":…,
/// "nonce":<the item's id>,"at":…}`, signed by the device key, and `presence` the presence key's signature over the same
/// text. Every request item carries both signatures: one without `presence` can be neither written nor read (4.3).
/// `request` must say what `signed` says.
public struct RequestItem: Sendable {
	public let statement: SignedStatement
	public let presence: Data
	public let method: String
	public let params: JSONValue
	public let pairing: PairingID
	public let device: DeviceID
	public let nonce: ItemID
	/// The phone's clock when it signed, in milliseconds since 1970.
	public let at: Int64

	public static func make(
		method: String, params: JSONValue, pairing: PairingID, device: DeviceID, id: ItemID, at date: Date = Date(),
		deviceKey: some StatementSigner, presenceKey: some StatementSigner
	) throws -> RequestItem {
		let signed = JSONValue.object([
			("v", .integer(2)), ("kind", .string("request")), ("pairing", .string(pairing.text)), ("device", .string(device.text)),
			("method", .string(method)), ("params", params), ("nonce", .string(id.text)),
			("at", .integer(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
		])
		let statement = try SignedStatement.make(signed, signer: deviceKey)
		let presence: Data
		do {
			presence = try presenceKey.sign(Data(statement.text.utf8))
		} catch {
			throw RemoteKitError("request item", "the presence key could not sign")
		}
		return try RequestItem(statement: statement, presence: presence)
	}

	private init(statement: SignedStatement, presence: Data) throws {
		let part = "request item"
		let fields = try Fields(statement.value, part: part, keys: ["v", "kind", "pairing", "device", "method", "params", "nonce", "at"])
		try fields.version()
		guard try fields.string("kind").sameBytes("request") else { throw RemoteKitError(part, "not a request") }
		guard let pairing = PairingID(try fields.string("pairing")) else { throw RemoteKitError(part, "pairing is not a pairing's id") }
		guard let device = DeviceID(try fields.string("device")) else { throw RemoteKitError(part, "device is not a device's id") }
		guard let nonce = ItemID(try fields.string("nonce")) else { throw RemoteKitError(part, "nonce is not an item's id") }
		if presence.count != SignedStatement.signatureLength { throw RemoteKitError(part, "a presence signature of the wrong length") }
		self.statement = statement
		self.presence = presence
		method = try fields.nonEmpty("method", maxLength: 128)
		params = fields.value("params")!
		self.pairing = pairing
		self.device = device
		self.nonce = nonce
		at = try fields.integer("at")
	}

	public var plaintext: Data {
		var members: [(String, JSONValue)] = [
			("v", .integer(2)), ("request", .object([("method", .string(method)), ("params", params)])),
			("signed", .string(statement.text)), ("signature", .string(statement.signatureText)),
		]
		members.append(("presence", .string(Base64URL.encode(presence))))
		return JSON.write(.object(members))
	}

	@_spi(Vectors)
	public static func read(_ plaintext: Data) throws -> RequestItem {
		let part = "request item"
		let value: JSONValue
		do {
			value = try JSON.parse(plaintext)
		} catch {
			throw RemoteKitError(part, "not JSON as RemoteKit reads it")
		}
		// `presence` is required: a request item without the presence signature is refused (4.3).
		let fields = try Fields(value, part: part, keys: ["v", "request", "signed", "signature", "presence"])
		try fields.version()
		let presence = try fields.bytes("presence", count: SignedStatement.signatureLength)
		let item = try RequestItem(
			statement: try SignedStatement.read(text: fields.value("signed"), signature: fields.value("signature"), part: part), presence: presence)
		let request = try Fields(fields.value("request")!, part: part, keys: ["method", "params"])
		guard try request.string("method", maxLength: 128).sameBytes(item.method), request.value("params")! == item.params else {
			throw RemoteKitError(part, "request does not say what signed says")
		}
		return item
	}

	/// The check whoever opens the item makes: the writer's device key signed it, for this pairing, as the device the
	/// relay says wrote it, with the item's own id as its nonce, and its presence key signed the same text. How old `at`
	/// may be, and whether the nonce was seen, are the engine's (4.3).
	@_spi(Vectors)
	public func verify(deviceKey: P256.Signing.PublicKey, presenceKey: P256.Signing.PublicKey, writer: DeviceID, address: ItemAddress) throws {
		let part = "request item"
		guard statement.isSigned(by: deviceKey) else { throw RemoteKitError(part, "not signed by the device key") }
		guard pairing == address.pairing, address.reader == .mac else { throw RemoteKitError(part, "for another pairing or reader") }
		guard device == writer else { throw RemoteKitError(part, "from another device") }
		guard nonce == address.id else { throw RemoteKitError(part, "its nonce is not the item's id") }
		guard SignedStatement.verify(presence, over: Data(statement.text.utf8), by: presenceKey) else {
			throw RemoteKitError(part, "no valid presence signature")
		}
	}
}

/// What the Mac leaves for a device (5.3): a state, a receipt, a revocation notice and the like. `{"v":2,"signed":…,
/// "signature":…}`, `signed` being `{"v":2,"kind":…,"pairing":…,"device":…,"nonce":<the item's id>,"at":…,"body":…}`, with
/// `"number"` before `body` in a state, signed by the Mac's identity key.
public struct MacItem: Sendable {
	/// Kinds a Mac item may not have, since statements of theirs are signed elsewhere: the Mac's proof, and the device
	/// key's `pair`, `attach`, `request` and `leave` (the leave text for the Mac, `RelayLeaveNotice`, #813).
	static let reservedKinds = ["mac", "pair", "attach", "request", "leave"]

	public let statement: SignedStatement
	/// `state`, `receipt`, `revoked`, or another kind the issue that needs it names: a lower-case letter, then up to 31
	/// letters.
	public let kind: String
	/// A state's number, which only rises (5.3). Only a state has one, and every state has one.
	public let number: Int64?
	public let body: JSONValue
	public let pairing: PairingID
	public let device: DeviceID
	public let nonce: ItemID
	public let at: Int64

	public static func make(
		kind: String, number: Int64? = nil, body: JSONValue, pairing: PairingID, device: DeviceID, id: ItemID, at date: Date = Date(),
		identity: some StatementSigner
	) throws -> MacItem {
		var members: [(String, JSONValue)] = [
			("v", .integer(2)), ("kind", .string(kind)), ("pairing", .string(pairing.text)), ("device", .string(device.text)),
			("nonce", .string(id.text)), ("at", .integer(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
		]
		if let number { members.append(("number", .integer(number))) }
		members.append(("body", body))
		return try MacItem(statement: try SignedStatement.make(.object(members), signer: identity))
	}

	private init(statement: SignedStatement) throws {
		let part = "mac item"
		let fields = try Fields(statement.value, part: part, keys: ["v", "kind", "pairing", "device", "nonce", "at", "body"], optional: ["number"])
		try fields.version()
		let kind = try fields.string("kind", maxLength: 32)
		let letters = Array(kind.utf8)
		guard let first = letters.first, first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z"),
			letters.allSatisfy({ ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) }),
			!Self.reservedKinds.contains(where: { $0.sameBytes(kind) })
		else { throw RemoteKitError(part, "kind is not a Mac item's kind") }
		var number: Int64?
		if fields.value("number") != nil {
			number = try fields.integer("number")
			guard number! >= 0 else { throw RemoteKitError(part, "number is not a state's number") }
		}
		guard (number != nil) == kind.sameBytes("state") else { throw RemoteKitError(part, "a state without its number, or a number on another kind") }
		guard let pairing = PairingID(try fields.string("pairing")) else { throw RemoteKitError(part, "pairing is not a pairing's id") }
		guard let device = DeviceID(try fields.string("device")) else { throw RemoteKitError(part, "device is not a device's id") }
		guard let nonce = ItemID(try fields.string("nonce")) else { throw RemoteKitError(part, "nonce is not an item's id") }
		self.statement = statement
		self.kind = kind
		self.number = number
		body = fields.value("body")!
		self.pairing = pairing
		self.device = device
		self.nonce = nonce
		at = try fields.integer("at")
	}

	public var plaintext: Data {
		JSON.write(.object([("v", .integer(2)), ("signed", .string(statement.text)), ("signature", .string(statement.signatureText))]))
	}

	@_spi(Vectors)
	public static func read(_ plaintext: Data) throws -> MacItem {
		let part = "mac item"
		let value: JSONValue
		do {
			value = try JSON.parse(plaintext)
		} catch {
			throw RemoteKitError(part, "not JSON as RemoteKit reads it")
		}
		let fields = try Fields(value, part: part, keys: ["v", "signed", "signature"])
		try fields.version()
		return try MacItem(statement: try SignedStatement.read(text: fields.value("signed"), signature: fields.value("signature"), part: part))
	}

	/// The phone's check: its Mac's identity key signed this item, for this pairing and device, with the item's own id.
	@_spi(Vectors)
	public func verify(identityKey: P256.Signing.PublicKey, address: ItemAddress) throws {
		let part = "mac item"
		guard statement.isSigned(by: identityKey) else { throw RemoteKitError(part, "not signed by the Mac's identity key") }
		guard pairing == address.pairing, address.reader == .device(device) else { throw RemoteKitError(part, "for another pairing or device") }
		guard nonce == address.id else { throw RemoteKitError(part, "its nonce is not the item's id") }
	}
}

/// The highest state number the phone has shown (5.3): it refuses a state older than one it has shown, so a relay
/// cannot hand back an old one. The phone keeps `shown` in its store (P23).
public struct StateNumbers: Sendable, Equatable {
	public enum Verdict: Sendable { case newer, same, older }

	public private(set) var shown: Int64?

	public init(shown: Int64? = nil) {
		self.shown = shown
	}

	/// Takes a state's number: a newer one becomes the one shown; the same one again is nothing new; an older one is refused.
	public mutating func take(_ number: Int64) -> Verdict {
		guard let shown else {
			self.shown = number
			return .newer
		}
		if number > shown {
			self.shown = number
			return .newer
		}
		return number == shown ? .same : .older
	}
}
