// What RemoteKit refuses, and why, in words that carry nothing secret.
//
// Every error RemoteKit throws is one of these. None holds a key, a secret, a tag, a ciphertext or a plaintext: only the
// name of what was refused and a fixed reason, so that an error can go into a log or a message as it is (#674).

public struct RemoteKitError: Error, Equatable, Sendable, CustomStringConvertible {
	/// What was being read or made: "Noise handshake", "frame", "pairing payload", "sealed item" and so on.
	public let part: String
	/// Why it was refused, as a fixed phrase.
	public let reason: String

	public init(_ part: String, _ reason: String) {
		self.part = part
		self.reason = reason
	}

	public var description: String { "\(part): \(reason)" }
}
