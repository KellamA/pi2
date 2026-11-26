
import CryptoKit
import Foundation

// A push's content, sealed for its one device (iphone.md 7 and 7.1; #689): what pi² Remote writes into a push's one
// custom key, `sealed`, and what the phone's notification service extension opens. The relay and Apple see its size,
// one of three, and nothing else of it.
//
// The bytes are a sealed item as `SealedItem` seals one for the mailbox (HPKE's encapsulated key first, as the relay
// checks: `sealed[0] == 0x04`), but under the push's own label, `info` beginning "pi2-push-v1" where a mailbox item's
// begins "pi2-item-v2" (#937), so that a push opens as no mailbox item and no mailbox item as a push; then the item's
// 16-byte id, which HPKE's `info` binds it to and which the push has nowhere else to carry. Inside, a Mac item (`MacItem`, signed by the Mac's identity key, for this pairing, device and
// id) of kind `push` for an alert or `pushGone` for a background push, whose body is
// `{"body":<the engine's body, as it wrote it>,"pad":"000…"}`: the padding inside the signature, so that nothing
// outside it can be changed unseen, and the engine's own body untouched beside it. The whole is exactly 696, 1,464 or
// 3,000 bytes, the smallest that holds it, and for an alert never less than 1,464, so that a push's size says no more
// than its class and an alert's does not tell a one-line card from a longer one. One that does not fit the largest is
// refused, never cut.
//
// The collapse id the relay passes to Apple is an HMAC of the item's own id (`need:n12`), keyed per pairing and per
// device, so that neither the relay nor Apple learns the id, nor ties two devices' pushes about one item together.

public enum PushSealing {
	/// What a sealed push is: an alert the extension shows, or a background push that takes notifications away.
	public enum Kind: String, Sendable, CaseIterable {
		case alert, background

		/// The kind of the Mac item inside the seal.
		public var itemKind: String {
			switch self {
			case .alert: "push"
			case .background: "pushGone"
			}
		}

		/// The smallest size a push of this kind is padded to: an alert never less than the middle size, so that its size
		/// does not tell a one-line card from a longer one; a background push the smallest.
		public var smallest: Int {
			switch self {
			case .alert: PushSealing.sizes[1]
			case .background: PushSealing.sizes[0]
			}
		}

		init?(itemKind: String) {
			guard let kind = Self.allCases.first(where: { $0.itemKind.sameBytes(itemKind) }) else { return nil }
			self = kind
		}
	}

	/// The sizes a sealed push may have, in bytes (relay/README.md, "Pushes"; `SEALED_SIZES` in relay/src/apns.ts).
	public static let sizes = [696, 1_464, 3_000]
	/// The item's id, after the sealed item.
	public static let idLength = 16
	/// What sealing adds to the Mac item's text: HPKE's encapsulated key and AES-GCM's tag, and the id after them.
	public static let overhead = SealedItem.encapsulatedKeyLength + 16 + idLength
	/// What the padding is made of: one byte JSON writes as itself.
	static let padCharacter: Character = "0"

	/// The body does not fit the largest size: refused, never cut.
	public static let tooLarge = RemoteKitError("sealed push", "too large for the largest push")

	/// Seals the engine's `body` for `device`: a Mac item of `kind`, signed by `identity`, sealed to the device's record
	/// key with the Mac's, padded to the smallest of `sizes` that holds it and is at least `kind.smallest`. Throws
	/// `tooLarge` if none does.
	public static func seal<Key: HPKEDiffieHellmanPrivateKey>(
		_ body: JSONValue, kind: Kind, pairing: PairingID, device: DeviceID, deviceRecordKey: P256.KeyAgreement.PublicKey, recordKey: Key,
		identity: some StatementSigner, id: ItemID = .random(), at date: Date = Date()
	) throws -> Data where Key.PublicKey == P256.KeyAgreement.PublicKey {
		func item(pad: Int) throws -> MacItem {
			try MacItem.make(
				kind: kind.itemKind, body: .object([("body", body), ("pad", .string(String(repeating: padCharacter, count: pad)))]),
				pairing: pairing, device: device, id: id, at: date, identity: identity)
		}
		// The signature is always 64 bytes, and the padding is written as itself, so the text grows by exactly the padding.
		let bare = try item(pad: 0).plaintext.count
		guard let size = sizes.first(where: { bare + overhead <= $0 && $0 >= kind.smallest }) else { throw tooLarge }
		let plaintext = try item(pad: size - overhead - bare).plaintext
		guard plaintext.count == size - overhead else { throw RemoteKitError("sealed push", "could not be padded") }
		let sealed = try SealedItem.seal(
			plaintext, to: ItemAddress(pairing: pairing, reader: .device(device), id: id), label: .push, readerKey: deviceRecordKey, writerKey: recordKey)
		guard let idBytes = Base64URL.decode(id.text, count: idLength) else { throw RemoteKitError("sealed push", "not an item's id") }
		let whole = sealed + idBytes
		guard whole.count == size else { throw RemoteKitError("sealed push", "not of a push's size") }
		return whole
	}

	/// A sealed push, opened and verified.
	public struct Opened: Sendable {
		public let kind: Kind
		/// The item's id, which names it once (the phone remembers it, so that one handed back is refused).
		public let id: ItemID
		/// When the Mac signed it, in milliseconds since 1970 by its clock.
		public let at: Int64
		/// The engine's body, as it wrote it.
		public let body: JSONValue
	}

