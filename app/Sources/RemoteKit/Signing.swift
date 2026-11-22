import CryptoKit
import Foundation

/// A P-256 key that signs what RemoteKit writes: the Mac's identity key, the phone's device key or presence key
/// (iphone.md 3.2). Either a key in software or one in the Secure Enclave; a presence key is one made with the
/// authentication context of the session's Face ID (4.3), which RemoteKit never sees.
public protocol StatementSigner {
	var publicKey: P256.Signing.PublicKey { get }
	/// An ECDSA P-256 signature over SHA-256 of `data`, as its 64 raw bytes (r then s).
	func sign(_ data: Data) throws -> Data
}

extension P256.Signing.PrivateKey: StatementSigner {
	public func sign(_ data: Data) throws -> Data { try signature(for: data).rawRepresentation }
}

extension SecureEnclave.P256.Signing.PrivateKey: StatementSigner {
	public func sign(_ data: Data) throws -> Data { try signature(for: data).rawRepresentation }
}

/// A JSON text and a signature over its exact bytes (iphone.md 4.3: "`signed` is always the exact JSON text that was
/// signed, so neither side has to put JSON in a canonical form"). Signatures are ECDSA P-256 with SHA-256, written as
/// their 64 raw bytes (r then s, IEEE P1363, which `node:crypto` reads with `dsaEncoding: "ieee-p1363"`) in base64url.
public struct SignedStatement: Sendable {
	public static let maxTextLength = 16 * 1024
	public static let signatureLength = 64

	/// The exact text that was signed.
	public let text: String
	public let signature: Data
	/// The text, read.
	public let value: JSONValue

	/// Writes `value` and signs it.
	public static func make(_ value: JSONValue, signer: some StatementSigner) throws -> SignedStatement {
		let text = JSON.text(value)
		guard text.utf8.count <= maxTextLength else { throw RemoteKitError("signed statement", "too long") }
		let signature: Data
		do {
			signature = try signer.sign(Data(text.utf8))
		} catch {
			throw RemoteKitError("signed statement", "the key could not sign")
		}
		guard signature.count == signatureLength else { throw RemoteKitError("signed statement", "a signature of the wrong length") }
		return SignedStatement(text: text, signature: signature, value: value)
	}

	private init(text: String, signature: Data, value: JSONValue) {
		self.text = text
		self.signature = signature
		self.value = value
	}

	/// Reads a text and its base64url signature as a line carries them. Checks their form only: whose signature it is,
	/// is `isSigned(by:)`.
	public static func read(text: JSONValue?, signature: JSONValue?, part: String) throws -> SignedStatement {
		guard let text = text?.stringValue, text.utf8.count <= maxTextLength else { throw RemoteKitError(part, "signed is not a fitting text") }
		guard let encoded = signature?.stringValue, let signature = Base64URL.decode(encoded, count: signatureLength) else {
			throw RemoteKitError(part, "a signature is not 64 bytes of base64url")
		}
		let value: JSONValue
		do {
			value = try JSON.parse(text)
		} catch {
			throw RemoteKitError(part, "signed is not JSON as RemoteKit reads it")
		}
		return SignedStatement(text: text, signature: signature, value: value)
	}

	/// Whether `key` made this signature over the text.
	public func isSigned(by key: P256.Signing.PublicKey) -> Bool {
		Self.verify(signature, over: Data(text.utf8), by: key)
	}

	static func verify(_ signature: Data, over data: Data, by key: P256.Signing.PublicKey) -> Bool {
		guard let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
		return key.isValidSignature(ecdsa, for: data)
	}

	public var signatureText: String { Base64URL.encode(signature) }
}
