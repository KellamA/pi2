import CryptoKit
import Darwin
import Foundation
import RemoteKit

/// A line-at-a-time reader of a blocking socket, with a deadline for each line.
final class LineReader {
	let descriptor: Int32
	private var buffer = Data()
	private(set) var closed = false

	init(descriptor: Int32) { self.descriptor = descriptor }

	/// How far `buffer` is known to hold no line break, so that a long line is searched once, not once a read.
	private var scanned = 0

	/// The next line, or nil if none came within `seconds` or the socket closed.
	func next(within seconds: Double = 30) -> Data? {
		let deadline = Date().addingTimeInterval(seconds)
		while true {
			if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
				let line = Data(buffer[buffer.startIndex ..< newline])
				buffer = Data(buffer[(newline + 1)...])
				scanned = 0
				return line
			}
			scanned = buffer.count
			let left = deadline.timeIntervalSinceNow
			guard !closed, left > 0, readable(descriptor, within: left) else { return nil }
			var chunk = [UInt8](repeating: 0, count: 65536)
			let count = read(descriptor, &chunk, chunk.count)
			if count <= 0 {
				closed = true
				return nil
			}
			buffer.append(contentsOf: chunk[0 ..< count])
		}
	}

	func write(_ data: Data) {
		var line = data
		line.append(0x0A)
		writeAll(descriptor, line)
	}
}

/// Writes all of `data`, as many writes as it takes; false if the socket refused (or, with a send timeout, stayed full).
@discardableResult
func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
	data.withUnsafeBytes { bytes in
		var offset = 0
		while offset < bytes.count {
			let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
			if count > 0 {
				offset += count
			} else if count < 0, errno == EINTR {
				continue
			} else {
				return false
			}
		}
		return true
	}
}

/// The check as the engine: its end of the socket pair pi² Remote is started on (engine/src/remote.ts's side).
final class FakeEngine {
	let lines: LineReader
	/// Requests and lines heard while waiting for something else, in order.
	private var heard: [JSONValue] = []
	private var sessionLines: [(String, Data)] = []

	init(descriptor: Int32) { lines = LineReader(descriptor: descriptor) }

	func event(_ kind: String, _ fields: [(String, JSONValue)] = []) {
		lines.write(JSON.write(.object([("event", .string("remote")), ("kind", .string(kind))] + fields)))
	}

	func answer(_ id: JSONValue, _ result: JSONValue = .object([])) {
		lines.write(JSON.write(.object([("id", id), ("result", result)])))
	}

	func refuse(_ id: JSONValue, _ why: String) {
		lines.write(JSON.write(.object([("id", id), ("error", .string(why))])))
	}

	/// A line of the engine's to a session, as remote.ts writes it.
	func toSession(_ session: String, _ message: String) {
		lines.write(Data("{\"session\":\"\(session)\",\"message\":\(message)}".utf8))
	}

	private func read(within seconds: Double) -> Bool {
		guard let line = lines.next(within: seconds) else { return false }
		if line.starts(with: Data(#"{"session":"#.utf8)) {
			let value = try? JSON.parse(line)
			sessionLines.append((value?["session"]?.stringValue ?? "", line))
		} else if let value = try? JSON.parse(line) {
			heard.append(value)
		} else {
			heard.append(.string("not JSON: \(String(decoding: line, as: UTF8.self))"))
		}
		return true
	}

	/// The next request pi² Remote sends with `method`, skipping none: anything else heard first is a failure.
	func request(_ method: String, within seconds: Double = 30) -> (id: JSONValue, params: JSONValue)? {
		let deadline = Date().addingTimeInterval(seconds)
		while true {
			if let index = heard.firstIndex(where: { $0["method"]?.stringValue != nil }) {
				let value = heard.remove(at: index)
				guard value["method"]?.stringValue == method else {
					Check.expect(false, "pi² Remote sent \(method) next", "it sent \(value["method"]?.stringValue ?? "?")")
					return nil
				}
				return (value["id"] ?? .null, value["params"] ?? .object([]))
			}
			guard read(within: max(0, deadline.timeIntervalSinceNow)) else { return nil }
		}
	}

	/// Whether pi² Remote sends any request within `seconds`.
	func quiet(for seconds: Double) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while deadline.timeIntervalSinceNow > 0 {
			if heard.contains(where: { $0["method"] != nil }) { return false }
			_ = read(within: deadline.timeIntervalSinceNow)
		}
		return !heard.contains(where: { $0["method"] != nil })
	}

