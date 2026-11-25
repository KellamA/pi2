import Darwin
import Foundation
import RemoteKit
import pi2_remote

/// Starting again at the relay now set (#917), through a real engine and the relay on this computer. A pairing made with
/// the relay switch off, then the switch on: the relay path is `unavailable`, `unregistered`, and starting again
/// registers a new pairing there. Then the relay's address changed: `another-relay`, and starting again unpairs the
/// phone (told so on the home path, signed) and registers a new pairing at the new address, through which a phone pairs
/// and attaches. The new address is a front of the check's own on 127.0.0.1 (`RecordingFront`) that passes every byte
/// on to the same relay and keeps what passed, read as the relay reads it (the request's head and each WebSocket
/// frame's payload, unmasked). It takes `Sec-WebSocket-Extensions` out of every request head, so that no
/// `permessage-deflate` is agreed, and the check asserts that no compressed frame (RSV1) crossed: every frame is read as
/// it is. Neither earlier pairing's id, as text or as its bytes, ever crosses it, in a head or in a frame.
enum StartAgain {
	static func run(engineMain: String, helper: URL, root: URL, relay: URL) {
		Check.section("through a real engine and the relay on this computer: the pairing started again at the relay now set (#917)")
		guard let front = RecordingFront(to: relay) else { return Check.expect(false, "a recording front for the relay, on 127.0.0.1") }
		defer { front.stop() }
		guard let (engine, app, home) = RealEngine.startEngine(engineMain: engineMain, helper: helper, root: root, name: "ea") else { return }
		defer { engine.stop() }

		func relayState(_ reason: String?, _ state: String = "unavailable", within seconds: Double = 60) -> JSONValue? {
			let deadline = Date().addingTimeInterval(seconds)
			var last: JSONValue?
			while Date() < deadline {
				if case let .success(event) = app.call("devices.watch") {
					last = event["helper"]?["relay"]
					if last?["state"]?.stringValue == state, last?["reason"]?.stringValue == reason { return last }
				}
				usleep(200_000)
			}
			Check.expect(false, "the Devices page is told the relay path is \(state) (\(reason ?? "no reason"))", last.map(JSON.text) ?? "nothing")
			return nil
		}
		func opened(_ what: String) -> PairingPayload? {
			guard case let .success(window) = app.call("devices.pairStart", within: 180), let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text) else {
				Check.expect(false, "a pairing opened: \(what)", engine.stderrText.suffix(2000).description)
				return nil
			}
			return payload
		}
		func confirm(_ payload: PairingPayload, _ binding: Data) -> DeviceID? {
			var confirmed: Result<JSONValue, Refused> = .failure(Refused("not tried"))
			for _ in 0 ..< 300 {
				confirmed = app.call("devices.pairConfirm", .object([("digits", .string(PairingSecrets.digits(secret: payload.secret, binding: binding)))]))
				if case let .failure(why) = confirmed, why.description.contains("No phone is waiting") { usleep(200_000) } else { break }
			}
			guard case let .success(answer) = confirmed, let id = answer["device"]?.stringValue else { return nil }
			return DeviceID(id)
		}
		/// A phone paired on the home path, then attached there.
		func pairedAtHome(_ payload: PairingPayload) -> (Phone, DeviceID)? {
			guard let address = payload.addresses.first, let port = UInt16(address.split(separator: ":").last ?? "") else { return nil }
			let keys = PhoneKeys()
			guard let phone = Phone(port: port), let paired = phone.pair(payload: payload, keys: keys, team: RealEngine.team), let device = confirm(payload, paired.binding),
			      phone.line() != nil, phone.event() == .bye,
			      let attached = Phone(port: port), let challenge = attached.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey),
			      attached.attach(pairing: payload.pairing, device: device, keys: keys, challenge: challenge) != nil
			else { return nil }
			while let line = attached.line(within: 60), let value = try? JSON.parse(line), value["event"]?.stringValue != "device" {}
			return (attached, device)
		}
		func startAgain(_ what: String) -> [String]? {
			guard case let .success(answer) = app.call("devices.startAgain"), case let .array(revoked)? = answer["revoked"] else {
				Check.expect(false, "the person starts again on the Mac: \(what)")
				return nil
			}
			return revoked.compactMap(\.stringValue)
		}
		/// A pairing code refused in `words` (#1013); had one been made, the check uses it as a phone does, joining the relay
		/// it names at once, so that what crosses the front shows it too.
		func refused(_ words: String, _ what: String) {
			switch app.call("devices.pairStart", within: 180) {
			case let .failure(why):
				Check.expect(why.description.contains(words), "no pairing code \(what)", why.description)
			case let .success(window):
				Check.expect(false, "no pairing code \(what)", window["payload"]?.stringValue.map { _ in "a code was made" } ?? "")
				if let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text), let relay = URL(string: payload.relay) {
					_ = Relayed.join(relay, pairing: payload.pairing, secret: payload.secret, keys: PhoneKeys())
				}
				_ = app.call("devices.pairCancel")
			}
		}
		func pairing() -> String? {
			guard case let .success(event) = app.call("devices.watch") else { return nil }
			return event["pairing"]?.stringValue
		}

		// A pairing made with the relay switch off: its id made by pi² Remote, for the home path alone.
		guard case .success = app.call("devices.set", .object([("on", .bool(true)), ("preview", .bool(true)), ("relay", .bool(false)), ("relayAddress", .string(relay.absoluteString))])) else {
			return Check.expect(false, "remote access turned on, the relay switch off")
		}
		guard let homeOnly = opened("with the relay switch off"), let (first, firstDevice) = pairedAtHome(homeOnly) else { return Check.expect(false, "a phone paired at home with the relay off") }
		Check.expect(Relayed.kept(home)?.registration == nil, "a pairing made with the relay off is registered at no relay")
		_ = relayState(nil, "off")
		// Nothing happens by itself when the switch goes on: the Devices page is told why, and the person decides.
		guard case .success = app.call("devices.set", .object([("relay", .bool(true))])) else { return Check.expect(false, "the relay switch turned on") }
		let unregistered = relayState("unregistered")
		Check.expect(unregistered?["why"]?.stringValue?.contains("not registered at this relay") == true, "the relay switch on: the relay path is unavailable, reason unregistered, for the pairing made at home", unregistered.map(JSON.text) ?? "nothing")
		usleep(1_000_000)
		Check.expect(pairing() == homeOnly.pairing.text && Relayed.kept(home)?.registration == nil, "and nothing is registered by itself")
		refused("pairing is registered at no relay. Start again at this relay first", "while the pairing made with the relay off would be named to the relay now on")

		guard let firstRevoked = startAgain("for the pairing made at home") else { return }
		Check.expect(firstRevoked == [firstDevice.text], "starting again revokes the one phone paired", "\(firstRevoked)")
		var told = false
		while let event = first.event(within: 30) {
			if case let .line(line) = event, case let .revoked(revocation)? = try? ControlLine.parse(line) {
				told = (try? revocation.verify(identityKey: homeOnly.identityKey, pairing: homeOnly.pairing, device: firstDevice)) != nil
			}
			if event == .bye { break }
		}
		Check.expect(told, "which is told so at home, signed by the Mac's identity key for its pairing, and its channel ends")
		Check.expect(pairing() == nil, "and the engine has no pairing")
		guard let atRelay = opened("at the relay, after starting again") else { return }
		Check.expect(atRelay.pairing != homeOnly.pairing && atRelay.relay == relay.absoluteString, "the next code names a new pairing, at the relay")
		let kept = Relayed.kept(home)?.registration
		Check.expect(kept == RelayRegistration(pairing: atRelay.pairing, relay: relay.absoluteString), "registered at the relay now set, and kept with its address", "\(String(describing: kept))")
		guard let (second, secondDevice) = pairedAtHome(atRelay) else { return Check.expect(false, "a phone pairs with the new pairing, at home") }
		Check.expect(relayState(nil, "ready") != nil, "and the relay path is ready at the relay for the new pairing")

		// The relay's address changed: the pairing is shown to no other relay, and the page is told why.
		guard case .success = app.call("devices.set", .object([("relayAddress", .string(front.url.absoluteString))])) else { return Check.expect(false, "the relay's address changed") }
		// At once, before pi² Remote has said anything of the new address: the engine waits for its word (#1013).
		refused("belongs to another relay. Start again at this relay first", "for the pairing registered at the old address, asked at once after the change")
		let elsewhere = relayState("another-relay")
		Check.expect(elsewhere?["why"]?.stringValue?.contains("not registered at this relay") == true, "another relay's address: unavailable, reason another-relay", elsewhere.map(JSON.text) ?? "nothing")
		usleep(1_000_000)
		Check.expect(pairing() == atRelay.pairing.text, "nothing is forgotten or registered by itself")
		guard case .success = app.call("devices.set", .object([("relay", .bool(false))])) else { return Check.expect(false, "the relay switch turned off") }
		refused("belongs to another relay. Set the relay's address back", "with the relay switch off either: the phone tries the code's relay whatever the switch")
		guard case .success = app.call("devices.set", .object([("relay", .bool(true))])) else { return Check.expect(false, "the relay switch turned on again") }
		_ = relayState("another-relay")
		guard let secondRevoked = startAgain("at another relay's address") else { return }
		Check.expect(secondRevoked == [secondDevice.text], "starting again revokes the phone paired", "\(secondRevoked)")
		told = false
		while let event = second.event(within: 30) {
			if case let .line(line) = event, case let .revoked(revocation)? = try? ControlLine.parse(line) {
				told = (try? revocation.verify(identityKey: atRelay.identityKey, pairing: atRelay.pairing, device: secondDevice)) != nil
			}
			if event == .bye { break }
		}
		Check.expect(told, "which is told so at home, signed, and its channel ends")
		var forgotten: KeptDevices?
		for _ in 0 ..< 50 {
			forgotten = Relayed.kept(home)
			if forgotten?.registration == nil, forgotten?.devices.isEmpty == true { break }
			usleep(100_000)
		}
		Check.expect(forgotten?.registration == nil && forgotten?.devices.isEmpty == true && forgotten?.homeKey == nil, "pi² Remote forgets the pairing, its registration, list and home key, in its folder")
		_ = relayState("no-pairing")

		guard let atFront = opened("at the new relay's address") else { return }
		Check.expect(atFront.pairing != atRelay.pairing && atFront.pairing != homeOnly.pairing && atFront.relay == front.url.absoluteString, "the next code names a new pairing, at the new address")
		Check.expect(Relayed.kept(home)?.registration == RelayRegistration(pairing: atFront.pairing, relay: front.url.absoluteString), "registered there, and kept with that address")
		let keys = PhoneKeys()
		guard let link = Relayed.join(front.url, pairing: atFront.pairing, secret: atFront.secret, keys: keys) else { return Check.expect(false, "a phone joins the new relay's window") }
		let joined = RelayWire(link: link)
		let phone = Phone(relay: joined)
		guard let paired = phone.pair(payload: atFront, keys: keys, team: RealEngine.team), let device = confirm(atFront, paired.binding),
		      let line = phone.line(), case .paired? = try? ControlLine.parse(line)
		else { return Check.expect(false, "the phone pairs through the new relay") }
		joined.close()
		guard let wire = Relayed.connect(front.url, pairing: atFront.pairing, device: device, keys: keys) else { return Check.expect(false, "the phone connects to the new relay as a listed device") }
		let connected = Phone(relay: wire)
		guard let challenge = connected.connect(pairing: atFront.pairing, device: device, keys: keys, macChannel: atFront.channelKey, identity: atFront.identityKey),
		      connected.attach(pairing: atFront.pairing, device: device, keys: keys, challenge: challenge) != nil
		else { return Check.expect(false, "the phone attaches through the new relay") }
		connected.sendLine(Data(#"{"id":"a1","method":"engine.info","params":{}}"#.utf8))
		var info: JSONValue?
		while info == nil, let line = connected.line(within: 60) {
			if let value = try? JSON.parse(line), value["id"]?.stringValue == "a1" { info = value }
		}
		Check.expect(info?["result"]?["pid"]?.integerValue == Int64(engine.pid), "a phone pairs, attaches and asks the engine through the new relay")
		Check.expect(relayState(nil, "ready") != nil, "and the relay path is ready there")
		if case let .success(event) = app.call("devices.watch"), case let .array(sessions)? = event["sessions"] {
			Check.expect(sessions.contains { $0["device"]?.stringValue == device.text && $0["path"]?.stringValue == "relay" }, "the Devices page shows its session on the relay path")
		}

		// What crossed the new relay's address, as the relay read it.
		let seen = front.seen
		func crossed(_ pairing: PairingID) -> Bool {
			seen.range(of: Data(pairing.text.utf8)) != nil || Base64URL.decode(pairing.text, count: 16).map { seen.range(of: $0) != nil } == true
		}
		Check.expect(front.offersTaken >= front.connections && front.connections >= 3, "every connection's offer of permessage-deflate was taken out of its request head", "\(front.offersTaken) of \(front.connections)")
		Check.expect(front.compressed == 0 && seen.range(of: Data("sec-websocket-extensions".utf8)) == nil && String(decoding: seen, as: UTF8.self).lowercased().contains("sec-websocket-extensions") == false,
		             "no compressed frame crossed the front, and no extension was agreed: every frame's payload is read as it is", "\(front.compressed) compressed")
		Check.expect(front.frames.range(of: Data(atFront.pairing.text.utf8)) != nil, "the front saw the new pairing's id inside frames, not only in a request head (its hello)", "\(front.frames.count) bytes of frames")
		Check.expect(front.connections >= 3 && crossed(atFront.pairing), "the front saw the new pairing's traffic: the Mac's registration and socket, the phone's join and socket", "\(front.connections) connections, \(seen.count) bytes")
		Check.expect(!crossed(atRelay.pairing), "the pairing registered at the old address never crossed the new relay's wire, as text or as its bytes, by pi² Remote or by a pairing code")
		Check.expect(!crossed(homeOnly.pairing), "nor the one made at home")

		// No phone paired and the pairing kept (#1013's case, the security read's M1): pi² Remote is not running, the
		// address changes, a code is refused, and starting again still works, waiting for pi² Remote's word as pairStart does.
		guard case .success = app.call("devices.revoke", .object([("device", .string(device.text))])) else { return Check.expect(false, "the last phone revoked") }
		func helperRunning() -> Bool? {
			guard case let .success(event) = app.call("devices.watch") else { return nil }
			return event["helper"]?["running"]?.boolValue
		}
		func registeredNow() -> String? {
			guard case let .success(event) = app.call("devices.watch") else { return nil }
			return event["pairingRegistered"]?.stringValue
		}
		var stopped = false
		for _ in 0 ..< 150 where !stopped {
			stopped = helperRunning() == false
			if !stopped { usleep(100_000) }
		}
		Check.expect(stopped && pairing() == atFront.pairing.text, "with no phone paired, pi² Remote stops, and the pairing is kept")
		guard case .success = app.call("devices.set", .object([("relayAddress", .string(relay.absoluteString))])) else { return Check.expect(false, "the relay's address changed back") }
		Check.expect(registeredNow() == nil, "a word about another address is not taken for this one")
		refused("belongs to another relay. Start again at this relay first", "with no phone paired, for the pairing registered at the front's address")
		usleep(4_000_000)
		Check.expect(helperRunning() == false && registeredNow() == "another-relay", "pi² Remote stopped again, and the engine keeps its word: the page goes on offering to start again", "running \(String(describing: helperRunning())), registered \(registeredNow() ?? "none")")
		if case let .success(answer) = app.call("devices.startAgain", within: 120), case let .array(revoked)? = answer["revoked"] {
			Check.expect(revoked.isEmpty && pairing() == nil, "starting again works with no phone paired and pi² Remote stopped: it is started, and its word awaited")
		} else {
			Check.expect(false, "starting again works with no phone paired and pi² Remote stopped")
		}
		guard let atLast = opened("after starting again with no phone") else { return }
		Check.expect(atLast.pairing != atFront.pairing && atLast.relay == relay.absoluteString && Relayed.kept(home)?.registration == RelayRegistration(pairing: atLast.pairing, relay: relay.absoluteString), "the next code names a new pairing, registered at the relay now set")
		let lastKeys = PhoneKeys()
		if let lastLink = Relayed.join(relay, pairing: atLast.pairing, secret: atLast.secret, keys: lastKeys) {
			let lastWire = RelayWire(link: lastLink)
			let lastPhone = Phone(relay: lastWire)
			let paired = lastPhone.pair(payload: atLast, keys: lastKeys, team: RealEngine.team).flatMap { confirm(atLast, $0.binding) }
			let told = lastPhone.line().flatMap { try? ControlLine.parse($0) }
			if case .paired? = told, paired != nil {
				Check.expect(true, "and a phone pairs through the relay with it")
			} else {
				Check.expect(false, "and a phone pairs through the relay with it")
			}
			lastWire.close()
		} else {
			Check.expect(false, "a phone joins the relay's window with the new pairing")
		}
		guard case .success = app.call("devices.set", .object([("on", .bool(false))])) else { return Check.expect(false, "remote access turned off") }
	}
}

