import Darwin
import Dispatch
import Foundation
import RemoteKit

/// One phone's connection, on either path (docs/iphone.md 5.1): a TCP connection on the home or direct path (5.4), each
/// Noise message preceded by its length in two bytes, or a device's slot at the relay (5.3), each Noise message one
/// WebSocket message (remotekit.md, "Framing"). Which it is is its link's (`PhoneLink`) and its route's: everything
/// below is the same code for both, so that no check exists on one path only.
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
/// The fixed words the engine gives beside its own for a phone (#818, #881), read byte for byte; its words are never read.
package enum EngineWords {
	/// The reasons the engine may give for refusing `remote.attach` (`data.reason`): `resume` is pi² Remote's own, and
	/// anything else is no reason.
	package static func attachRefusal(_ word: String?) -> Refusal.Reason? {
		guard let word else { return nil }
		return [Refusal.Reason.update, .suspended, .presence, .clock].first { $0.rawValue.utf8.elementsEqual(word.utf8) }
	}

	/// The words the engine's `pairRefused` event may carry for the phone (`reason`).
	package static func pairRefusal(_ word: String?) -> PairRefusal.Why? {
		guard let word else { return nil }
		return PairRefusal.Why.allCases.first { $0.rawValue.utf8.elementsEqual(word.utf8) }
	}
}

final class PhoneConnection: @unchecked Sendable {
	private enum Phase {
		case first
		/// A pairing channel, waiting for the claimer's first transport message.
		case pairing(Channel, challenge: Data)
		case claiming(Channel)
		case claimed(Channel, claim: String)
		/// A connection's channel, waiting for the engine's challenge, then for the phone's attach, then for the engine.
		case connecting(Channel)
		case awaitingAttach(Channel, challenge: Data)
		case attaching(Channel)
		case attached(Channel, Session)
		/// Its session was closed by the engine: nothing more is taken from the phone, and the channel ends shortly,
		/// after a `revoked` line if the engine revokes the device (it closes the sessions first, then says `revoke`).
		case closing(Channel)
		case ended
	}

	private unowned let remote: Remote
	private let link: any PhoneLink
	/// Where it came from: a TCP peer, or a slot the relay named.
	let route: PhoneRoute
	/// The limits it is counted under before it authenticates: the home listener's, or the relay path's own.
	let admission: Admission
	/// The source it is counted under while it waits to authenticate, as it was when it was admitted.
	let admissionKey: IPAddress
	let acceptedAt = ContinuousClock.now
	private var phase = Phase.first
	private var admitted = true
	private var deadline: DispatchWorkItem?
	/// For counting a wrong pairing try: the second handshake message went, and no transport message opened yet.
	private var awaitingClaimerProof = false
	/// The claimer's first transport message opened, so it holds the code's secret; and whether the engine has heard of
	/// its try (a claim, or `remote.pairWrong`). One that proved the secret and ends before a claim reaches the engine
	/// is counted (#675's security read B, M3).
	private var claimerProven = false
	private var claimReported = false
	private(set) var device: DeviceID?
	/// Lines received in a session, and how far the last ack the Mac sent went (5.8).
	private var received: UInt64 = 0
	private var receivedBytesSinceAck = 0
	private var ackScheduled = false

	init(remote: Remote, link: any PhoneLink, route: PhoneRoute, admission: Admission, admissionKey: IPAddress) {
		self.remote = remote
		self.link = link
		self.route = route
		self.admission = admission
		self.admissionKey = admissionKey
	}

	/// The TCP peer, on the home or direct path; nil at the relay.
	var peer: IPAddress? {
		if case let .tcp(peer, _) = route { return peer }
		return nil
	}

	/// The interface it came by, when that matters (a peer in the shared address space, D2).
	var arrivedOn: String? {
		if case let .tcp(_, arrivedOn) = route { return arrivedOn }
		return nil
	}

	/// The slot the relay named for it, on the relay path.
	var relaySlot: DeviceID? {
		if case let .relay(slot) = route { return slot }
		return nil
	}

	/// The relay's link, on the relay path: the slot it answers under moves to the engine's id once the device is added.
	var relayLink: RelayLink? { link as? RelayLink }

	/// The path the engine is told: `home` or `direct` by the peer's address (`IPAddress.path`), or `relay`.
	var path: String { peer?.path ?? "relay" }

	/// Who sent its first message, for the log.
	private var from: String { peer.map { "\($0)" } ?? "the relay" }