	/// The next device line pi² Remote passes on, as its whole control line.
	func sessionLine(within seconds: Double = 30) -> (String, Data)? {
		let deadline = Date().addingTimeInterval(seconds)
		while sessionLines.isEmpty {
			guard read(within: max(0, deadline.timeIntervalSinceNow)) else { return nil }
		}
		return sessionLines.removeFirst()
	}
}

/// The check as a phone: a TCP connection to the home listener, a Noise handshake made with RemoteKit, then a channel.
final class Phone {
	let descriptor: Int32
	private var framing = LengthFraming()
	private var messages: [Data] = []
	private(set) var closed = false
	var channel: Channel?
	/// Lines the phone has received on this channel.
	private(set) var received: UInt64 = 0

	init?(port: UInt16, address: String = "127.0.0.1") {
		descriptor = socket(AF_INET, SOCK_STREAM, 0)
		var target = sockaddr_in()
		target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		target.sin_family = sa_family_t(AF_INET)
		target.sin_port = port.bigEndian
		target.sin_addr.s_addr = inet_addr(address)
		let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
		var on: Int32 = 1
		setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		if connected != 0 {
			close(descriptor)
			return nil
		}
	}

	deinit { if !closed { close(descriptor) } }

	@discardableResult
	func raw(_ bytes: Data) -> Bool { writeAll(descriptor, bytes) }

	@discardableResult
	func send(_ message: Data) -> Bool { raw(try! LengthFraming.encode(message)) }

	/// The next whole message, or nil within `seconds` or once closed.
	func message(within seconds: Double = 30) -> Data? {
		let deadline = Date().addingTimeInterval(seconds)
		while messages.isEmpty {
			let left = deadline.timeIntervalSinceNow
			guard !closed, left > 0, readable(descriptor, within: left) else { return nil }
			var chunk = [UInt8](repeating: 0, count: 65536)
			let count = read(descriptor, &chunk, chunk.count)
			if count <= 0 {
				closed = true
				return nil
			}
			guard let found = try? framing.push(Data(chunk[0 ..< count])) else {
				closed = true
				return nil
			}
			messages += found
		}
		return messages.removeFirst()
	}

	/// Whether the other side closed the connection within `seconds` (after any messages still to come).
	func closesWithin(_ seconds: Double = 30) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while deadline.timeIntervalSinceNow > 0 {
			if message(within: deadline.timeIntervalSinceNow) == nil { return closed }
		}
		return closed
	}

	/// The next channel event; acks and pings are taken in passing.
	func event(within seconds: Double = 30) -> ChannelEvent? {
		guard let channel else { return nil }
		let deadline = Date().addingTimeInterval(seconds)
		while let message = message(within: max(0, deadline.timeIntervalSinceNow)) {
			// `open` gives nil for a frame that is not yet a whole line: read on. A `try?` here would take that for the end.
			let opened: ChannelEvent?
			do {
				opened = try channel.open(message)
			} catch {
				return nil
			}
			guard let event = opened else { continue }
			switch event {
			case .line:
				received += 1
				return event
			case .bye: return .bye
			case .ack, .ping: continue
			}
		}
		return nil
	}

	func line(within seconds: Double = 30) -> Data? {
		if case let .line(line)? = event(within: seconds) { return line }
		return nil
	}

	@discardableResult
	func sendLine(_ line: Data) -> Bool {
		guard let channel else { return false }
		for message in try! channel.seal(line: line) where !send(message) { return false }
		return true
	}

	/// Writes give up after `seconds` on a full socket, so that a phone held back by the Mac does not hold the check.
	func sendTimeout(_ seconds: Int) {
		var limit = timeval(tv_sec: seconds, tv_usec: 0)
		setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
	}

	func sendAck(_ count: UInt64) {
		guard let channel else { return }
		send(try! channel.sealAck(count))
	}

	func end() {
		closed = true
		close(descriptor)
	}
}

/// The keys a phone makes at pairing (3.2), in software.
struct PhoneKeys {
	let device = P256.Signing.PrivateKey()
	let presence = P256.Signing.PrivateKey()
	let channel = Curve25519.KeyAgreement.PrivateKey()
	let record = P256.KeyAgreement.PrivateKey()
	let keyId = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
	var build = "7"

	func description(name: String = "Check iPhone") -> DeviceDescription {
		DeviceDescription(
			name: name, model: "iPhone 17 Pro", system: "iOS 27.1", build: build, deviceKey: device.publicKey, presenceKey: presence.publicKey,
			channelKey: channel.publicKey, recordKey: record.publicKey)
	}

