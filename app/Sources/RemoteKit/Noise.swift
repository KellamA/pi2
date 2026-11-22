import CryptoKit
import Foundation
import Synchronization

// The Noise Protocol Framework, revision 34 (https://noiseprotocol.org/noise.html), for the two protocols pi² uses
// (iphone.md 5.2): Noise_IKpsk2_25519_ChaChaPoly_SHA256 to pair and Noise_KK_25519_ChaChaPoly_SHA256 for every
// connection after. Written from the specification's sections 5 (the processing rules), 7 (the patterns), 9 (psk
// modifiers) and 12 (25519, ChaChaPoly, SHA256), on CryptoKit's primitives, and checked against the published test
// vectors by pi2-remote-check (#674). Nothing else in pi² is Noise: the channel (Channel.swift) is built on this alone.
//
// Handshake payloads are possible here, because the published vectors carry them; the channel sends none and takes
// none (5.2). Rekeying is not implemented, since a channel is made again after a day and never rekeyed.

public enum Noise {
	/// The longest Noise message (section 3).
	public static let maxMessageLength = 65535
	public static let tagLength = 16
	public static let dhLength = 32
	public static let hashLength = 32
	/// The longest plaintext of a transport message.
	public static let maxPlaintextLength = maxMessageLength - tagLength
}

/// A handshake pattern of the two pi² uses.
public enum NoisePattern: Sendable, CaseIterable {
	case kk
	case ikpsk2

	enum Token { case e, s, ee, es, se, ss, psk }

	public var protocolName: String {
		switch self {
		case .kk: "Noise_KK_25519_ChaChaPoly_SHA256"
		case .ikpsk2: "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
		}
	}

	// Section 7.5: KK and IK. Section 9.4: psk2 adds "psk" to the end of the second message.
	var initiatorPremessage: [Token] {
		switch self {
		case .kk: [.s]
		case .ikpsk2: []
		}
	}

	var responderPremessage: [Token] { [.s] }

	var messages: [[Token]] {
		switch self {
		case .kk: [[.e, .es, .ss], [.e, .ee, .se]]
		case .ikpsk2: [[.e, .es, .s, .ss], [.e, .ee, .se, .psk]]
		}
	}

	public var usesPSK: Bool { self == .ikpsk2 }
}

/// Section 5.1: a key and a nonce.
struct NoiseCipherState: Sendable {
	private var key: SymmetricKey?
	private(set) var nonce: UInt64 = 0

	init() {}

	init(key: Data) { self.key = SymmetricKey(data: key) }

	var hasKey: Bool { key != nil }

	mutating func initializeKey(_ material: Data) {
		key = SymmetricKey(data: material)
		nonce = 0
	}

	/// Section 12.3: 32 bits of zeros, then the nonce as a 64-bit little-endian number.
	private func chachaNonce() throws -> ChaChaPoly.Nonce {
		var bytes = Data(repeating: 0, count: 4)
		for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(nonce >> UInt64(shift) & 0xff)) }
		return try ChaChaPoly.Nonce(data: bytes)
	}

	mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
		guard let key else { return plaintext }
		// 2^64-1 is reserved (section 5.1).
		guard nonce < UInt64.max else { throw RemoteKitError("Noise", "the channel's nonces are used up") }
		let box: ChaChaPoly.SealedBox
		do {
			box = try ChaChaPoly.seal(plaintext, using: key, nonce: chachaNonce(), authenticating: ad)
		} catch {
			throw RemoteKitError("Noise", "could not encrypt")
		}
		nonce += 1
		return box.ciphertext + box.tag
	}

	mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
		guard let key else { return ciphertext }
		guard nonce < UInt64.max else { throw RemoteKitError("Noise", "the channel's nonces are used up") }
		guard ciphertext.count >= Noise.tagLength else { throw RemoteKitError("Noise", "a message too short to hold its tag") }
		let plaintext: Data
		do {
			let box = try ChaChaPoly.SealedBox(
				nonce: chachaNonce(),
				ciphertext: ciphertext.prefix(ciphertext.count - Noise.tagLength),
				tag: ciphertext.suffix(Noise.tagLength))
			plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
		} catch {
			throw RemoteKitError("Noise", "a message failed its authentication")
		}
		nonce += 1
		return plaintext
	}
}

/// Section 5.2: the chaining key and the handshake hash.
struct NoiseSymmetricState: Sendable {
	private(set) var chainingKey: Data
	private(set) var hash: Data
	private(set) var cipher = NoiseCipherState()

	init(protocolName: String) {
		let name = Data(protocolName.utf8)
		hash = name.count <= Noise.hashLength ? name + Data(repeating: 0, count: Noise.hashLength - name.count) : Data(SHA256.hash(data: name))
		chainingKey = hash
	}

