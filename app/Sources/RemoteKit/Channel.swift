import CryptoKit
import Foundation
import Synchronization

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
///
/// A final class, as `NoiseHandshake` is and for its reason: holders share one state, so nothing can be sent twice under
/// one key and nonce, and it gives its channel once. A handshake message that carries a payload fails it.
public final class ChannelHandshake: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	public enum Kind: Sendable { case pairing, connection }

	public let kind: Kind
	private let noise: NoiseHandshake

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

	/// The length of a connection's first message: KK's `e` and the tag of its empty payload.
	public static let connectionFirstMessageLength = Noise.dhLength + Noise.tagLength

	/// How many devices `respond(toFirstMessage:…)` tries, whatever the number paired: the most a Mac may pair (3.5) with
	/// room to spare.
	public static let trials = 8

	/// Keys no device holds, tried in place of the devices a Mac does not have, so that every first message costs the same
	/// eight trials (made once; their private halves are dropped at once).
	private static let decoys: [(DeviceID, Curve25519.KeyAgreement.PublicKey)] = (0..<trials).map { _ in
		(DeviceID.random(), Curve25519.KeyAgreement.PrivateKey().publicKey)
	}

	/// pi² Remote's side of a connection whose first message came without saying which device sent it (a path with no
	/// device id in front, such as TCP): tries the paired devices' keys, and gives back the device whose key the message
	/// was made for, with the handshake ready to write its answer.
	///
	/// A message that is not exactly a first message's length is refused before any key agreement. Every call makes
	/// exactly `trials` trials, the paired devices' and then decoys', and none stops early, so neither how many devices
	/// are paired nor where a device is in the list shows in how long it takes. A failed trial leaves nothing behind.
	public static func respond(
		toFirstMessage message: Data, pairing: PairingID, channelKey: Curve25519.KeyAgreement.PrivateKey,
		devices: [(DeviceID, Curve25519.KeyAgreement.PublicKey)]
	) throws -> (DeviceID, ChannelHandshake) {
		guard message.count == connectionFirstMessageLength else { throw RemoteKitError("channel handshake", "not a connection's first message") }
		guard devices.count <= trials else { throw RemoteKitError("channel handshake", "too many devices to try") }
		let slots = devices.map { Optional($0) } + Array(repeating: nil, count: trials - devices.count)
		var found: (DeviceID, ChannelHandshake)?
		for (index, slot) in slots.enumerated() {
			let (device, key) = slot ?? decoys[index]
			let handshake = try connection(initiator: false, pairing: pairing, device: device, channelKey: channelKey, remoteChannelKey: key)
			let taken = (try? handshake.readMessage(message)) != nil
			if taken, slot != nil, found == nil { found = (device, handshake) }
		}
		guard let found else { throw RemoteKitError("channel handshake", "made for no paired device") }
		return found
	}

	public var writesNext: Bool { noise.writesNext }
	public var isComplete: Bool { noise.isComplete }
	public var hasFailed: Bool { noise.hasFailed }

	/// The other side's channel key: known from the start but on pi² Remote's side of pairing, where the phone's comes
	/// in the first message.
	public var remoteChannelKey: Curve25519.KeyAgreement.PublicKey? {
		noise.remoteStaticKey.flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
	}

	/// This side's next handshake message. It carries no payload (5.2).
	public func writeMessage() throws -> Data { try noise.writeMessage() }

	/// The other side's next handshake message, which must carry no payload (5.2): the first message of KK and IK can be
	/// replayed and is only weakly forward-secret, so the first data always waits for the transport. A message with a
	/// payload fails the handshake: it writes, reads and gives a channel no more.
	public func readMessage(_ message: Data) throws { try noise.readMessageWithoutPayload(message) }

	/// The channel, once both messages are done. Given once: a second call is refused, since two channels from one
	/// handshake would share their keys and nonces.
	///
	/// - Parameters:
	///   - openedAt: when the day it may last begins, on a clock that keeps counting while the device sleeps.
	///   - maxLineLength: the longest line the channel takes from the other side. It starts small, enough for the
	///     channel's own first lines; raise it with `Channel.maxLineLength` once the device is attached.
	public func channel(openedAt: ContinuousClock.Instant = .now, maxLineLength: Int = Lines.firstLinesMaxLength) throws -> Channel {
		let transport = try noise.splitCore()
		guard let remote = noise.remoteStaticKey else { throw RemoteKitError("channel handshake", "not complete") }
		return Channel(transport: transport, handshakeHash: noise.handshakeHash, remoteChannelKey: remote, openedAt: openedAt, maxLineLength: maxLineLength)
	}

	public var description: String {
		"\(kind == .pairing ? "pairing" : "connection") handshake: \(noise.description)"
	}

	public var debugDescription: String { description }

	public var customMirror: Mirror { Mirror(self, children: ["state": description], displayStyle: .class) }
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
/// A final class with its state behind a lock, not a value, for the reason `NoiseHandshake` gives: a copy of a value
/// would seal two lines under one key and nonce. Every holder shares one state, so a channel that refuses a message is
/// over for all of them: every call after throws, since the two sides' nonces no longer agree and a message that failed
/// may have been an attack. A channel lasts a day at most, on a clock that keeps counting while the device sleeps, and
/// is never rekeyed (5.2).
public final class Channel: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	public static let lifetime: Duration = .seconds(24 * 60 * 60)

	/// The channel binding: the handshake hash (5.2), which `pair`, `attach` and the Mac's proof sign.
	public let handshakeHash: Data
	/// The other side's channel key, as the handshake proved it.
	public let remoteChannelKey: Data
	public let openedAt: ContinuousClock.Instant

	private let state: Mutex<State>

	private struct State {
		var transport: TransportCore
		var assembler: LineAssembler
		var padding: Int?
		var phase = Phase.open
	}

	private enum Phase { case open, ended, failed }

	init(transport: TransportCore, handshakeHash: Data, remoteChannelKey: Data, openedAt: ContinuousClock.Instant, maxLineLength: Int) {
		self.handshakeHash = handshakeHash
		self.remoteChannelKey = remoteChannelKey
		self.openedAt = openedAt
		state = Mutex(State(transport: transport, assembler: LineAssembler(maxLength: maxLineLength)))
	}

	/// Pads each frame this end sends to the next multiple of this many bytes; the phone sets 256 (5.2).
	public var padding: Int? {
		get { state.withLock { $0.padding } }
		set { state.withLock { $0.padding = newValue } }
	}

	/// The longest line taken from the other side. It starts at what `channel(…)` was given; pi² Remote and the phone
	/// raise it once the device is attached. A line that would pass it is refused before it is held.
	public var maxLineLength: Int {
		get { state.withLock { $0.assembler.maxLength } }
		set { state.withLock { $0.assembler.maxLength = newValue } }
	}

	public func isExpired(at instant: ContinuousClock.Instant = .now) -> Bool { instant - openedAt >= Self.lifetime }

	/// Whether it has ended, with `bye` either way, or failed.
	public var isOver: Bool { state.withLock { $0.phase != .open } }

	private func usable(_ state: State, at instant: ContinuousClock.Instant) throws {
		guard state.phase == .open else { throw RemoteKitError("channel", state.phase == .ended ? "has ended" : "has failed") }
		guard !isExpired(at: instant) else { throw RemoteKitError("channel", "is over a day old: make a new one") }
	}

	/// The transport messages that carry `line`.
	public func seal(line: Data, at instant: ContinuousClock.Instant = .now) throws -> [Data] {
		let frames = try Lines.frames(for: line)
		return try state.withLock { state in
			try usable(state, at: instant)
			return try frames.map { try Self.seal($0, &state) }
		}
	}

	public func sealAck(_ count: UInt64, at instant: ContinuousClock.Instant = .now) throws -> Data {
		try state.withLock { state in
			try usable(state, at: instant)
			return try Self.seal(Frame.ack(count), &state)
		}
	}

	public func sealPing(at instant: ContinuousClock.Instant = .now) throws -> Data {
		try state.withLock { state in
			try usable(state, at: instant)
			return try Self.seal(Frame(.ping), &state)
		}
	}

	/// The last message this end sends.
	public func sealBye() throws -> Data {
		try state.withLock { state in
			guard state.phase == .open else { throw RemoteKitError("channel", "has ended") }
			let message = try Self.seal(Frame(.bye), &state)
			state.phase = .ended
			return message
		}
	}

	/// pi² Remote's last messages to a phone it did not attach: the `refused` line, then `bye`, so the line always comes
	/// before the channel closes. The line is padded to 256 bytes whatever this end's padding, so that its length tells
	/// the relay or the network nothing of the reason; that a refusal came still shows.
	///
	/// The caller's duties (remotekit.md, "The refused line"): call it only once the attach's device-key signature has
	/// checked out against pi² Remote's own list (`AttachClaim.verifyDevice`), and close anything that fails sooner with
	/// `bye` alone; refuse a `refused` line that arrives from a phone, which never sends one; and never turn the engine's
	/// "revoked" into another reason: a revoked device is sent `bye` alone, or the signed `revoked` line.
	public func sealRefusal(_ refusal: Refusal, at instant: ContinuousClock.Instant = .now) throws -> [Data] {
		try sealLast(ControlLine.refused(refusal).line, at: instant)
	}

	/// pi² Remote's last messages to a phone whose claim to pair did not end paired (#881): the `pairRefused` line, then
	/// `bye`, padded as `sealRefusal` pads, so that its length tells the relay or the network nothing of the word.
	///
	/// The caller's duties (remotekit.md, "The pairRefused line"): call it only on a pairing channel whose claimer proved
	/// the code's secret and sent a claim, in place of `paired`; and refuse a `pairRefused` line from a phone.
	public func sealPairRefusal(_ refusal: PairRefusal, at instant: ContinuousClock.Instant = .now) throws -> [Data] {
		try sealLast(ControlLine.pairRefused(refusal).line, at: instant)
	}

	/// A last line, padded to 256 bytes whatever this end's padding, then `bye`.
	private func sealLast(_ line: Data, at instant: ContinuousClock.Instant) throws -> [Data] {
		let frames = try Lines.frames(for: line)
		return try state.withLock { state in
			try usable(state, at: instant)
			var messages = try frames.map { try Self.seal($0, &state, padTo: max(state.padding ?? 0, Frame.paddingBlock)) }
			messages.append(try Self.seal(Frame(.bye), &state))
			state.phase = .ended
			return messages
		}
	}

	private static func seal(_ frame: Frame, _ state: inout State, padTo block: Int? = nil) throws -> Data {
		do {
			return try state.transport.encrypt(frame.encoded(padTo: block ?? state.padding))
		} catch {
			state.phase = .failed
			throw error
		}
	}

	/// Reads one transport message from the other side.
	public func open(_ message: Data, at instant: ContinuousClock.Instant = .now) throws -> ChannelEvent? {
		try state.withLock { state in
			try usable(state, at: instant)
			do {
				let frame = try Frame.decode(state.transport.decrypt(message))
				switch frame.kind {
				case .data, .more:
					return try state.assembler.take(frame).map(ChannelEvent.line)
				case .ack:
					guard !state.assembler.isPartway else { throw RemoteKitError("channel", "an ack inside a line") }
					return .ack(frame.ackCount!)
				case .ping:
					return .ping
				case .bye:
					state.phase = .ended
					return .bye
				}
			} catch {
				state.phase = .failed
				throw error
			}
		}
	}

	public var description: String {
		let phase = state.withLock { $0.phase }
		return "channel, \(phase == .open ? "open" : phase == .ended ? "ended" : "failed")"
	}

	public var debugDescription: String { description }

	public var customMirror: Mirror { Mirror(self, children: ["state": description], displayStyle: .class) }
}
