import Darwin
import Dispatch
import Foundation
import RemoteKit

/// One TCP connection on the home path (docs/iphone.md 5.4): a Noise handshake, then a channel, each message preceded
/// by its length in two bytes (remotekit.md, "Framing").
///
/// - The first message must be exactly a first message's length before anything else is done: 48 bytes for a
///   connection (KK), 96 for a pairing (IKpsk2), and the latter only while a pairing window is open. Anything else, or
///   a first message over the listener's limits, closes the connection before any key agreement (#767's security read).
/// - A connection: the device is found by trial among pi² Remote's own list (`ChannelHandshake.respond`), at most a few
///   handshakes a minute for each device; the Mac proves itself with the engine's challenge; the phone's `attach` is
///   checked against the device key on the list, its build against the minimum, and passed to the engine as
///   `remote.attach` without `received`, which is pi² Remote's alone (3.4, 5.8).
/// - A pairing: the Mac proves itself with a challenge of its own; the claimer's `pair` is checked and passed to the
///   engine as `remote.pairClaim` with that exact challenge (3.3). A wrong pre-shared key shows only after the second
///   handshake message, so a wrong try is counted (`remote.pairWrong`) when the claimer's first transport message fails
///   to open, or when the connection closes or ten seconds pass after the second message with none; never for a
///   first handshake message that fails, or any peer on the network could close the window. Anyone who once saw a QR
///   code holds the Mac's channel key and the pairing's id, which outlive the window, and so can use up its three
///   tries: that blocks pairing until the person opens another window, and is no way in.
/// - Not attached, or not past its pairing claim, within ten seconds of being accepted: closed.
final class PhoneConnection: @unchecked Sendable {
	private enum Phase {
		case first
		/// A pairing channel, waiting for the claimer's first transport message.
		case pairing(Channel, challenge: Data)
		case claiming(Channel)
		case claimed(Channel, claim: String)
		/// A connection's channel, waiting for the engine's challenge, then for the phone's attach, then for the engine.
		case connecting(Channel)
		case awaitingAttach(Channel)
		case attaching(Channel)
		case attached(Channel, Session)
		/// Its session was closed by the engine: nothing more is taken from the phone, and the channel ends shortly,
		/// after a `revoked` line if the engine revokes the device (it closes the sessions first, then says `revoke`).
		case closing(Channel)
		case ended
	}

	private unowned let remote: Remote
	private let io: SocketIO
	let peer: IPAddress
	private var phase = Phase.first
	private var framing = LengthFraming()
	private var firstBytes = Data()
	private var admitted = true
	private var deadline: DispatchWorkItem?
	/// For counting a wrong pairing try: the second handshake message went, and no transport message opened yet.
	private var awaitingClaimerProof = false
	private(set) var device: DeviceID?
	/// Lines received in a session, and how far the last ack the Mac sent went (5.8).
	private var received: UInt64 = 0
	private var receivedBytesSinceAck = 0
	private var ackScheduled = false

	init(remote: Remote, descriptor: Int32, peer: IPAddress) {
		self.remote = remote
		self.peer = peer
		io = SocketIO(descriptor: descriptor, queue: remote.queue)
	}

	func start() {
		io.onBytes = { [unowned self] in self.take($0) }
		io.onClose = { [unowned self] in self.closed() }
		io.start()
		let deadline = DispatchWorkItem { [weak self] in self?.tooSlow() }
		self.deadline = deadline
		remote.queue.asyncAfter(deadline: .now() + remote.attachWithin, execute: deadline)
	}

	/// A pairing channel whose claimer has sent no claim yet: the one kind `closeJoin` ends. A claim passed to the engine
	/// is the engine's to answer (`paired` or `pairRefused`, or its refusal of `remote.pairClaim`); the engine closes the
	/// window before it says `paired`, so a claimed channel must outlive `closeJoin`.
	var isPairingBeforeClaim: Bool {
		if case .pairing = phase { return true }
		return false
	}

