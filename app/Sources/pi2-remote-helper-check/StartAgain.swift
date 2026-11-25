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
/// frame's payload, unmasked): neither earlier pairing's id, as text or as its bytes, ever crosses it.
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
		let elsewhere = relayState("another-relay")
		Check.expect(elsewhere?["why"]?.stringValue?.contains("not registered at this relay") == true, "another relay's address: unavailable, reason another-relay", elsewhere.map(JSON.text) ?? "nothing")
		usleep(1_000_000)
		Check.expect(pairing() == atRelay.pairing.text, "nothing is forgotten or registered by itself")
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
		Check.expect(front.connections >= 3 && crossed(atFront.pairing), "the front saw the new pairing's traffic: the Mac's registration and socket, the phone's join and socket", "\(front.connections) connections, \(seen.count) bytes")
		Check.expect(!crossed(atRelay.pairing), "the pairing registered at the old address never crossed the new relay's wire, as text or as its bytes")
		Check.expect(!crossed(homeOnly.pairing), "nor the one made at home")
		guard case .success = app.call("devices.set", .object([("on", .bool(false))])) else { return Check.expect(false, "remote access turned off") }
	}
}

/// A front on 127.0.0.1 for a relay on this computer: every byte passed on unchanged, each way, and kept as the relay
/// reads it, so that the check can say what crossed this address: the request's head, then each WebSocket frame's
/// payload, unmasked (RFC 6455 5.2). Plain BSD sockets and a thread for each direction of each connection.
final class RecordingFront: @unchecked Sendable {
	private let listener: Int32
	private let upstream: UInt16
	let url: URL
	private let state = Locked<(seen: Data, connections: Int, open: [Int32])>((Data(), 0, []))
	private let stopped = Locked(false)

	var seen: Data { state.get().seen }
	var connections: Int { state.get().connections }

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
				pump(from: client, to: relay)
				finish()
			}.start()
			Thread { [self] in
				pump(from: relay, to: client)
				finish()
			}.start()
		}
	}

	/// Passes `from`'s bytes to `to` until either ends, keeping what the relay reads of them.
	private func pump(from: Int32, to: Int32) {
		var reader = Frames()
		var buffer = [UInt8](repeating: 0, count: 65536)
		while true {
			let count = read(from, &buffer, buffer.count)
			guard count > 0 else { break }
			var sent = 0
			while sent < count {
				let wrote = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, count - sent) }
				guard wrote > 0 else { break }
				sent += wrote
			}
			let read = reader.take(Data(buffer[0 ..< count]))
			if !read.isEmpty { state.update { $0.seen.append(read) } }
			guard sent == count else { break }
		}
		shutdown(to, SHUT_WR)
		shutdown(from, SHUT_RD)
	}

	/// One direction of a WebSocket connection read as its reader reads it: the HTTP head, then frames.
	private struct Frames {
		private var held = Data()
		private var headDone = false

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
				out.append(contentsOf: payload)
				out.append(0)
				held = Data(bytes[(at + length)...])
			}
			return out
		}
	}
}
