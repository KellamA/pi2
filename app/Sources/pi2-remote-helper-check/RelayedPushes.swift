import CryptoKit
import Darwin
import Foundation
import Network
import RemoteKit
import pi2_remote

// Pushes through the relay's client (#935, the last of #689), through the wiring rather than beside it: the engine's
// push event goes into pi² Remote as a process, and what comes out is read where it leaves the relay.
//
// - Against the relay itself (`Relayed.run`, `scripts/relay-protocol-test --remote`), whose pairings push through the
//   stand-in for Apple's service (relay/test/protocol/worker.ts, `PUSH_STAND_IN`): an alert and a background push reach
//   Apple's stand-in sealed for the paired phone, to the token it gave; then, the relay path stopped (its switch off,
//   another relay's address), the same event is answered `push-later` and never handed to a relay client; given just
//   before the relay says the Mac is ready, the same; and a device revoked while its pushes wait behind one held at
//   Apple's stand-in gets none of them.
// - Against a relay of the check's own on 127.0.0.1 (`dropsAndStops`), which drops the Mac's socket, holds its next one
//   before `ready`, and stops it with a refusal: a push in each of those moments is answered `push-later` and handed to
//   no client, and one after `ready` again reaches the relay.
//
// "Handed to no client" is read in pi² Remote's log: the client itself refuses a push while it is not ready, so the
// engine is answered `push-later` either way, and only the log tells a push the hand-over kept from the client from one
// the client refused ("refused, push-later", or a stopped client's line). The hand-over's own line, "no relay connected
// as this Mac", is said once each time the relay goes, by the first push's id, and not for the pushes after it until a
// relay is connected again (#937): each check says which it expects.

enum RelayedPushes {
	/// The phone's push token at the relay, as `token { apns }` takes it: 32 bytes in hexadecimal.
	static let token = String(repeating: "a5", count: 32)

	/// The relay's stand-in for Apple's service, as `scripts/relay-protocol-test --remote` runs it: what it took, in order,
	/// and its answer to the next push held until released.
	struct Apple {
		let base: URL

		init(relay: URL) {
			var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
			parts.scheme = "http"
			parts.path = ""
			base = parts.url!
		}

		/// A push as Apple's stand-in took it.
		struct Taken {
			let token: String
			let headers: [String: String]
			let sealed: Data?
		}

		private func call(_ path: String, method: String) -> Data? {
			var made = URLRequest(url: base.appendingPathComponent(path))
			made.httpMethod = method
			let request = made
			let result = blocking(within: 20) { () async throws -> Data in
				let session = URLSession(configuration: .ephemeral)
				defer { session.invalidateAndCancel() }
				let (data, response) = try await session.data(for: request)
				guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else { throw TimedOut() }
				return data
			}
			return try? result.get()
		}

		func taken() -> [Taken]? {
			guard let data = call("pushes", method: "GET"), case let .array(items)? = try? JSON.parse(data) else { return nil }
			return items.map { item in
				var headers: [String: String] = [:]
				if case let .object(members)? = item["headers"] { for (name, value) in members { headers[name] = value.stringValue } }
				let payload = item["payload"]?.stringValue.flatMap { try? JSON.parse(Data($0.utf8)) }
				return Taken(token: item["token"]?.stringValue ?? "", headers: headers, sealed: payload?["sealed"]?.stringValue.flatMap { Base64URL.decode($0) })
			}
		}

		/// Waits until the stand-in has taken more than `count`, up to `seconds`; what it took.
		func taken(moreThan count: Int, within seconds: Double = 20) -> [Taken] {
			let deadline = Date().addingTimeInterval(seconds)
			while true {
				let all = taken() ?? []
				if all.count > count || deadline.timeIntervalSinceNow <= 0 { return all }
				usleep(100_000)
			}
		}

		func hold() -> Bool { call("pushes/hold", method: "POST") != nil }
		func release() -> Bool { call("pushes/release", method: "POST") != nil }
	}

	/// The engine's push event, as `Pushes` writes the engine's text.
	static func send(_ engine: FakeEngine, _ text: String) {
		let value = try! JSON.parse(text)
		engine.event("push", [("push", value["push"]!)])
	}