	private var channel: Channel? {
		switch phase {
		case let .pairing(channel, _), let .claiming(channel), let .claimed(channel, _), let .connecting(channel), let .awaitingAttach(channel),
		     let .attaching(channel), let .attached(channel, _), let .closing(channel):
			channel
		case .first, .ended:
			nil
		}
	}

	// ---- Reading

	private func take(_ bytes: Data) {
		if case .first = phase {
			firstBytes.append(bytes)
			firstMessage()
			return
		}
		do {
			for message in try framing.push(bytes) {
				try opened(message)
				if case .ended = phase { return }
			}
		} catch {
			end()
		}
	}

	/// The first message: its length decided before any of it is read, then exactly that many bytes.
	private func firstMessage() {
		guard firstBytes.count >= 2 else { return }
		let length = Int(firstBytes[firstBytes.startIndex]) << 8 | Int(firstBytes[firstBytes.startIndex + 1])
		let pairing = length == 96
		guard length == ChannelHandshake.connectionFirstMessageLength || (pairing && remote.openWindow != nil && remote.pairing != nil) else { return end() }
		guard firstBytes.count >= 2 + length else { return }
		// The initiator waits for the answer before it sends anything more.
		guard firstBytes.count == 2 + length else { return end() }
		guard remote.admission.firstMessage(from: peer, now: remote.now) else {
			Seldom.shared.say("first messages", "a first message from \(peer) over the listener's limits; closed")
			return end()
		}
		let message = Data(firstBytes[(firstBytes.startIndex + 2)...])
		firstBytes = Data()
		pairing ? startPairing(message) : startConnection(message)
	}

	private func startConnection(_ message: Data) {
		guard let pairing = remote.pairing else { return end() }
		let found: (DeviceID, ChannelHandshake)
		do {
			found = try ChannelHandshake.respond(toFirstMessage: message, pairing: pairing, channelKey: remote.keys.channel, devices: remote.channelKeys)
		} catch {
			Seldom.shared.say("no device", "a connection's first message from \(peer) was made for no paired device; closed")
			return end()
		}
		let (device, handshake) = found
		guard remote.admission.handshake(for: device.text, now: remote.now) else {
			log("more than \(Admission.handshakesPerDevicePerMinute) handshakes this minute for device \(device); closed")
			return end()
		}
		self.device = device
		guard let answer = try? handshake.writeMessage(), let channel = try? handshake.channel() else { return end() }
		send(answer)
		phase = .connecting(channel)
		remote.engine.request("remote.attachBegin") { [weak self] result in
			guard let self, case .connecting = self.phase else { return }
			guard case let .success(value) = result, let text = value["challenge"]?.stringValue, let challenge = Base64URL.decode(text, count: 32),
			      let proof = try? MacProof.make(challenge: challenge, pairing: pairing, binding: channel.handshakeHash, identity: self.remote.keys.identity)
			else { return self.end() }
			self.phase = .awaitingAttach(channel)
			self.sendLine(ControlLine.mac(proof).line)
		}
	}

	private func startPairing(_ message: Data) {
		guard let window = remote.openWindow, let pairing = remote.pairing,
		      let handshake = try? ChannelHandshake.pairingResponder(pairing: pairing, secret: window.secret, channelKey: remote.keys.channel)
		else { return end() }
		// A first message that fails is not counted: it proves nothing of the secret, and anyone could send one.
		guard (try? handshake.readMessage(message)) != nil, let answer = try? handshake.writeMessage(), let channel = try? handshake.channel() else { return end() }
		send(answer)
		awaitingClaimerProof = true
		let challenge = Bytes.random(32)
		phase = .pairing(channel, challenge: challenge)
		guard let proof = try? MacProof.make(challenge: challenge, pairing: pairing, binding: channel.handshakeHash, identity: remote.keys.identity) else { return end() }
		sendLine(ControlLine.mac(proof).line)
	}