	/// The engine's stand-in for App Attest (PI2_APP_ATTEST_STAND_IN in devices.ts): JSON naming what App Attest would
	/// have checked.
	func attestation(challenge: Data, binding: Data, team: String) -> Data {
		let hash = PairingSecrets.attestationClientDataHash(challenge: challenge, deviceKey: device.publicKey, binding: binding)
		return JSON.write(.object([
			("standIn", .string("pi2-app-attest")), ("appId", .string("\(team).dev.pi2.ios")), ("keyId", .string(keyId)),
			("clientDataHash", .string(Base64URL.encode(hash))), ("environment", .string("development")), ("validationCategory", .integer(3)),
			("bundleVersion", .string(build)),
		]))
	}

	/// The engine's record of the device, as its `paired` event gives pi² Remote.
	func paired(id: DeviceID) -> JSONValue {
		.object([
			("id", .string(id.text)), ("deviceKey", .string(PublicKeys.text(device.publicKey))), ("presenceKey", .string(PublicKeys.text(presence.publicKey))),
			("channelKey", .string(PublicKeys.text(channel.publicKey))), ("recordKey", .string(PublicKeys.text(record.publicKey))), ("attestKeyId", .string(keyId)),
		])
	}
}

extension Phone {
	/// Pairs over this connection: the IKpsk2 handshake with `payload`'s secret, the Mac's proof, the claim. Returns the
	/// channel's binding and the Mac's challenge, or nil when the handshake failed.
	func pair(payload: PairingPayload, keys: PhoneKeys, team: String) -> (binding: Data, challenge: Data, claimLine: Data)? {
		let handshake = try! ChannelHandshake.pairingInitiator(payload: payload, channelKey: keys.channel)
		send(try! handshake.writeMessage())
		guard let answer = message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel() else { return nil }
		self.channel = channel
		guard let proofLine = line(), case let .mac(proof)? = try? ControlLine.parse(proofLine) else { return nil }
		Check.expect((try? proof.verify(identityKey: payload.identityKey, pairing: payload.pairing, binding: channel.handshakeHash)) != nil, "the Mac's proof on a pairing channel is signed by the identity key in the payload")
		let claim = try! PairClaim.make(
			device: keys.description(), attestation: keys.attestation(challenge: proof.challenge, binding: channel.handshakeHash, team: team), keyId: keys.keyId,
			pairing: payload.pairing, binding: channel.handshakeHash, deviceKey: keys.device)
		let line = ControlLine.pair(claim).line
		sendLine(line)
		return (channel.handshakeHash, proof.challenge, line)
	}

	/// Opens a connection's channel (KK) as `device`; returns the Mac's challenge, checked against `identity`.
	func connect(pairing: PairingID, device: DeviceID, keys: PhoneKeys, macChannel: Curve25519.KeyAgreement.PublicKey, identity: P256.Signing.PublicKey) -> Data? {
		let handshake = try! ChannelHandshake.connection(initiator: true, pairing: pairing, device: device, channelKey: keys.channel, remoteChannelKey: macChannel)
		send(try! handshake.writeMessage())
		guard let answer = message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel(maxLineLength: Lines.defaultMaxLength) else { return nil }
		self.channel = channel
		guard let proofLine = line(), case let .mac(proof)? = try? ControlLine.parse(proofLine),
		      (try? proof.verify(identityKey: identity, pairing: pairing, binding: channel.handshakeHash)) != nil
		else { return nil }
		return proof.challenge
	}

	/// Sends an attach, afresh or resuming, and reads `attached`.
	func attach(pairing: PairingID, device: DeviceID, keys: PhoneKeys, challenge: Data, session: SessionID? = nil, received: UInt64? = nil, signer: P256.Signing.PrivateKey? = nil) -> Attached? {
		let claim = try! AttachClaim.make(
			pairing: pairing, device: device, session: session, received: received, binding: channel!.handshakeHash, challenge: challenge, build: keys.build,
			deviceKey: signer ?? keys.device, presenceKey: keys.presence)
		sendLine(ControlLine.attach(claim).line)
		guard let line = line(), case let .attached(attached)? = try? ControlLine.parse(line) else { return nil }
		// The session's lines are counted from here: the channel's own first lines are not the session's (5.8).
		self.received = 0
		return attached
	}
}

/// The check's own end of a Unix socket pair, and the end to give a child as descriptor 3.
func socketPair() -> (mine: Int32, theirs: Int32) {
	var ends: [Int32] = [0, 0]
	guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { Check.stop("a socket pair could not be made") }
	var on: Int32 = 1
	setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	return (ends[0], ends[1])
}