/// A front on 127.0.0.1 for a relay on this computer: every byte passed on unchanged, each way, and kept as the relay
/// reads it, so that the check can say what crossed this address: the request's head, then each WebSocket frame's
/// payload, unmasked (RFC 6455 5.2). The client's offer of extensions is taken out of its head, so frames are never
/// compressed; a compressed frame (RSV1) is counted, never read, and the check wants none. Plain BSD sockets and a
/// thread for each direction of each connection.
final class RecordingFront: @unchecked Sendable {
	private let listener: Int32
	private let upstream: UInt16
	let url: URL
	private let state = Locked<(seen: Data, frames: Data, connections: Int, open: [Int32], compressed: Int, offersTaken: Int)>((Data(), Data(), 0, [], 0, 0))
	private let stopped = Locked(false)

	var seen: Data { state.get().seen }
	/// The frames' payloads alone, as the relay read them: what the heads do not hold.
	var frames: Data { state.get().frames }
	var connections: Int { state.get().connections }
	/// Frames with RSV1 set, compressed by `permessage-deflate`, which the front cannot read: there must be none.
	var compressed: Int { state.get().compressed }
	/// Request heads whose `Sec-WebSocket-Extensions` offer the front took out before the relay saw them.
	var offersTaken: Int { state.get().offersTaken }