	private func opened(_ message: Data) throws {
		guard let channel else { return end() }
		let event: ChannelEvent?
		do {
			event = try channel.open(message)
		} catch {
			// The claimer's first transport message did not open: a wrong pre-shared key (3.3).
			if awaitingClaimerProof { wrongTry("the claimer's first message did not open") }
			return end()
		}
		awaitingClaimerProof = false
		guard let event else { return }
		switch event {
		case .bye: return end()
		case .ping: return
		case let .ack(count):
			if case let .attached(_, session) = phase { session.acknowledged(count, by: self) }
		case let .line(line):
			heard(line, on: channel)
		}
	}

	private func heard(_ line: Data, on channel: Channel) {
		switch phase {
		case let .pairing(_, challenge): claim(line, channel: channel, challenge: challenge)
		case .awaitingAttach: attach(line, channel: channel)
		case let .attached(_, session): fromPhone(line, session: session)
		case .closing: return
		default: end()
		}
	}

	// ---- Pairing (3.3)

	private func claim(_ line: Data, channel: Channel, challenge: Data) {
		guard let pairing = remote.pairing, case let .pair(claim)? = try? ControlLine.parse(line) else { return end() }
		do {
			try claim.verify(pairing: pairing, binding: channel.handshakeHash, handshakeChannelKey: channel.remoteChannelKey)
		} catch {
			log("a pairing claim was not signed for this channel by the device key it names; closed")
			return end()
		}
		// The claim as the phone wrote it, passed on whole: the engine checks it again, with its attestation.
		guard let inner = (try? JSON.parse(line))?["pair"] else { return end() }
		phase = .claiming(channel)
		let params = JSONValue.object([
			("claim", inner), ("binding", .string(Base64URL.encode(channel.handshakeHash))), ("challenge", .string(Base64URL.encode(challenge))),
			("path", .string("home")),
		])
		remote.engine.request("remote.pairClaim", params) { [weak self] result in
			guard let self, case .claiming = self.phase else { return }
			switch result {
			case let .success(value):
				guard let id = value["claim"]?.stringValue else { return self.end() }
				self.phase = .claimed(channel, claim: id)
				self.remote.claims[id] = self
				self.passedFirstLines()
				log("a pairing claim waits for the digits on the Mac")
			case let .failure(refusal):
				log("the engine refused a pairing claim: \(refusal)")
				self.end()
			}
		}
	}

	private func wrongTry(_ why: String) {
		guard awaitingClaimerProof else { return }
		awaitingClaimerProof = false
		log("a wrong pairing try: \(why)")
		remote.engine.request("remote.pairWrong")
	}

	// ---- Attaching (3.4, 5.8)

	private func attach(_ line: Data, channel: Channel) {
		guard let pairing = remote.pairing, let device, let listed = remote.listed(device), case let .attach(claim)? = try? ControlLine.parse(line) else { return end() }
		do {
			try claim.verifyDevice(deviceKey: listed.deviceKey, pairing: pairing, device: device, binding: channel.handshakeHash)
		} catch {
			log("an attach for device \(device) is not signed by its device key on pi² Remote's own list; closed")
			return end()
		}
		if Remote.isBuild(claim.build), !Remote.buildAtLeast(claim.build, remote.minimumBuild) {
			log("device \(device) runs build \(claim.build), below the lowest this Mac attaches (\(remote.minimumBuild)); closed")
			return end()
		}
		phase = .attaching(channel)
		// `received` is pi² Remote's alone, for its buffer: the engine takes exactly these three fields (devices.ts).
		let attach = JSONValue.object([
			("signed", .string(claim.statement.text)), ("signature", .string(claim.statement.signatureText)), ("presence", .string(Base64URL.encode(claim.presence))),
		])
		let params = JSONValue.object([("attach", attach), ("binding", .string(Base64URL.encode(channel.handshakeHash))), ("path", .string(peer.path))])
		remote.engine.request("remote.attach", params) { [weak self] result in
			guard let self, case .attaching = self.phase else { return }
			guard case let .success(value) = result, let text = value["session"]?.stringValue, let session = SessionID(text), let resumed = value["resume"]?.boolValue else {
				if case let .failure(refusal) = result { log("the engine refused an attach of device \(device): \(refusal)") }
				return self.end()
			}
			self.passedFirstLines()
			channel.maxLineLength = Lines.defaultMaxLength
			guard self.remote.attached(self, device: device, session: session, resumed: resumed, received: claim.received) else { return self.end() }
		}
	}