	static func log(_ home: URL) -> String {
		(try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
	}

	/// The push the engine named `id`, given by `sending`, is answered `push-later`, and pi² Remote's log says it was
	/// handed to no relay client: no client refused it, and no stopped client was asked. `said`: whether it is the first
	/// since the relay went, which alone the log names ("no relay connected as this Mac"); the next say nothing (#937).
	static func answeredLater(_ engine: FakeEngine, _ id: String, home: URL, _ what: String, said: Bool, sending: () -> Void) {
		func lines(_ text: String) -> Int { log(home).components(separatedBy: "\n").filter { $0.contains(text) }.count }
		let none = "no relay connected as this Mac", client = "push \(id) to ", stopped = "relay client that has stopped", named = "push \(id):"
		let before = (lines(none), lines(client), lines(stopped), lines(named))
		sending()
		let refused = engine.request("remote.pushRefused")
		if let refused { engine.answer(refused.id) }
		Check.expect(refused?.params == .object([("id", .string(id)), ("why", .string("push-later"))]), "\(what): the push is answered push-later", refused.map { JSON.text($0.params) } ?? "nothing")
		let after = (lines(none), lines(client), lines(stopped), lines(named))
		let added = said ? 1 : 0
		let name = said
			? "and handed to no relay client: pi² Remote's log says, by its id, no relay is connected as this Mac, and no client refused it"
			: "and handed to no relay client, no client refused it, and the log says nothing of it: that no relay is connected was said once already since the relay went (#937)"
		Check.expect(after.0 == before.0 + added && after.3 == before.3 + added && after.1 == before.1 && after.2 == before.2, name,
		             log(home).split(separator: "\n").filter { $0.contains("push") }.suffix(4).joined(separator: "\n"))
	}

	/// Opens a sealed push as the phone's extension does.
	static func open(_ sealed: Data?, pairing: PairingID, device: DeviceID, keys: PhoneKeys, mac: Relayed.Mac) -> PushSealing.Opened? {
		guard let sealed else { return nil }
		return try? PushSealing.open(sealed, pairing: pairing, device: device, recordKey: keys.record, macRecordKey: mac.record, identityKey: mac.identity)
	}

	/// After the mailbox: the phone gives its token, and the engine's alert and background push reach Apple's stand-in
	/// sealed for it; one for a device not on pi² Remote's own list reaches nothing.
	static func through(_ engine: FakeEngine, mac: Relayed.Mac, device: DeviceID, keys: PhoneKeys, wire: RelayWire, relay: URL, home: URL) {
		Check.section("pushes through the relay's client (#935): the engine's event, sealed, out of the relay's stand-in for Apple")
		let apple = Apple(relay: relay)
		guard let client = wire.client, case .success = blocking({ try await client.setPushToken(token, environment: .development) }) else {
			return Check.expect(false, "the phone gives the relay its push token")
		}
		guard let before = apple.taken()?.count else { return Check.expect(false, "the relay's stand-in for Apple's service answers (PUSH_STAND_IN, scripts/relay-protocol-test --remote)") }
		send(engine, Pushes.alert("p1", device: device))
		send(engine, Pushes.gone("p2", device: device))
		send(engine, Pushes.alert("p3", device: DeviceID.random()))
		let taken = Array(apple.taken(moreThan: before + 1).dropFirst(before))
		Check.expect(taken.count == 2, "the alert and the background push leave the relay for Apple's stand-in, and nothing else", "\(taken.count) taken")
		guard taken.count == 2 else { return }
		let alert = open(taken[0].sealed, pairing: mac.pairing, device: device, keys: keys, mac: mac)
		let gone = open(taken[1].sealed, pairing: mac.pairing, device: device, keys: keys, mac: mac)
		Check.expect(alert?.kind == .alert && alert.map { JSON.text($0.body) } == Pushes.approval, "the alert opens as the paired phone opens it: sealed for this device of this pairing, signed by the Mac, its body as the engine wrote it")
		Check.expect(gone?.kind == .background, "and the background push as one")
		Check.expect(taken.allSatisfy { $0.token == token } && taken[0].headers["apns-push-type"] == "alert" && taken[1].headers["apns-push-type"] == "background",
		             "each to the token the phone gave, as its kind", "\(taken.map(\.headers))")
		let collapse = try? PushSealing.collapse("need:n12", pairing: mac.pairing, device: device, recordKey: keys.record, deviceRecordKey: mac.record)
		Check.expect(collapse.map(Base64URL.encode) == taken[0].headers["apns-collapse-id"] && taken[1].headers["apns-collapse-id"] == nil,
		             "the alert's collapse id is the one the phone works out for the engine's need; the background push has none")
		Check.expect(open(taken[0].sealed, pairing: mac.pairing, device: DeviceID.random(), keys: keys, mac: mac) == nil && open(taken[0].sealed, pairing: mac.pairing, device: device, keys: PhoneKeys(), mac: mac) == nil,
		             "and it opens for no other device id, nor with another phone's record key")
		Check.expect(engine.quiet(for: 1), "a push sent is not answered, and one for a device not on the list is dropped with nothing to answer")
		let log = log(home)
		Check.expect(!log.contains("push p1") && !log.contains("push p2") && !["Forge", "npm test", "need:n12"].contains(where: log.contains), "the log names no push it sent, and nothing of any push's body or collapse")
	}

	/// The engine's first alert again, after the relay path stopped: `push-later`, and nothing more at Apple's stand-in.
	static func afterStop(_ engine: FakeEngine, device: DeviceID, relay: URL, home: URL, _ what: String, said: Bool) {
		let apple = Apple(relay: relay)
		let before = apple.taken()?.count
		answeredLater(engine, "p1", home: home, what, said: said) { send(engine, Pushes.alert("p1", device: device)) }
		Check.expect(apple.taken()?.count == before, "and nothing reaches Apple's stand-in")
	}

	/// The relay switch turned on again, and the same push given in the same write, before the relay can say the Mac is
	/// ready: `push-later`, handed to no client; then, once ready, it reaches Apple's stand-in.
	static func beforeReady(_ engine: FakeEngine, device: DeviceID, relay: URL, home: URL) -> Bool {
		let apple = Apple(relay: relay)
		let before = apple.taken()?.count ?? 0
		let count = engine.states.count
		let settings = JSON.write(.object([("event", .string("remote")), ("kind", .string("settings")), ("relay", .string(relay.absoluteString)), ("switches", Flows.switches)]))
		let push = JSON.write(.object([("event", .string("remote")), ("kind", .string("push")), ("push", try! JSON.parse(Pushes.alert("p4", device: device))["push"]!)]))
		// One write: pi² Remote reads both before its client can have heard the relay's `ready`.
		// The relay has been away since the switch went off, and that was said then.
		answeredLater(engine, "p4", home: home, "given with the switch turned on, before the relay says the Mac is ready", said: false) { engine.lines.write(settings + Data([0x0A]) + push) }
		let ready = engine.relayState("ready", from: count) != nil
		send(engine, Pushes.alert("p5", device: device))
		let taken = apple.taken(moreThan: before)
		Check.expect(ready && taken.count == before + 1, "once the relay says the Mac is ready again, the next push reaches Apple's stand-in", "\(taken.count - before) taken")
		return ready
	}

	/// A device revoked while its pushes wait behind one held at Apple's stand-in: the one already being asked of the
	/// relay goes, the others never. Before `revoke`; `then` revokes, and returns once pi² Remote's list has dropped it.
	static func revokedWhileWaiting(_ engine: FakeEngine, device: DeviceID, relay: URL, home: URL, revoke: () -> Void) -> () -> Void {
		Check.section("a device revoked while its pushes wait to be put (#935): the one at the relay goes, the rest never")
		let apple = Apple(relay: relay)
		let before = apple.taken()?.count ?? 0
		guard apple.hold() else {
			Check.expect(false, "Apple's stand-in holds its next answer")
			return {}
		}
		send(engine, Pushes.alert("p6", device: device, collapse: "need:n13"))
		let first = apple.taken(moreThan: before)
		Check.expect(first.count == before + 1, "the first push is at Apple's stand-in, its answer held, so that it holds the relay client's turn")
		send(engine, Pushes.alert("p7", device: device, collapse: "need:n14"))
		send(engine, Pushes.gone("p8", device: device))
		revoke()
		let deadline = Date().addingTimeInterval(15)
		while Relayed.kept(home)?.devices.contains(where: { $0.id == device }) != false, deadline.timeIntervalSinceNow > 0 { usleep(100_000) }
		Check.expect(Relayed.kept(home)?.devices.contains(where: { $0.id == device }) == false, "the revocation reached pi² Remote while the two behind it waited")
		_ = apple.release()
		return {
			let log = log(home)
			Check.expect(log.contains("push p7: its device was revoked before it went; dropped") && log.contains("push p8: its device was revoked before it went; dropped"),
			             "the two that waited are dropped", log.split(separator: "\n").filter { $0.contains("push p") }.suffix(4).joined(separator: "\n"))
			Check.expect(apple.taken()?.count == before + 1, "and Apple's stand-in took only the one that was at the relay already: removeDevice, behind it in the client's turn, takes the token after it")
		}
	}

	// ---- A relay of the check's own: dropped, held before `ready`, stopped

	/// pi² Remote with a pairing registered at `PushingRelay` and one device on its list, kept as pi² Remote keeps them:
	/// a push in each moment the relay's client is not connected as this Mac is answered `push-later` and handed to no
	/// client; one in each moment it is, reaches the relay, sealed for the device.
	static func dropsAndStops(helper: URL, home: URL) {
		Check.section("the hand-over follows the relay's word (#935): taken away when the socket drops, before ready, when stopped")
		guard let relay = PushingRelay() else { return Check.expect(false, "a relay of the check's own listens on 127.0.0.1") }
		defer { relay.stop() }
		let keys = PhoneKeys()
		let device = DeviceID.random()
		let listed = ListedDevice(json: keys.paired(id: device))!
		do {
			try PrivateFile.write(home.appendingPathComponent("remote-devices.json"), KeptDevices(devices: [listed], homeKey: HomeKey.random(), registration: RelayRegistration(pairing: relay.pairing, relay: relay.url.absoluteString)).data)
		} catch {
			return Check.expect(false, "pi² Remote's list is written with a device and the relay's pairing", "\(error)")
		}
		let (child, engine) = Starts.start(helper: helper, home: home)
		defer { child.stop() }
		engine.answersStates = true
		engine.event("start", [
			("relay", .string(relay.url.absoluteString)), ("switches", Flows.switches), ("pairing", .string(relay.pairing.text)),
			("devices", .array([.object([("id", .string(device.text))])])), ("minimumBuild", .string("1")),
		])
		guard let hello = engine.request("remote.hello") else { return Check.expect(false, "pi² Remote said hello") }
		engine.answer(hello.id)
		let macKeys = hello.params["macKeys"]
		guard let identity = macKeys?["identity"]?.stringValue.flatMap(PublicKeys.signingKey), let record = macKeys?["record"]?.stringValue.flatMap(PublicKeys.agreementKey) else {
			return Check.expect(false, "remote.hello gave the Mac's keys")
		}
		let mac = Relayed.Mac(pairing: relay.pairing, port: 0, identity: identity, channel: Curve25519.KeyAgreement.PrivateKey().publicKey, record: record)
		guard engine.relayState("ready") != nil else { return Check.expect(false, "pi² Remote is ready at the relay of the check's own", JSON.text(.array(engine.states))) }
		func reaches(_ id: String, _ what: String) {
			let before = relay.pushes.count
			send(engine, Pushes.alert(id, device: device))
			let deadline = Date().addingTimeInterval(20)
			while relay.pushes.count == before, deadline.timeIntervalSinceNow > 0 { usleep(50_000) }
			let push = relay.pushes.dropFirst(before).first
			let sealed = push?["push"]?["sealed"]?.stringValue.flatMap { Base64URL.decode($0) }
			Check.expect(push?["push"]?["device"]?.stringValue == device.text && open(sealed, pairing: relay.pairing, device: device, keys: keys, mac: mac) != nil,
			             "\(what): the push reaches the relay, sealed for the device", push.map(JSON.text) ?? "nothing")
		}
		reaches("p21", "ready")

		var count = engine.states.count
		relay.drop()
		guard engine.relayState("down", from: count) != nil else { return Check.expect(false, "the relay dropped the Mac's socket: down") }
		answeredLater(engine, "p22", home: home, "the socket dropped (disconnected)", said: true) { send(engine, Pushes.alert("p22", device: device)) }
		guard relay.waitHeld(within: 30) else { return Check.expect(false, "the client connects again, and the relay holds it before ready") }
		// Still away since the drop: said once already (#937).
		answeredLater(engine, "p23", home: home, "connected again and proved, before the relay says ready (connecting)", said: false) { send(engine, Pushes.alert("p23", device: device)) }
		answeredLater(engine, "p26", home: home, "the engine's next push in the same state, as it offers one each minute", said: false) { send(engine, Pushes.alert("p26", device: device)) }
		count = engine.states.count
		relay.letIn()
		guard engine.relayState("ready", from: count) != nil else { return Check.expect(false, "ready again") }
		reaches("p24", "ready again")

		count = engine.states.count
		relay.refuse("removed")
		guard engine.relayState("stopped", from: count) != nil else { return Check.expect(false, "the relay's refusal stops the client") }
		// The relay was back between: said again, once.
		answeredLater(engine, "p25", home: home, "the client stopped on the relay's refusal (stopped)", said: true) { send(engine, Pushes.alert("p25", device: device)) }
		answeredLater(engine, "p27", home: home, "the next push while it stays stopped", said: false) { send(engine, Pushes.alert("p27", device: device)) }
		Check.expect(relay.pushes.count == 2, "and the relay was asked for the two pushes made while ready, and no other", "\(relay.pushes.count)")
	}
}

/// A relay on 127.0.0.1 of the check's own, as far as a Mac's pushes go (relay/README.md): a challenge for its hello,
/// `ready` for its proof (listing no device, so that nothing is removed), `ok` for each push, which it keeps; and, on the
/// check's word, the Mac's socket dropped, its next proof held unanswered, or a refusal that stops the client.
final class PushingRelay: @unchecked Sendable {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "pushing relay")
	let pairing = PairingID.random()
	private(set) var url = URL(string: "ws://127.0.0.1/v1")!
	private let state = Locked<(mac: NWConnection?, admit: Bool, held: NWConnection?, pushes: [JSONValue])>((nil, true, nil, []))