	/// Opens a sealed push as the phone does, and gives nothing back unless all of it holds: one of `sizes`, sealed for
	/// this device of this pairing and this id by the Mac's record key under the push's label, signed by its identity key,
	/// a push's kind, and its body exactly `{"body":…,"pad":"000…"}`.
	public static func open<Key: HPKEDiffieHellmanPrivateKey>(
		_ sealed: Data, pairing: PairingID, device: DeviceID, recordKey: Key, macRecordKey: P256.KeyAgreement.PublicKey, identityKey: P256.Signing.PublicKey
	) throws -> Opened where Key.PublicKey == P256.KeyAgreement.PublicKey {
		let part = "sealed push"
		guard sizes.contains(sealed.count) else { throw RemoteKitError(part, "not of a push's size") }
		let split = sealed.endIndex - idLength
		guard let id = ItemID(Base64URL.encode(sealed[split...])) else { throw RemoteKitError(part, "not an item's id") }
		let item = try SealedItem.openMacItem(
			Data(sealed[sealed.startIndex..<split]), at: ItemAddress(pairing: pairing, reader: .device(device), id: id), label: .push,
			readerKey: recordKey, writerRecordKey: macRecordKey, identityKey: identityKey)
		guard let kind = Kind(itemKind: item.kind) else { throw RemoteKitError(part, "not a push") }
		let fields = try Fields(item.body, part: part, keys: ["body", "pad"])
		let pad = try fields.string("pad", maxLength: sizes.last!)
		guard pad.allSatisfy({ $0 == padCharacter }) else { throw RemoteKitError(part, "padding that is not padding") }
		return Opened(kind: kind, id: id, at: item.at, body: fields.value("body")!)
	}

	// MARK: The collapse id

	/// The longest item id the engine names a push's subject by (`need:n12`, `limit:<id>`, `answer:<id>`).
	public static let maxCollapseSource = 256

	/// The relay's `collapse` for the item the engine calls `subject`: HMAC-SHA256 of it, keyed with a key of this pairing
	/// and this device alone, 32 bytes. The key is made from the agreement of the Mac's record key with the device's
	/// (HKDF-SHA256, salt `pi2-collapse-v1`, info the pairing's and the device's ids, each after a zero byte): no relay
	/// and no other device can make it, it needs nothing kept beside the keys, and a record key in the Secure Enclave
	/// makes it there. So the relay never sees the item's id, and one item's pushes to two devices share no collapse id.
	public static func collapse<Key: HPKEDiffieHellmanPrivateKey>(
		_ subject: String, pairing: PairingID, device: DeviceID, recordKey: Key, deviceRecordKey: P256.KeyAgreement.PublicKey
	) throws -> Data where Key.PublicKey == P256.KeyAgreement.PublicKey {
		guard !subject.isEmpty, subject.utf8.count <= maxCollapseSource else { throw RemoteKitError("collapse id", "not an item's id") }
		let secret: SharedSecret
		do {
			secret = try recordKey.sharedSecretFromKeyAgreement(with: deviceRecordKey)
		} catch {
			throw RemoteKitError("collapse id", "the record keys do not agree")
		}
		var info = Data()
		for part in [pairing.text, device.text] {
			info.append(0)
			info.append(Data(part.utf8))
		}
		let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("pi2-collapse-v1".utf8), sharedInfo: info, outputByteCount: 32)
		return Data(HMAC<SHA256>.authenticationCode(for: Data(subject.utf8), using: key))
	}
}

// MARK: Live Activities

/// A Live Activity's numbers, exactly what a Live Activity push carries (iphone.md 7; relay/README.md, "Live
/// Activities"): the system reads them, so they are never sealed, and nothing but these four goes with them.
public struct ActivityNumbers: Equatable, Sendable {
	/// The largest count the relay takes.
	public static let maxCount: Int64 = 99_999

	public let working: Int64
	public let needs: Int64
	public let finished: Int64
	/// When the engine counted them, in milliseconds since 1970.
	public let at: Int64

	/// Nil unless each count is a whole number from 0 to 99,999 and `at` a time.
	public init?(working: Int64, needs: Int64, finished: Int64, at: Int64) {
		guard [working, needs, finished].allSatisfy({ (0...Self.maxCount).contains($0) }), at > 0, at <= RelayLimits.maxTime else { return nil }
		self.working = working
		self.needs = needs
		self.finished = finished
		self.at = at
	}

	/// Read strictly: exactly the four members, each a whole number in its range.
	public init?(json: JSONValue) {
		guard let keys = json.keys, keys.count == 4, Set(keys) == ["working", "needs", "finished", "at"],
		      let working = json["working"]?.integerValue, let needs = json["needs"]?.integerValue,
		      let finished = json["finished"]?.integerValue, let at = json["at"]?.integerValue
		else { return nil }
		self.init(working: working, needs: needs, finished: finished, at: at)
	}

	public var json: JSONValue {
		.object([("working", .integer(working)), ("needs", .integer(needs)), ("finished", .integer(finished)), ("at", .integer(at))])
	}
}

/// What a Live Activity push does: brings new numbers, or ends the activity with its last.
public enum ActivityEvent: String, Sendable, CaseIterable {
	case update, end
}

/// A push the Mac asks the relay for (relay/README.md, "Pushes", "Live Activities"), each for one device.
public enum RelayPush: Equatable, Sendable {
	/// An alert or a background push: its sealed bytes (`PushSealing`), and for an alert its collapse id, 32 bytes.
	case sealed(device: DeviceID, kind: PushSealing.Kind, sealed: Data, collapse: Data?)
	/// A Live Activity's numbers, to the activity the phone started under that id (16 bytes, base64url).
	case activity(device: DeviceID, activity: ItemID, event: ActivityEvent, numbers: ActivityNumbers)

	public var device: DeviceID {
		switch self {
		case let .sealed(device, _, _, _), let .activity(device, _, _, _): device
		}
	}
}
