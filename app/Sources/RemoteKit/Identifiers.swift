import CryptoKit
import Foundation

/// A pairing's id at the relay: 16 random bytes the relay chose, as base64url (iphone.md 3.1).
public struct PairingID: Hashable, Sendable, CustomStringConvertible {
	public let text: String

	public init?(_ text: String) {
		guard Base64URL.decode(text, count: 16) != nil else { return nil }
		self.text = text
	}

	public static func random() -> PairingID { PairingID(Base64URL.encode(Bytes.random(16)))! }

	public var description: String { text }
}

/// A device's id: "dev_" and 16 random bytes as base64url; also its slot at the relay (iphone.md 3.2).
public struct DeviceID: Hashable, Sendable, CustomStringConvertible {
	public let text: String

	public init?(_ text: String) {
		guard text.hasPrefix("dev_"), text.utf8.count == 26, Base64URL.decode(String(text.dropFirst(4)), count: 16) != nil else { return nil }
		self.text = text
	}

	public static func random() -> DeviceID { DeviceID("dev_" + Base64URL.encode(Bytes.random(16)))! }

	public var description: String { text }
}

/// A sealed item's id, which is also the nonce of the request it carries: 16 random bytes as base64url (iphone.md 4.3).
public struct ItemID: Hashable, Sendable, CustomStringConvertible {
	public let text: String

	public init?(_ text: String) {
		guard Base64URL.decode(text, count: 16) != nil else { return nil }
		self.text = text
	}

	public static func random() -> ItemID { ItemID(Base64URL.encode(Bytes.random(16)))! }

	public var description: String { text }
}

/// A device session's id, as the engine gives it at `remote.attach` (iphone.md 4.1): 1 to 64 letters, digits, `_` and `-`.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
	public let text: String

	public init?(_ text: String) {
		guard (1...64).contains(text.utf8.count), text.utf8.allSatisfy(Self.allowed) else { return nil }
		self.text = text
	}

	static func allowed(_ byte: UInt8) -> Bool {
		switch byte {
		case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
			UInt8(ascii: "_"), UInt8(ascii: "-"):
			true
		default: false
		}
	}

	public var description: String { text }
}

/// The public keys of iphone.md 3.2, as they are written in the pairing payload, the `pair` line and the engine's record.
public enum PublicKeys {
	/// A P-256 public key written as SPKI DER in base64url (the identity, record, device and presence keys). Only the one
	/// encoding CryptoKit writes for it is taken, so that each key has one text.
	public static func signingKey(fromBase64URL text: String) -> P256.Signing.PublicKey? {
		guard text.utf8.count <= 200, let der = Base64URL.decode(text), let key = try? P256.Signing.PublicKey(derRepresentation: der) else { return nil }
		guard Bytes.constantTimeEqual(key.derRepresentation, der) else { return nil }
		return key
	}

	public static func agreementKey(fromBase64URL text: String) -> P256.KeyAgreement.PublicKey? {
		guard text.utf8.count <= 200, let der = Base64URL.decode(text), let key = try? P256.KeyAgreement.PublicKey(derRepresentation: der) else { return nil }
		guard Bytes.constantTimeEqual(key.derRepresentation, der) else { return nil }
		return key
	}

	/// A Curve25519 public key (a channel key) as its 32 raw bytes in base64url.
	public static func channelKey(fromBase64URL text: String) -> Curve25519.KeyAgreement.PublicKey? {
		guard let raw = Base64URL.decode(text, count: 32) else { return nil }
		return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
	}

	public static func text(_ key: P256.Signing.PublicKey) -> String { Base64URL.encode(key.derRepresentation) }
	public static func text(_ key: P256.KeyAgreement.PublicKey) -> String { Base64URL.encode(key.derRepresentation) }
	public static func text(_ key: Curve25519.KeyAgreement.PublicKey) -> String { Base64URL.encode(key.rawRepresentation) }
}
