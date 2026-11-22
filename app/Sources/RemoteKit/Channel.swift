import CryptoKit
import Foundation

// The channel between a phone and pi² Remote (iphone.md 5.2), the same on every path: a Noise handshake with no payload
// in either message, then frames in transport messages.
//
// - Pairing: Noise_IKpsk2_25519_ChaChaPoly_SHA256, the phone the initiator knowing the Mac's channel key `c`, the
//   pre-shared key `s`, the prologue "pi2-pair-v2", a zero byte and the pairing's id (3.3).
// - Every connection after: Noise_KK_25519_ChaChaPoly_SHA256, both static keys known, the prologue "pi2-v2", a zero
//   byte, the pairing's id, a zero byte and the device's id (3.4).
//
// Ids are written in the prologue as their texts, in UTF-8; neither can hold a zero byte, so the prologue has one reading.

/// A channel's handshake, as one side runs it.
public struct ChannelHandshake: Sendable {
	public enum Kind: Sendable { case pairing, connection }

	public let kind: Kind
	private var noise: NoiseHandshake

	private init(kind: Kind, noise: NoiseHandshake) {
		self.kind = kind
		self.noise = noise
	}

	static func pairingPrologue(_ pairing: PairingID) -> Data { Data("pi2-pair-v2".utf8) + Data([0]) + Data(pairing.text.utf8) }

	static func connectionPrologue(_ pairing: PairingID, _ device: DeviceID) -> Data {
		Data("pi2-v2".utf8) + Data([0]) + Data(pairing.text.utf8) + Data([0]) + Data(device.text.utf8)
	}

	/// The phone's side of pairing: it knows the Mac's channel key and the secret from the payload it scanned.
	public static func pairingInitiator(
		payload: PairingPayload, channelKey: Curve25519.KeyAgreement.PrivateKey
	) throws -> ChannelHandshake {
		try pairingInitiator(payload: payload, channelKey: channelKey, ephemeral: nil)
	}

	/// The same, with the ephemeral key given rather than made: only for the fuzzer, which must make the same messages
	/// from the same seed. An ephemeral key used twice gives away the channel.
	@_spi(Vectors)
	public static func pairingInitiator(
		payload: PairingPayload, channelKey: Curve25519.KeyAgreement.PrivateKey, ephemeral: Curve25519.KeyAgreement.PrivateKey?
	) throws -> ChannelHandshake {
		ChannelHandshake(kind: .pairing, noise: try NoiseHandshake(
			pattern: .ikpsk2, initiator: true, prologue: pairingPrologue(payload.pairing), localStatic: channelKey,
			remoteStatic: payload.channelKey.rawRepresentation, psk: payload.secret, ephemeral: ephemeral))
	}

	/// pi² Remote's side of pairing, for the join window whose secret is `secret`.
	public static func pairingResponder(
		pairing: PairingID, secret: Data, channelKey: Curve25519.KeyAgreement.PrivateKey
	) throws -> ChannelHandshake {
		try pairingResponder(pairing: pairing, secret: secret, channelKey: channelKey, ephemeral: nil)
	}

	@_spi(Vectors)
	public static func pairingResponder(
		pairing: PairingID, secret: Data, channelKey: Curve25519.KeyAgreement.PrivateKey, ephemeral: Curve25519.KeyAgreement.PrivateKey?
	) throws -> ChannelHandshake {
		ChannelHandshake(kind: .pairing, noise: try NoiseHandshake(
			pattern: .ikpsk2, initiator: false, prologue: pairingPrologue(pairing), localStatic: channelKey, remoteStatic: nil,
			psk: secret, ephemeral: ephemeral))
	}

	/// Either side of a connection after pairing. The phone is the initiator on both paths today; either end may be.
	public static func connection(
		initiator: Bool, pairing: PairingID, device: DeviceID, channelKey: Curve25519.KeyAgreement.PrivateKey,
		remoteChannelKey: Curve25519.KeyAgreement.PublicKey
	) throws -> ChannelHandshake {
		try connection(initiator: initiator, pairing: pairing, device: device, channelKey: channelKey, remoteChannelKey: remoteChannelKey, ephemeral: nil)
	}

	@_spi(Vectors)
	public static func connection(
		initiator: Bool, pairing: PairingID, device: DeviceID, channelKey: Curve25519.KeyAgreement.PrivateKey,
		remoteChannelKey: Curve25519.KeyAgreement.PublicKey, ephemeral: Curve25519.KeyAgreement.PrivateKey?
	) throws -> ChannelHandshake {
		ChannelHandshake(kind: .connection, noise: try NoiseHandshake(
			pattern: .kk, initiator: initiator, prologue: connectionPrologue(pairing, device), localStatic: channelKey,
			remoteStatic: remoteChannelKey.rawRepresentation, psk: nil, ephemeral: ephemeral))
	}

	/// pi² Remote's side of a connection whose first message came without saying which device sent it (a path with no
	/// device id in front, such as TCP): tries the paired devices' keys in turn, at most five (3.5), and gives back the
	/// device whose key the message was made for, with the handshake ready to write its answer.
	public static func respond(
		toFirstMessage message: Data, pairing: PairingID, channelKey: Curve25519.KeyAgreement.PrivateKey,
		devices: [(DeviceID, Curve25519.KeyAgreement.PublicKey)]
	) throws -> (DeviceID, ChannelHandshake) {
		guard devices.count <= 8 else { throw RemoteKitError("channel handshake", "too many devices to try") }
		for (device, key) in devices {
			var handshake = try connection(initiator: false, pairing: pairing, device: device, channelKey: channelKey, remoteChannelKey: key)
			if (try? handshake.readMessage(message)) != nil { return (device, handshake) }
		}
		throw RemoteKitError("channel handshake", "made for no paired device")
	}

