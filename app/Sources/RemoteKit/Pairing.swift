import CryptoKit
import Foundation

/// What is worked out from a pairing's secret `s` (iphone.md 3.1, 3.3). Each is HMAC-SHA256 keyed with `s` over a label,
/// a zero byte and what it is bound to.
public enum PairingSecrets {
	/// The relay's join token: HMAC-SHA256(s, "pi2-join" 0x00 <pairing id's text>), 32 bytes (3.3 step 2).
	public static func joinToken(secret: Data, pairing: PairingID) -> Data {
		mac(secret, label: "pi2-join", Data(pairing.text.utf8))
	}

	/// What the relay is given in place of the token: SHA-256 of it.
	public static func joinTokenHash(_ token: Data) -> Data { Data(SHA256.hash(data: token)) }

	/// The six digits the phone shows and the person types on the Mac: HMAC-SHA256(s, "pi2-digits" 0x00 <handshake
	/// hash>), its first 32 bits as a big-endian number, modulo a million, written with six digits (3.3 step 7).
	public static func digits(secret: Data, binding: Data) -> String {
		let code = mac(secret, label: "pi2-digits", binding)
		let number = UInt32(code[0]) << 24 | UInt32(code[1]) << 16 | UInt32(code[2]) << 8 | UInt32(code[3])
		let text = String(number % 1_000_000)
		return String(repeating: "0", count: 6 - text.count) + text
	}

	/// Whether the digits typed are the ones expected, compared in constant time.
	public static func digitsMatch(_ typed: String, _ expected: String) -> Bool {
		Bytes.constantTimeEqual(Array(typed.utf8), Array(expected.utf8))
	}

	/// The client data hash of the App Attest attestation in `pair`: SHA-256 of the Mac's challenge, the device key's
	/// public half (SPKI DER) and the handshake hash, one after the other (3.3 step 4).
	public static func attestationClientDataHash(challenge: Data, deviceKey: P256.Signing.PublicKey, binding: Data) -> Data {
		var hasher = SHA256()
		hasher.update(data: challenge)
		hasher.update(data: deviceKey.derRepresentation)
		hasher.update(data: binding)
		return Data(hasher.finalize())
	}

	/// The client data hash of the App Attest attestation in the relay's `join`: SHA-256 of the relay's 32-byte challenge
	/// followed by the device key's public half (SPKI DER, 91 bytes), so that the attested copy of the app vouches for this
	/// device key on this connection (3.3 step 2). The relay works out the same (`relay/src/join.ts`); one shared value
	/// holds the two together (`pi2-relay-check`, `relay/test/join-hash.test.ts`).
	public static func joinClientDataHash(challenge: Data, deviceKey: P256.Signing.PublicKey) -> Data {
		var hasher = SHA256()
		hasher.update(data: challenge)
		hasher.update(data: deviceKey.derRepresentation)
		return Data(hasher.finalize())
	}

	private static func mac(_ secret: Data, label: String, _ bound: Data) -> Data {
		var message = Data(label.utf8)
		message.append(0)
		message.append(bound)
		return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
	}
}