	/// Called by the session it attached to: the phone is told, and the session's lines follow.
	func attachedTo(_ session: Session, resumed: Bool) {
		guard case let .attaching(channel) = phase else { return }
		phase = .attached(channel, session)
		sendLine(ControlLine.attached(Attached(session: session.id, resume: resumed)).line)
	}

	/// The connection is past its first lines: it no longer counts against the listener's limit, and has no deadline.
	private func passedFirstLines() {
		deadline?.cancel()
		deadline = nil
		if admitted {
			admitted = false
			remote.admission.release(peer)
		}
	}

	private func tooSlow() {
		switch phase {
		case .claimed, .attached, .closing, .ended: return
		default:
			wrongTry("no message from the claimer within ten seconds")
			end()
		}
	}

	// ---- A session's lines (4.1, 5.6, 5.8)

	private func fromPhone(_ line: Data, session: Session) {
		received += 1
		receivedBytesSinceAck += line.count
		// Every line is read strictly as one JSON object before it is put in a line to the engine, so that nothing in it
		// can end that line or name another session.
		guard let value = try? JSON.parse(line), case let .object(members) = value else {
			log("device \(session.device) sent a line that is not one JSON object; closed")
			return end()
		}
		if members.count == 1, members[0].0 == "sessionEnd" {
			remote.end(session, why: "the phone's session ended")
			return
		}
		remote.engine.send(session: session.id, message: line)
		if receivedBytesSinceAck >= 64 * 1024 {
			sendAck()
		} else if !ackScheduled {
			ackScheduled = true
			remote.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
				self?.ackScheduled = false
				self?.sendAck()
			}
		}
	}

	private func sendAck() {
		guard case let .attached(channel, _) = phase, let ack = try? channel.sealAck(received), let framed = try? LengthFraming.encode(ack) else { return }
		receivedBytesSinceAck = 0
		io.send(framed)
	}

	/// The session moved to another channel, or ended: this one is closed, at once or after `grace` seconds.
	func detach(grace: TimeInterval = 0) {
		guard case let .attached(channel, _) = phase else { return end() }
		guard grace > 0 else {
			phase = .attaching(channel)
			return end()
		}
		phase = .closing(channel)
		remote.queue.asyncAfter(deadline: .now() + grace) { [weak self] in self?.end() }
	}

	// ---- Writing

	private func send(_ handshakeMessage: Data) {
		guard let framed = try? LengthFraming.encode(handshakeMessage) else { return end() }
		io.send(framed)
	}

	/// A line on the channel, in as many frames as it takes.
	func sendLine(_ line: Data) {
		guard let channel, !io.isClosed else { return }
		do {
			for message in try channel.seal(line: line) { io.send(try LengthFraming.encode(message)) }
		} catch {
			return end()
		}
		// A phone that reads nothing does not make the Mac hold more: its session keeps what it needs for a resume.
		if io.pending > 16 * 1024 * 1024 { end() }
	}

	/// The Mac closed the pairing window: the channel ends, and that is no wrong try of the claimer's.
	func windowClosed() {
		awaitingClaimerProof = false
		end()
	}

	/// Ends the channel with `bye` and closes the connection.
	func end() {
		if case .ended = phase { return }
		if let channel, let bye = try? channel.sealBye(), let framed = try? LengthFraming.encode(bye) { io.send(framed) }
		io.finish()
	}

	private func closed() {
		let was = phase
		phase = .ended
		deadline?.cancel()
		if admitted {
			admitted = false
			remote.admission.release(peer)
		}
		if awaitingClaimerProof { wrongTry("the claimer closed the connection before its first message") }
		switch was {
		case let .claimed(_, claim): remote.claims.removeValue(forKey: claim)
		case let .attached(_, session): session.lost(self)
		default: break
		}
		remote.forget(self)
	}
}