	/// How long a claim the engine holds may wait for `paired` or `pairRefused`: the window's five minutes and one more,
	/// and once the window has closed (`closeJoin`, which the engine sends just before `paired`), 30 seconds.
	static let claimWithin: TimeInterval = 6 * 60
	static let answerAfterCloseJoin: TimeInterval = 30
	/// How long an attach may wait for the engine's answer.
	static let attachWithin: TimeInterval = 60

	func start() {
		link.onMessage = { [unowned self] in self.take($0) }
		link.acceptsFirst = { [unowned self] in self.acceptsFirst(length: $0) }
		link.onBroken = { [unowned self] in self.end() }
		link.onClose = { [unowned self] in self.closed() }
		link.start()
		let deadline = DispatchWorkItem { [weak self] in self?.tooSlow() }
		self.deadline = deadline
		remote.queue.asyncAfter(deadline: .now() + remote.attachWithin, execute: deadline)
		// The first message has a short deadline of its own: a phone sends it at once (D1).
		remote.queue.asyncAfter(deadline: .now() + Admission.firstMessageWithin) { [weak self] in
			guard let self, case .first = self.phase else { return }
			self.end()
		}
	}

	/// A claim passed to the engine, waiting for its answer.
	var isClaim: Bool {
		switch phase {
		case .claiming, .claimed: true
		default: false
		}
	}