	mutating func mixKey(_ input: Data) {
		let output = Self.hkdf(chainingKey, input, outputs: 2)
		chainingKey = output[0]
		cipher.initializeKey(output[1])
	}

	mutating func mixHash(_ data: Data) {
		var hasher = SHA256()
		hasher.update(data: hash)
		hasher.update(data: data)
		hash = Data(hasher.finalize())
	}

	mutating func mixKeyAndHash(_ input: Data) {
		let output = Self.hkdf(chainingKey, input, outputs: 3)
		chainingKey = output[0]
		mixHash(output[1])
		cipher.initializeKey(output[2])
	}

	mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
		let ciphertext = try cipher.encrypt(ad: hash, plaintext: plaintext)
		mixHash(ciphertext)
		return ciphertext
	}

	mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
		let plaintext = try cipher.decrypt(ad: hash, ciphertext: ciphertext)
		mixHash(ciphertext)
		return plaintext
	}

	func split() -> (NoiseCipherState, NoiseCipherState) {
		let output = Self.hkdf(chainingKey, Data(), outputs: 2)
		return (NoiseCipherState(key: output[0]), NoiseCipherState(key: output[1]))
	}

	/// Section 4.3: HKDF with HMAC-SHA256, the chaining key as its salt.
	static func hkdf(_ chainingKey: Data, _ input: Data, outputs: Int) -> [Data] {
		let temporary = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: chainingKey))))
		var result: [Data] = []
		var previous = Data()
		for index in 1...outputs {
			var message = previous
			message.append(UInt8(index))
			previous = Data(HMAC<SHA256>.authenticationCode(for: message, using: temporary))
			result.append(previous)
		}
		return result
	}
}

/// Section 5.3: one side of a handshake, as a value: the state `NoiseHandshake` keeps behind its lock.
struct HandshakeCore: Sendable {
	let pattern: NoisePattern
	let isInitiator: Bool
	private var symmetric: NoiseSymmetricState
	private let localStatic: Curve25519.KeyAgreement.PrivateKey
	private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
	private let fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?
	private(set) var remoteStatic: Data?
	private var remoteEphemeral: Data?
	private let psk: Data?
	private var messageIndex = 0
	private(set) var failed = false
	/// Whether the transport has been made from it: a handshake gives one, and only one.
	private var spent = false

	init(
		pattern: NoisePattern, initiator: Bool, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
		remoteStatic: Data?, psk: Data?, ephemeral: Curve25519.KeyAgreement.PrivateKey?
	) throws {
		let knowsRemote = initiator ? pattern.responderPremessage.contains(.s) : pattern.initiatorPremessage.contains(.s)
		guard (remoteStatic != nil) == knowsRemote else { throw RemoteKitError("Noise handshake", "the other side's static key is not as the pattern needs") }
		if let remoteStatic, remoteStatic.count != Noise.dhLength { throw RemoteKitError("Noise handshake", "a static key is not 32 bytes") }
		guard (psk != nil) == pattern.usesPSK else { throw RemoteKitError("Noise handshake", "a pre-shared key is not as the pattern needs") }
		if let psk, psk.count != 32 { throw RemoteKitError("Noise handshake", "the pre-shared key is not 32 bytes") }

		self.pattern = pattern
		self.isInitiator = initiator
		self.localStatic = localStatic
		self.remoteStatic = remoteStatic
		self.psk = psk
		self.fixedEphemeral = ephemeral
		symmetric = NoiseSymmetricState(protocolName: pattern.protocolName)
		symmetric.mixHash(prologue)
		// The initiator's pre-message keys are hashed first (section 7.1).
		let local = localStatic.publicKey.rawRepresentation
		if pattern.initiatorPremessage.contains(.s) { symmetric.mixHash(initiator ? local : remoteStatic!) }
		if pattern.responderPremessage.contains(.s) { symmetric.mixHash(initiator ? remoteStatic! : local) }
	}

	var isComplete: Bool { messageIndex == pattern.messages.count }
	var writesNext: Bool { !isComplete && (messageIndex % 2 == 0) == isInitiator }
	var handshakeHash: Data { symmetric.hash }
	var messagesDone: Int { messageIndex }

	mutating func fail() { failed = true }