/// A device session as pi² Remote holds it (5.8): the engine's lines it sent the phone that the phone has not
/// acknowledged, up to `sessionBufferLimit`; kept 60 seconds after the channel drops, for a resume on a new channel by
/// either path; then ended, and the engine told (`remote.sessionEnd`).
package final class Session: @unchecked Sendable {
	private unowned let remote: Remote
	package let id: SessionID
	package let device: DeviceID
	private var connection: PhoneConnection?
	private var lines: [(index: UInt64, line: Data)] = []
	private var bytes = 0
	/// Lines the engine sent this session, in all.
	package private(set) var sent: UInt64 = 0
	/// The most the phone has said it received.
	package private(set) var acked: UInt64 = 0
	/// Lines up to this count were let go before the phone acknowledged them: a resume from below it cannot be served.
	private var lostThrough: UInt64 = 0
	private var lapse: DispatchWorkItem?

	init(remote: Remote, id: SessionID, device: DeviceID) {
		self.remote = remote
		self.id = id
		self.device = device
	}

	package var isAttached: Bool { connection != nil }
	package var bufferedBytes: Int { bytes }

	func attach(_ connection: PhoneConnection) {
		lapse?.cancel()
		lapse = nil
		self.connection = connection
		connection.attachedTo(self, resumed: false)
	}

	/// The phone resumed on `connection`, having received `received` lines: what it has not had is sent again.
	func resume(on connection: PhoneConnection, received: UInt64) -> Bool {
		guard received <= sent, received >= lostThrough else {
			remote.end(self, why: "the phone asked to resume from a line this session no longer holds")
			return false
		}
		lapse?.cancel()
		lapse = nil
		if let old = self.connection, old !== connection {
			self.connection = nil
			old.detach()
		}
		acknowledged(received, by: nil)
		self.connection = connection
		connection.attachedTo(self, resumed: true)
		for (_, line) in lines { connection.sendLine(line) }
		return true
	}

	func fromEngine(_ line: Data) {
		sent += 1
		lines.append((sent, line))
		bytes += line.count
		while bytes > remote.sessionBufferLimit, let oldest = lines.first {
			lines.removeFirst()
			bytes -= oldest.line.count
			lostThrough = oldest.index
		}
		if let connection {
			connection.sendLine(line)
		} else if lostThrough > acked {
			remote.end(self, why: "its phone was away and its lines passed what a session keeps")
		}
	}

	func acknowledged(_ count: UInt64, by sender: PhoneConnection?) {
		if let sender, sender !== connection { return }
		guard count <= sent, count > acked || sender == nil else { return }
		acked = max(acked, count)
		while let first = lines.first, first.index <= count {
			lines.removeFirst()
			bytes -= first.line.count
		}
	}

	/// Its channel dropped: kept for a resume, unless lines it no longer holds are owed.
	func lost(_ from: PhoneConnection) {
		guard connection === from else { return }
		connection = nil
		if lostThrough > acked {
			remote.end(self, why: "its channel dropped owing lines it no longer holds")
			return
		}
		let lapse = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.remote.end(self, why: "no resume within \(Int(self.remote.resumeWindow)) seconds")
		}
		self.lapse = lapse
		remote.queue.asyncAfter(deadline: .now() + remote.resumeWindow, execute: lapse)
	}

	/// The session is over: its channel, if any, is ended, at once or after `grace` seconds.
	func closed(grace: TimeInterval = 0) {
		lapse?.cancel()
		lapse = nil
		lines.removeAll()
		bytes = 0
		let connection = self.connection
		self.connection = nil
		connection?.detach(grace: grace)
	}
}