	init?(to relay: URL) {
		guard relay.host == "127.0.0.1", let port = relay.port, let upstream = UInt16(exactly: port) else { return nil }
		self.upstream = upstream
		let descriptor = socket(AF_INET, SOCK_STREAM, 0)
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		address.sin_port = 0
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let bound = withUnsafeMutablePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && listen(descriptor, 16) == 0 && getsockname(descriptor, $0, &length) == 0 }
		}
		guard bound else {
			close(descriptor)
			return nil
		}
		listener = descriptor
		url = URL(string: "ws://127.0.0.1:\(UInt16(bigEndian: address.sin_port))\(relay.path)")!
		Thread { [self] in accepting() }.start()
	}

	func stop() {
		stopped.set(true)
		shutdown(listener, SHUT_RDWR)
		close(listener)
		for open in state.get().open { shutdown(open, SHUT_RDWR) }
	}

	private func accepting() {
		while !stopped.get() {
			let client = accept(listener, nil, nil)
			guard client >= 0 else { if stopped.get() { return } else { continue } }
			let relay = socket(AF_INET, SOCK_STREAM, 0)
			var address = sockaddr_in()
			address.sin_family = sa_family_t(AF_INET)
			address.sin_addr.s_addr = inet_addr("127.0.0.1")
			address.sin_port = upstream.bigEndian
			let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(relay, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
			guard connected else {
				close(client)
				close(relay)
				continue
			}
			state.update {
				$0.connections += 1
				$0.open += [client, relay]
			}
			let ends = Locked(0)
			let finish: @Sendable () -> Void = {
				guard ends.update({ $0 += 1; return $0 }) == 2 else { return }
				close(client)
				close(relay)
			}
			Thread { [self] in
				pump(from: client, to: relay, request: true)
				finish()
			}.start()
			Thread { [self] in
				pump(from: relay, to: client, request: false)
				finish()
			}.start()
		}
	}

	/// Passes `from`'s bytes to `to` until either ends, keeping what the relay reads of them.
	/// The client's request head is held until it is whole and passed on without its `Sec-WebSocket-Extensions` lines,
	/// so that no `permessage-deflate` is agreed and every frame stays readable here (the local relay, workerd, accepts it
	/// when offered); what is kept is what the relay reads.
	private func pump(from: Int32, to: Int32, request: Bool) {
		var reader = Frames()
		var head: Data? = request ? Data() : nil
		var buffer = [UInt8](repeating: 0, count: 65536)
		func send(_ bytes: Data) -> Bool {
			var sent = 0
			while sent < bytes.count {
				let wrote = bytes.withUnsafeBytes { write(to, $0.baseAddress! + sent, bytes.count - sent) }
				guard wrote > 0 else { return false }
				sent += wrote
			}
			return true
		}
		while true {
			let count = read(from, &buffer, buffer.count)
			guard count > 0 else { break }
			var bytes = Data(buffer[0 ..< count])
			if var held = head {
				held.append(bytes)
				guard let end = held.range(of: Data("\r\n\r\n".utf8)) else {
					head = held
					continue
				}
				let text = String(decoding: held[held.startIndex ..< end.lowerBound], as: UTF8.self)
				let lines = text.components(separatedBy: "\r\n")
				let kept = lines.filter { !$0.lowercased().hasPrefix("sec-websocket-extensions:") }
				if kept.count != lines.count { state.update { $0.offersTaken += 1 } }
				bytes = Data((kept.joined(separator: "\r\n") + "\r\n\r\n").utf8) + held[end.upperBound...]
				head = nil
			}
			let readHere = reader.take(bytes)
			if !readHere.isEmpty || reader.compressed > 0 {
				let compressed = reader.compressed
				let payloads = reader.payloads
				reader.compressed = 0
				reader.payloads = Data()
				state.update {
					$0.seen.append(readHere)
					$0.frames.append(payloads)
					$0.compressed += compressed
				}
			}
			guard send(bytes) else { break }
		}
		shutdown(to, SHUT_WR)
		shutdown(from, SHUT_RD)
	}

	/// One direction of a WebSocket connection read as its reader reads it: the HTTP head, then frames.
	private struct Frames {
		private var held = Data()
		private var headDone = false
		/// Whole frames with RSV1 set (compressed) since last asked.
		var compressed = 0
		/// The frames' payloads alone since last asked, each followed by a zero byte.
		var payloads = Data()

		/// What `more` completes: the head's text, and each whole frame's payload unmasked, each followed by a zero byte.
		mutating func take(_ more: Data) -> Data {
			held.append(more)
			var out = Data()
			if !headDone {
				guard let end = held.range(of: Data("\r\n\r\n".utf8)) else { return out }
				out.append(held[held.startIndex ..< end.upperBound])
				out.append(0)
				held = Data(held[end.upperBound...])
				headDone = true
			}
			while true {
				let bytes = [UInt8](held)
				guard bytes.count >= 2 else { break }
				let masked = bytes[1] & 0x80 != 0
				let deflated = bytes[0] & 0x40 != 0
				var length = Int(bytes[1] & 0x7F)
				var at = 2
				if length == 126 {
					guard bytes.count >= 4 else { break }
					length = Int(bytes[2]) << 8 | Int(bytes[3])
					at = 4
				} else if length == 127 {
					guard bytes.count >= 10 else { break }
					length = bytes[2 ..< 10].reduce(0) { $0 << 8 | Int($1) }
					at = 10
				}
				let key = masked ? Array(bytes[min(at, bytes.count) ..< min(at + 4, bytes.count)]) : []
				if masked { at += 4 }
				guard bytes.count >= at + length else { break }
				var payload = Array(bytes[at ..< at + length])
				if masked, key.count == 4 { for index in payload.indices { payload[index] ^= key[index % 4] } }
				if deflated { compressed += 1 }
				out.append(contentsOf: payload)
				out.append(0)
				payloads.append(contentsOf: payload)
				payloads.append(0)
				held = Data(bytes[(at + length)...])
			}
			return out
		}
	}
}