	mutating func writeMessage(payload: Data) throws -> Data {
		guard !failed else { throw RemoteKitError("Noise handshake", "has already failed") }
		guard writesNext else { throw RemoteKitError("Noise handshake", "not this side's turn to write") }
		do {
			var message = Data()
			for token in pattern.messages[messageIndex] {
				switch token {
				case .e:
					let ephemeral = fixedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
					localEphemeral = ephemeral
					let key = ephemeral.publicKey.rawRepresentation
					message.append(key)
					symmetric.mixHash(key)
					if pattern.usesPSK { symmetric.mixKey(key) }
				case .s:
					message.append(try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation))
				case .psk:
					symmetric.mixKeyAndHash(psk!)
				case .ee, .es, .se, .ss:
					symmetric.mixKey(try dh(token))
				}
			}
			message.append(try symmetric.encryptAndHash(payload))
			guard message.count <= Noise.maxMessageLength else { throw RemoteKitError("Noise handshake", "a message too long") }
			messageIndex += 1
			return message
		} catch {
			failed = true
			throw error
		}
	}

	mutating func readMessage(_ message: Data) throws -> Data {
		guard !failed else { throw RemoteKitError("Noise handshake", "has already failed") }
		guard !isComplete, !writesNext else { throw RemoteKitError("Noise handshake", "not this side's turn to read") }
		do {
			guard message.count <= Noise.maxMessageLength else { throw RemoteKitError("Noise handshake", "a message too long") }
			var rest = Data(message)
			func take(_ count: Int) throws -> Data {
				guard rest.count >= count else { throw RemoteKitError("Noise handshake", "a message too short") }
				let part = Data(rest.prefix(count))
				rest = Data(rest.dropFirst(count))
				return part
			}
			for token in pattern.messages[messageIndex] {
				switch token {
				case .e:
					let key = try take(Noise.dhLength)
					remoteEphemeral = key
					symmetric.mixHash(key)
					if pattern.usesPSK { symmetric.mixKey(key) }
				case .s:
					let sealed = try take(Noise.dhLength + (symmetric.cipher.hasKey ? Noise.tagLength : 0))
					remoteStatic = try symmetric.decryptAndHash(sealed)
				case .psk:
					symmetric.mixKeyAndHash(psk!)
				case .ee, .es, .se, .ss:
					symmetric.mixKey(try dh(token))
				}
			}
			let payload = try symmetric.decryptAndHash(rest)
			messageIndex += 1
			return payload
		} catch {
			failed = true
			throw error
		}
	}

	/// Section 5.2's Split, once: a second call is refused, since two transports from one handshake would share their
	/// keys and nonces.
	mutating func split() throws -> TransportCore {
		guard isComplete, !failed else { throw RemoteKitError("Noise handshake", "not complete") }
		guard !spent else { throw RemoteKitError("Noise handshake", "has already given its transport") }
		spent = true
		let (first, second) = symmetric.split()
		return TransportCore(sender: isInitiator ? first : second, receiver: isInitiator ? second : first)
	}

	/// Section 5.3's DH tokens, from this side's point of view.
	private func dh(_ token: NoisePattern.Token) throws -> Data {
		let local: Curve25519.KeyAgreement.PrivateKey?
		let remote: Data?
		switch token {
		case .ee: (local, remote) = (localEphemeral, remoteEphemeral)
		case .ss: (local, remote) = (localStatic, remoteStatic)
		case .es: (local, remote) = isInitiator ? (localEphemeral, remoteStatic) : (localStatic, remoteEphemeral)
		case .se: (local, remote) = isInitiator ? (localStatic, remoteEphemeral) : (localEphemeral, remoteStatic)
		default: (local, remote) = (nil, nil)
		}
		guard let local, let remote else { throw RemoteKitError("Noise handshake", "a key is missing for a DH") }
		return try NoiseHandshake.agree(local, remote)
	}
}