	public var writesNext: Bool { noise.writesNext }
	public var isComplete: Bool { noise.isComplete }

	/// The other side's channel key: known from the start but on pi² Remote's side of pairing, where the phone's comes
	/// in the first message.
	public var remoteChannelKey: Curve25519.KeyAgreement.PublicKey? {
		noise.remoteStaticKey.flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
	}

	/// This side's next handshake message. It carries no payload (5.2).
	public mutating func writeMessage() throws -> Data { try noise.writeMessage() }

	/// The other side's next handshake message, which must carry no payload (5.2): the first message of KK and IK can be
	/// replayed and is only weakly forward-secret, so the first data always waits for the transport.
	public mutating func readMessage(_ message: Data) throws {
		let payload = try noise.readMessage(message)
		guard payload.isEmpty else { throw RemoteKitError("channel handshake", "a payload in a handshake message") }
	}

	/// The channel, once both messages are done.
	public func channel(openedAt: Date = Date()) throws -> Channel {
		let transport = try noise.split()
		guard let remote = noise.remoteStaticKey else { throw RemoteKitError("channel handshake", "not complete") }
		return Channel(transport: transport, remoteChannelKey: remote, openedAt: openedAt)
	}
}

/// What a transport message brought.
public enum ChannelEvent: Equatable, Sendable {
	/// A whole engine line, or a first line of the channel (5.6).
	case line(Data)
	/// The count of lines the other side has received in all (5.8).
	case ack(UInt64)
	case ping
	/// The other side ended the channel.
	case bye
}

/// One end of a channel after its handshake: frames in Noise transport messages.
///
/// A channel that refuses a message is over: every call after throws, since the two sides' nonces no longer agree and a
/// message that failed may have been an attack. A channel lasts a day at most and is never rekeyed (5.2).
public struct Channel: Sendable {
	public static let lifetime: TimeInterval = 24 * 60 * 60

	/// The channel binding: the handshake hash (5.2), which `pair`, `attach` and the Mac's proof sign.
	public let handshakeHash: Data
	/// The other side's channel key, as the handshake proved it.
	public let remoteChannelKey: Data
	public let openedAt: Date
	/// Pads each frame this end sends to the next multiple of this many bytes; the phone sets 256 (5.2).
	public var padding: Int?

	private var transport: NoiseTransport
	private var assembler: LineAssembler
	private var state = State.open

	private enum State { case open, ended, failed }

	init(transport: NoiseTransport, remoteChannelKey: Data, openedAt: Date, maxLineLength: Int = Lines.defaultMaxLength) {
		self.transport = transport
		self.handshakeHash = transport.handshakeHash
		self.remoteChannelKey = remoteChannelKey
		self.openedAt = openedAt
		assembler = LineAssembler(maxLength: maxLineLength)
	}

	public func isExpired(at date: Date) -> Bool { date.timeIntervalSince(openedAt) >= Self.lifetime }

	/// Whether it has ended, with `bye` either way, or failed.
	public var isOver: Bool { state != .open }

	private func usable(at date: Date) throws {
		guard state == .open else { throw RemoteKitError("channel", state == .ended ? "has ended" : "has failed") }
		guard !isExpired(at: date) else { throw RemoteKitError("channel", "is over a day old: make a new one") }
	}

	/// The transport messages that carry `line`.
	public mutating func seal(line: Data, at date: Date = Date()) throws -> [Data] {
		try usable(at: date)
		return try Lines.frames(for: line).map { try seal($0) }
	}

	public mutating func sealAck(_ count: UInt64, at date: Date = Date()) throws -> Data {
		try usable(at: date)
		return try seal(Frame.ack(count))
	}

	public mutating func sealPing(at date: Date = Date()) throws -> Data {
		try usable(at: date)
		return try seal(Frame(.ping))
	}

	/// The last message this end sends.
	public mutating func sealBye() throws -> Data {
		guard state == .open else { throw RemoteKitError("channel", "has ended") }
		let message = try seal(Frame(.bye))
		state = .ended
		return message
	}

	private mutating func seal(_ frame: Frame) throws -> Data {
		do {
			return try transport.encrypt(frame.encoded(padTo: padding))
		} catch {
			state = .failed
			throw error
		}
	}

	/// Reads one transport message from the other side.
	public mutating func open(_ message: Data, at date: Date = Date()) throws -> ChannelEvent? {
		try usable(at: date)
		do {
			let frame = try Frame.decode(transport.decrypt(message))
			switch frame.kind {
			case .data, .more:
				return try assembler.take(frame).map(ChannelEvent.line)
			case .ack:
				guard !assembler.isPartway else { throw RemoteKitError("channel", "an ack inside a line") }
				return .ack(frame.ackCount!)
			case .ping:
				return .ping
			case .bye:
				state = .ended
				return .bye
			}
		} catch {
			state = .failed
			throw error
		}
	}
}