	/// Ends the channel `seconds` from now if its claim has still had no answer; no try is counted (it reached the engine).
	func endIfUnanswered(after seconds: TimeInterval) {
		remote.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
			guard let self, self.isClaim else { return }
			log("a claim had no answer within \(Int(seconds)) seconds of the window closing; its channel is closed")
			self.end()
		}
	}

	/// Accepted, and no first message yet: the kind of connection the listener lets go first when too many wait (D1).
	var waitingForFirstMessage: Bool {
		if case .first = phase { return admitted }
		return false
	}

	func pauseReading() { link.pauseReading() }
	func resumeReading() { link.resumeReading() }

	/// Attached, so its lines feed the engine: the only kind back-pressure pauses (#675's security read B, M2c). One
	/// not yet attached (a handshake, a claim, an attach) is always read, so that a phone held back by another's large
	/// message, or a claimer mid-pairing, is never cut by its own deadline.
	var isAttached: Bool {
		if case .attached = phase { return true }
		return false
	}

	/// When it attached, for keeping a device's newest two (M1b).
	private(set) var attachedAt = ContinuousClock.now

	/// What waits to be written to the phone.
	var queued: Int { link.pending }

	/// The line the phone has begun and not finished, as pi² Remote times it (#908); nil between lines.
	private(set) var unfinished: UnfinishedLine?

	/// How much of a line its channel holds, begun and not finished (#908).
	var unfinishedHeld: Int { channel?.unfinishedLineLength ?? 0 }

	/// A pairing channel whose claimer has sent no claim yet: the one kind `closeJoin` ends. A claim passed to the engine
	/// is the engine's to answer (`paired` or `pairRefused`, or its refusal of `remote.pairClaim`); the engine closes the
	/// window before it says `paired`, so a claimed channel must outlive `closeJoin`.
	var isPairingBeforeClaim: Bool {
		if case .pairing = phase { return true }
		return false
	}

	private var channel: Channel? {
		switch phase {
		case let .pairing(channel, _), let .claiming(channel), let .claimed(channel, _), let .connecting(channel), let .awaitingAttach(channel, _),
		     let .attaching(channel), let .attached(channel, _), let .closing(channel):
			channel
		case .first, .ended:
			nil
		}
	}

	// ---- Reading

	/// A whole Noise message from the link, whichever path it came by.
	private func take(_ message: Data) {
		if case .first = phase { return firstMessage(message) }
		do {
			try opened(message)
		} catch {
			end()
		}
	}

	/// Whether a first message of this length is taken, decided before any of it is read (on TCP, before its bytes are
	/// held): a connection's (48 bytes), or a pairing's (96) while a window is open.
	private func acceptsFirst(length: Int) -> Bool {
		length == ChannelHandshake.connectionFirstMessageLength || (length == 96 && remote.openWindow != nil && remote.pairing != nil)
	}

	/// The first message, of a length `acceptsFirst` took: counted against the limits of its path before any key
	/// agreement.
	private func firstMessage(_ message: Data) {
		guard acceptsFirst(length: message.count) else { return end() }
		guard admission.firstMessage(from: source, now: remote.now) else {
			Seldom.shared.say("\(path) first messages", "a first message from \(from) over its path's limits; closed")
			return end()
		}
		message.count == 96 ? startPairing(message) : startConnection(message)
	}

	/// What the limits count it under: the peer's address, or the relay's slot (`Admission.relaySource`).
	private var source: IPAddress { peer ?? admissionKey }

	private func startConnection(_ message: Data) {
		guard let pairing = remote.pairing else { return end() }
		// A first message seen before from a device is a replay: it would only use up that device's handshakes (D1).
		guard !admission.replayed(message, now: remote.now) else {
			Seldom.shared.say("\(path) replay", "a connection's first message from \(from) was one seen before (a replay); closed")
			return end()
		}
		let found: (DeviceID, ChannelHandshake)
		do {
			// At the relay, only the device whose slot the bytes came under: its handshake's prologue names it, so the relay
			// cannot hand one device's channel to another's slot (remotekit.md, ".data(from:) goes to that device's channel").
			let candidates = relaySlot.map { slot in remote.channelKeys.filter { $0.0 == slot } } ?? remote.channelKeys
			found = try ChannelHandshake.respond(toFirstMessage: message, pairing: pairing, channelKey: remote.keys.channel, devices: candidates)
		} catch {
			admission.unknownFirstMessage(now: remote.now)
			Seldom.shared.say("\(path) no device", "a connection's first message from \(from) was made for no paired device; closed")
			return end()
		}
		admission.remember(message, now: remote.now)
		let (device, handshake) = found
		guard admission.handshake(for: device.text, now: remote.now) else {
			Seldom.shared.say("\(path) handshakes", "more than \(Admission.handshakesPerDevicePerMinute) handshakes this minute for device \(device); closed")
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
			self.phase = .awaitingAttach(channel, challenge: challenge)
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
			// A line longer than the channel takes (`LineAssembler.take`): said, by its limit alone, at most once a minute
			// for each device (#919), never what it held. Its length is not known: the frame that passed it was not kept.
			if error as? RemoteKitError == RemoteKitError("line", "longer than allowed") {
				let who = device.map { "device \($0)" } ?? "a phone not yet paired"
				Seldom.shared.say("overlong \(device?.text ?? "")", "a line from \(who) passed the \(channel.maxLineLength) bytes its channel takes; its connection closed")
			}
			return end()
		}
		if awaitingClaimerProof { claimerProven = true }
		awaitingClaimerProof = false
		// A line begun and not finished (#908): timed from its first piece, again at each piece that adds to it (never at a
		// ping), and counted with every phone's, which may end this connection or another.
		let held = channel.unfinishedLineLength
		if held == 0 {
			unfinished = nil
		} else if held != unfinished?.held {
			let now = remote.lineClock
			unfinished = UnfinishedLine(began: unfinished?.began ?? now, grew: now, held: held)
			remote.watchLines()
			remote.keepLinesWithinBudget()
			if case .ended = phase { return }
		}
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
		case let .awaitingAttach(_, challenge): attach(line, channel: channel, challenge: challenge)
		case let .attached(_, session): fromPhone(line, session: session)
		case .closing: return
		default: end()
		}
	}

	// ---- Pairing (3.3)

	/// A claimer that holds the code's secret, and whose claim pi² Remote refuses itself (not a `pair` line, or one not
	/// signed for this channel by the device key it names, or naming another channel key than the handshake proved), is
	/// counted as a wrong try when the channel ends (`closed`): the engine hears of it. The engine has no request that
	/// closes the window at once for a claim pi² Remote refused; one is named for #776 (`remote.pairRefused`).
	/// What the engine hears of a claimer that proved the secret (#776's 28): a `pair` line pi² Remote can read and check
	/// goes on as `remote.pairClaim`; one not signed for this channel, or naming another channel key than the handshake
	/// proved, is `remote.pairRefused` `not-bound`; a first line that is not `pair` at all, `not-pair`; and a `pair` line
	/// RemoteKit cannot read goes on as `remote.pairClaim` too, for the engine to refuse in its own words, unless it names
	/// a channel key, which must then be this channel's. Each closes the window, as 3.3 step 5 asks.
	private func claim(_ line: Data, channel: Channel, challenge: Data) {
		guard let pairing = remote.pairing, let value = try? JSON.parse(line), value.keys?.count == 1, let inner = value["pair"] else {
			log("a claimer holding the code sent a first line that is not a claim to pair; closed")
			refusedClaim("not-pair")
			return end()
		}
		if case let .pair(claim)? = try? ControlLine.parse(line, from: .phone) {
			do {
				try claim.verify(pairing: pairing, binding: channel.handshakeHash, handshakeChannelKey: channel.remoteChannelKey)
			} catch {
				log("a pairing claim was not signed for this channel by the device key it names; closed")
				refusedClaim("not-bound")
				return end()
			}
		} else if let named = inner["device"]?["channelKey"]?.stringValue, !named.utf8.elementsEqual(Base64URL.encode(channel.remoteChannelKey).utf8) {
			log("a pairing claim names another channel key than its handshake's; closed")
			refusedClaim("not-bound")
			return end()
		}
		// The first pairing's home key, kept before the claim goes on (#675's security read, S2): if it cannot be, the claim
		// is refused while the window is open, and the engine pairs nothing. The engine is told `not-kept` (#887), which
		// closes the window in those words, and the phone `pairRefused` `unsaved` (#881).
		guard remote.keyForClaim() else {
			log("a pairing claim was refused: the home key could not be kept")
			refusedClaim("not-kept")
			return refusePairing(.unsaved)
		}
		// The claim as the phone wrote it, passed on whole: the engine checks it again, with its attestation.
		phase = .claiming(channel)
		claimReported = true
		// With the engine now: its answer, not the ten seconds, decides; bounded by the window's own time.
		deadline?.cancel()
		deadline = nil
		remote.queue.asyncAfter(deadline: .now() + Self.claimWithin) { [weak self] in
			guard let self else { return }
			switch self.phase {
			case .claiming, .claimed:
				log("a claim the engine took had no answer within \(Int(Self.claimWithin / 60)) minutes; its channel is closed")
				self.end()
			default: break
			}
		}
		let params = JSONValue.object([
			("claim", inner), ("binding", .string(Base64URL.encode(channel.handshakeHash))), ("challenge", .string(Base64URL.encode(challenge))),
			("path", .string(relaySlot == nil ? "home" : "relay")),
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

	/// A claim that did not decrypt: a wrong secret, one of the window's three tries (`remote.pairWrong`).
	private func wrongTry(_ why: String) {
		guard awaitingClaimerProof else { return }
		awaitingClaimerProof = false
		claimReported = true
		log("a wrong pairing try: \(why)")
		remote.engine.request("remote.pairWrong")
	}

	/// A claimer that proved the secret and whose claim never reaches the engine: `remote.pairRefused`, which closes the
	/// window as a refused claim does (#776's 28). `why` is `not-pair`, `not-bound` or `silent`, or `not-kept` when
	/// pi² Remote could not keep the home key (#887).
	private func refusedClaim(_ why: String) {
		guard claimerProven, !claimReported else { return }
		claimReported = true
		log("a claimer holding the code was refused (\(why)); the window closes")
		remote.engine.request("remote.pairRefused", .object([("why", .string(why))]))
	}

	// ---- Attaching (3.4, 5.8)

	private func attach(_ line: Data, channel: Channel, challenge: Data) {
		guard let pairing = remote.pairing, let device, let listed = remote.listed(device), case let .attach(claim)? = try? ControlLine.parse(line, from: .phone) else { return end() }
		do {
			try claim.verifyDevice(deviceKey: listed.deviceKey, pairing: pairing, device: device, binding: channel.handshakeHash)
		} catch {
			log("an attach for device \(device) is not signed by its device key on pi² Remote's own list; closed")
			return end()
		}
		// The challenge this channel was given, exactly: the engine takes any it issued and has not seen used.
		guard Bytes.constantTimeEqual(claim.challenge, challenge) else {
			log("an attach for device \(device) names another challenge than this channel's; closed")
			return end()
		}
		guard Remote.isBuild(claim.build) else {
			log("device \(device) runs a build that is not one the engine reads; closed")
			return end()
		}
		// Signed by the device key on pi² Remote's own list, for this channel: the phone may be told why (#820).
		guard Remote.buildAtLeast(claim.build, remote.minimumBuild) else {
			log("device \(device) runs a build below the lowest this Mac attaches (\(remote.minimumBuild)); refused update")
			return refuse(.update)
		}
		phase = .attaching(channel)
		deadline?.cancel()
		deadline = nil
		// With the engine now, which answers at once; a minute at most, so that its waiting slot is not held for good.
		remote.queue.asyncAfter(deadline: .now() + Self.attachWithin) { [weak self] in
			guard let self, case .attaching = self.phase else { return }
			log("an attach had no answer from the engine within \(Int(Self.attachWithin)) seconds; its channel is closed")
			self.end()
		}
		// `received` is pi² Remote's alone, for its buffer: the engine takes exactly these three fields (devices.ts).
		let attach = JSONValue.object([
			("signed", .string(claim.statement.text)), ("signature", .string(claim.statement.signatureText)), ("presence", .string(Base64URL.encode(claim.presence))),
		])
		let params = JSONValue.object([("attach", attach), ("binding", .string(Base64URL.encode(channel.handshakeHash))), ("path", .string(path))])
		remote.engine.request("remote.attach", params) { [weak self] result in
			guard let self, case .attaching = self.phase else { return }
			guard case let .success(value) = result, let text = value["session"]?.stringValue, let session = SessionID(text), let resumed = value["resume"]?.boolValue else {
				if case let .failure(refusal) = result {
					log("the engine refused an attach of device \(device): \(refusal)")
					// The engine's fixed word beside its words (#818), never its words: none, or one not on the list, is bye alone.
					if let reason = EngineWords.attachRefusal(refusal.reason) { return self.refuse(reason) }
				}
				return self.end()
			}
			self.passedFirstLines()
			channel.maxLineLength = Remote.phoneLineLimit
			guard self.remote.attached(self, device: device, session: session, resumed: resumed, received: claim.received) else { return self.end() }
		}
	}

	/// Called by the session it attached to: the phone is told, and the session's lines follow.
	func attachedTo(_ session: Session, resumed: Bool) {
		guard case let .attaching(channel) = phase else { return }
		phase = .attached(channel, session)
		attachedAt = .now
		if remote.phonesPaused { link.pauseReading() }
		sendLine(ControlLine.attached(Attached(session: session.id, resume: resumed)).line)
		sendHomeKey()
	}

	/// The home key, on an attached channel alone (remotekit.md, "The home key"): on every attach, and at once when it
	/// changes. Never on a pairing channel, where `paired` carries it.
	func sendHomeKey() {
		guard case .attached = phase, let key = remote.homeKey else { return }
		sendLine(ControlLine.homeKey(key).line)
	}

	/// The connection is past its first lines: it no longer counts against the listener's limit, and has no deadline.
	private func passedFirstLines() {
		deadline?.cancel()
		deadline = nil
		if admitted {
			admitted = false
			admission.release(key: admissionKey)
		}
	}

	private func tooSlow() {
		switch phase {
		case .claiming, .claimed, .attaching, .attached, .closing, .ended: return
		default:
			wrongTry("no message from the claimer within ten seconds")
			refusedClaim("silent")
			end()
		}
	}

	// ---- A session's lines (4.1, 5.6, 5.8)

	private func fromPhone(_ line: Data, session: Session) {
		received += 1
		receivedBytesSinceAck += line.count
		// Every line is read strictly as one JSON object before it is put in a line to the engine, so that nothing in it
		// can end that line or name another session; scanned, not built, so that a long line costs only itself (M2).
		guard let names = JSONScan.object(line) else {
			log("device \(session.device) sent a line that is not one JSON object; closed")
			return end()
		}
		// The channel's own lines (5.6), named by a one-member object (or the Mac's proof, by `challenge`), are read as
		// RemoteKit reads a phone's (`parse(_:from: .phone)`): `sessionEnd` ends the session; any other, a line of the
		// Mac's (`refused`, `homeKey`, …) or a first line again, is passed to no one and closes the channel.
		if (names.count == 1 && Self.macLines.contains(where: { names[0].utf8.elementsEqual($0.utf8) })) || names.contains(where: { $0.utf8.elementsEqual("challenge".utf8) }) {
			if case .sessionEnd? = try? ControlLine.parse(line, from: .phone) {
				remote.end(session, why: "the phone's session ended")
				return
			}
			log("device \(session.device) sent one of the channel's own lines in its session; closed")
			return end()
		}
		remote.engine.send(session: session.id, message: line)
		remote.engineMayBeFull()
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

	/// The channel's own lines (remotekit.md), and `refused` (#820) and `pairRefused` (#881), by their one member's name.
	static let macLines = ["pair", "paired", "pairRefused", "attach", "attached", "revoked", "refused", "homeKey", "mac", "sessionEnd"]

	private func sendAck() {
		guard case let .attached(channel, _) = phase, let ack = try? channel.sealAck(received) else { return }
		receivedBytesSinceAck = 0
		link.send(ack)
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
		link.send(handshakeMessage)
	}

	/// What a phone may leave unread before pi² Remote gives up on it (#675's security read B, M1): judged by what waits
	/// **before** a line, so that one line up to the engine's longest (64 MB) always goes. More than `slowAfter` waiting
	/// with no byte taken for `stalledAfter`, or more than `neverAfter` waiting at all, ends the channel; its session keeps
	/// what it needs for a resume.
	static let slowAfter = 16 * 1024 * 1024
	static let stalledAfter: Duration = .seconds(15)
	static let neverAfter = 128 * 1024 * 1024

	/// A line on the channel, in as many frames as it takes.
	func sendLine(_ line: Data) {
		guard let channel, !link.isClosed else { return }
		if link.pending > Self.neverAfter || (link.pending > Self.slowAfter && link.stalledFor >= Self.stalledAfter) {
			log("a phone left more than \(link.pending / 1024 / 1024) MB unread; its channel is closed")
			return end()
		}
		do {
			for message in try channel.seal(line: line) { link.send(message) }
		} catch {
			return end()
		}
		remote.keepWithinBudget()
	}

	/// The Mac ended the channel (it closed the pairing window, stopped listening, or narrowed who may connect): that is
	/// no wrong try of a claimer's.
	func windowClosed() {
		awaitingClaimerProof = false
		claimReported = true
		end()
	}

	/// Ends an attach pi² Remote does not take with the `refused` line, then `bye` (remotekit.md, "The refused line"):
	/// called only once the attach was signed by the device key on pi² Remote's own list, for this channel.
	private func refuse(_ reason: Refusal.Reason) {
		switch phase {
		case let .awaitingAttach(channel, _), let .attaching(channel):
			sendLast(try? channel.sealRefusal(Refusal(reason)))
		default:
			end()
		}
	}

	/// Ends a pairing channel whose claim did not end paired with the `pairRefused` line, then `bye` (#881): only on a
	/// channel whose claimer proved the secret and sent a claim; any other ends with `bye` alone.
	func refusePairing(_ why: PairRefusal.Why) {
		switch phase {
		case let .pairing(channel, _), let .claiming(channel), let .claimed(channel, _):
			guard claimerProven else { return end() }
			log("a claim's phone is told pairRefused \(why.rawValue)")
			sendLast(try? channel.sealPairRefusal(PairRefusal(why)))
		default:
			end()
		}
	}

	/// A channel's last messages, a line and `bye` as RemoteKit sealed them, then the connection closes.
	private func sendLast(_ messages: [Data]?) {
		if case .ended = phase { return }
		guard let messages else { return end() }
		for message in messages { link.send(message) }
		link.finish()
	}

	/// Its unfinished line is overdue (#908): said at most once a minute for each device, by the device and the limit,
	/// never what the line held; then the channel ends, and an attached one's session keeps what a resume needs.
	func endOverdue(_ overdue: LineOverdue) {
		let who = device.map { "device \($0)" } ?? "a phone not yet paired"
		switch overdue {
		case .stalled:
			let (whole, atto) = remote.lineStalledAfter.components
			let seconds = String(format: "%g", Double(whole) + Double(atto) / 1e18)
			Seldom.shared.say("stalled \(device?.text ?? "")", "nothing more of a line from \(who) came for \(seconds) seconds; its connection closed")
		case .tooSlow:
			Seldom.shared.say("slow \(device?.text ?? "")", "a line from \(who) came slower than \(remote.slowestLine / 1024) KiB a second; its connection closed")
		}
		end()
	}

	/// Ends the channel with `bye` and closes the connection.
	func end() {
		if case .ended = phase { return }
		if let channel, let bye = try? channel.sealBye() { link.send(bye) }
		link.finish()
	}

	private func closed() {
		let was = phase
		phase = .ended
		unfinished = nil
		deadline?.cancel()
		if admitted {
			admitted = false
			admission.release(key: admissionKey)
		}
		if awaitingClaimerProof { wrongTry("the claimer closed the connection before its first message") }
		refusedClaim("silent")
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