	var pushes: [JSONValue] { state.get().pushes }

	init?() {
		let options = NWProtocolWebSocket.Options()
		options.autoReplyPing = true
		let parameters = NWParameters.tcp
		parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		guard let made = try? NWListener(using: parameters) else { return nil }
		listener = made
		let ready = DispatchSemaphore(value: 0)
		listener.stateUpdateHandler = { state in
			if case .ready = state { ready.signal() }
			if case .failed = state { ready.signal() }
		}
		listener.newConnectionHandler = { [unowned self] connection in
			connection.start(queue: queue)
			receive(connection)
		}
		listener.start(queue: queue)
		guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue, port != 0 else { return nil }
		url = URL(string: "ws://127.0.0.1:\(port)/v1")!
	}

	func stop() {
		listener.cancel()
		let now = state.get()
		now.mac?.cancel()
		now.held?.cancel()
	}

	/// Closes the Mac's socket, and holds its next proof unanswered until `letIn`.
	func drop() {
		queue.sync {
			let mac = state.update { held -> NWConnection? in
				held.admit = false
				defer { held.mac = nil }
				return held.mac
			}
			mac?.cancel()
		}
	}

	func waitHeld(within seconds: Double) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while state.get().held == nil {
			guard deadline.timeIntervalSinceNow > 0 else { return false }
			usleep(50_000)
		}
		return true
	}

	/// Answers the held proof with `ready`.
	func letIn() {
		queue.sync {
			let held = state.update { held -> NWConnection? in
				held.admit = true
				defer { held.held = nil }
				held.mac = held.held
				return held.held
			}
			if let held { ready(held) }
		}
	}

	/// A refusal trying again would not change, as the relay says it, then the socket closed.
	func refuse(_ why: String) {
		queue.sync {
			guard let mac = state.get().mac else { return }
			send(mac, .object([("refused", .object([("why", .string(why))]))])) { mac.cancel() }
		}
	}

	private func ready(_ connection: NWConnection) {
		send(connection, .object([("ready", .object([
			("devices", .array([])), ("left", .array([])), ("pending", .bool(false)), ("mail", .integer(0)),
		]))]))
	}

	private func send(_ connection: NWConnection, _ message: JSONValue, then: (@Sendable () -> Void)? = nil) {
		let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
		connection.send(content: Data(JSON.text(message).utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in then?() })
	}

	private func receive(_ connection: NWConnection) {
		connection.receiveMessage { [self] content, _, _, error in
			guard error == nil, let content, let message = try? JSON.parse(content), case let .object(members) = message, members.count == 1 else { return connection.cancel() }
			switch members[0].0 {
			case "hello":
				send(connection, .object([("challenge", .string(Base64URL.encode(Bytes.random(32))))]))
			case "proof":
				let admit = state.update { held -> Bool in
					if held.admit { held.mac = connection } else { held.held = connection }
					return held.admit
				}
				if admit { ready(connection) }
			case "push":
				state.update { $0.pushes.append(message) }
				send(connection, .object([("ok", .object([("what", .string("push"))]))]))
			case "ping":
				send(connection, .object([("pong", .object([]))]))
			default:
				break
			}
			receive(connection)
		}
	}
}