/// Section 5.3: one side of a handshake.
///
/// A final class with its state behind a lock, not a value: a copy of a value would hold the same keys, and two
/// transports or two messages made from them would reuse a key with a nonce. A reference shares one state, so every
/// holder sees the same nonce and the same failure, from any thread. The transport is given once (`split()`).
/// `description`, `debugDescription` and `dump` show the pattern and the progress, never a key.
public final class NoiseHandshake: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	public let pattern: NoisePattern
	public let isInitiator: Bool
	private let core: Mutex<HandshakeCore>

	/// - Parameters:
	///   - remoteStatic: the other side's static key, when the pattern has it known beforehand (both sides of KK, the
	///     initiator of IK); nil otherwise.
	///   - psk: the 32-byte pre-shared key of IKpsk2; nil for KK.
	public convenience init(
		pattern: NoisePattern, initiator: Bool, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
		remoteStatic: Data?, psk: Data?
	) throws {
		try self.init(pattern: pattern, initiator: initiator, prologue: prologue, localStatic: localStatic, remoteStatic: remoteStatic, psk: psk, ephemeral: nil)
	}

	/// The same, with the ephemeral key given rather than made: only for checking against the published test vectors,
	/// which fix it. An ephemeral key used twice gives away the channel.
	@_spi(Vectors)
	public init(
		pattern: NoisePattern, initiator: Bool, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
		remoteStatic: Data?, psk: Data?, ephemeral: Curve25519.KeyAgreement.PrivateKey?
	) throws {
		self.pattern = pattern
		self.isInitiator = initiator
		core = Mutex(try HandshakeCore(
			pattern: pattern, initiator: initiator, prologue: prologue, localStatic: localStatic, remoteStatic: remoteStatic, psk: psk,
			ephemeral: ephemeral))
	}

	public var isComplete: Bool { core.withLock { $0.isComplete } }

	/// Whether the next message is this side's to write.
	public var writesNext: Bool { core.withLock { $0.writesNext } }

	/// Whether it refused a message, or was told to fail: then it does nothing more.
	public var hasFailed: Bool { core.withLock { $0.failed } }

	/// The handshake hash: the channel binding once the handshake is complete (section 11.2).
	public var handshakeHash: Data { core.withLock { $0.handshakeHash } }

	/// The other side's static key, once known.
	public var remoteStaticKey: Data? { core.withLock { $0.remoteStatic } }

	public func writeMessage(payload: Data = Data()) throws -> Data {
		try core.withLock { try $0.writeMessage(payload: payload) }
	}

	/// Reads the other side's next message and gives back its payload.
	public func readMessage(_ message: Data) throws -> Data {
		try core.withLock { try $0.readMessage(message) }
	}

	/// Reads the other side's next message, which must carry no payload; one that does fails the handshake.
	func readMessageWithoutPayload(_ message: Data) throws {
		try core.withLock { core in
			let payload = try core.readMessage(message)
			guard payload.isEmpty else {
				core.fail()
				throw RemoteKitError("channel handshake", "a payload in a handshake message")
			}
		}
	}

	/// The transport's two cipher states, once the handshake is complete (section 5.2's Split). Given once: a second call
	/// is refused.
	public func split() throws -> NoiseTransport { NoiseTransport(core: try splitCore(), handshakeHash: handshakeHash) }

	func splitCore() throws -> TransportCore { try core.withLock { try $0.split() } }

	public var description: String {
		let (done, failed) = core.withLock { ($0.messagesDone, $0.failed) }
		return "\(pattern.protocolName) handshake, \(isInitiator ? "initiator" : "responder"), \(done) of \(pattern.messages.count) messages\(failed ? ", failed" : "")"
	}

	public var debugDescription: String { description }

	public var customMirror: Mirror {
		Mirror(self, children: ["pattern": pattern.protocolName, "isInitiator": isInitiator, "state": description], displayStyle: .class)
	}

	static func agree(_ local: Curve25519.KeyAgreement.PrivateKey, _ remote: Data) throws -> Data {
		let output: Data
		do {
			let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
			output = try local.sharedSecretFromKeyAgreement(with: key).withUnsafeBytes { Data($0) }
		} catch {
			throw RemoteKitError("Noise handshake", "a key that cannot be agreed with")
		}
		// A key of small order gives all zeros, which section 12.1 lets an implementation refuse; this one does.
		guard output.count == Noise.dhLength, output.contains(where: { $0 != 0 }) else {
			throw RemoteKitError("Noise handshake", "a key of small order")
		}
		return output
	}
}

/// The transport's two cipher states, as a value: what `NoiseTransport` and `Channel` keep behind their locks.
struct TransportCore: Sendable {
	private var sender: NoiseCipherState
	private var receiver: NoiseCipherState

	init(sender: NoiseCipherState, receiver: NoiseCipherState) {
		self.sender = sender
		self.receiver = receiver
	}

	/// Transport messages have no associated data.
	mutating func encrypt(_ plaintext: Data) throws -> Data {
		guard plaintext.count <= Noise.maxPlaintextLength else { throw RemoteKitError("Noise", "a plaintext too long") }
		return try sender.encrypt(ad: Data(), plaintext: plaintext)
	}

	mutating func decrypt(_ message: Data) throws -> Data {
		guard message.count <= Noise.maxMessageLength else { throw RemoteKitError("Noise", "a message too long") }
		return try receiver.decrypt(ad: Data(), ciphertext: message)
	}
}

/// Section 5: the transport's two cipher states and the channel binding, after the handshake. A final class with its
/// state behind a lock, for the reason `NoiseHandshake` gives. The channel (`Channel`) is what pi² uses; this is Noise's
/// own transport, for the published vectors.
public final class NoiseTransport: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	private let core: Mutex<TransportCore>
	public let handshakeHash: Data

	init(core: TransportCore, handshakeHash: Data) {
		self.core = Mutex(core)
		self.handshakeHash = handshakeHash
	}

	public func encrypt(_ plaintext: Data) throws -> Data { try core.withLock { try $0.encrypt(plaintext) } }

	public func decrypt(_ message: Data) throws -> Data { try core.withLock { try $0.decrypt(message) } }

	public var description: String { "Noise transport" }
	public var debugDescription: String { description }
	public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
