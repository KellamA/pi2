
import CryptoKit
import Foundation
import RemoteKit

/// The client against a relay the check plays itself, in memory, on a clock it moves: the handshakes, the requests, the
/// mailbox, the channel's bytes, and every way a socket ends, with what the client does after each.
enum Sessions {
	static let url = URL(string: "ws://127.0.0.1:1/v1")!
	static let relayKey = P256.Signing.PrivateKey()
	static let deviceKey = P256.Signing.PrivateKey()

	/// A client, its clock, and the sockets it opens.
	struct Rig {
		let clock = ManualClock()
		let connector = MemoryConnector()
		let client: RelayClient
		let events: Inbox<RelayEvent>

		init(_ role: RelayClient.Role, build: String = "200", key: P256.Signing.PrivateKey? = nil, memory: RelayItemMemory = RelayItemMemory()) {
			var options = RelayOptions()
			options.clock = clock
			// No jitter: each wait at its shortest, so that the checks know it.
			options.random = { 0 }
			let signer = RelaySigner(key ?? (role == .mac(Formats.pairing) ? relayKey : deviceKey))
			client = RelayClient(relay: url, role: role, build: RelayBuild(build)!, signer: signer, connector: connector, options: options, itemMemory: memory)
			events = Inbox(client.events)
		}
	}

	static func run() async {
		Check.section("Sessions, in memory")
		await Check.runs("a Mac connects, proves itself and is ready", macConnects)
		await Check.runs("the Mac's requests, one at a time", macRequests)
		await Check.runs("the mailbox, both ways, and a repeat dropped", mailbox)
		await Check.runs("the channel's bytes and the notices", bytesAndNotices)
		await Check.runs("busy: back only at the relay's time", busy)
		await Check.runs("refusals tried again, and refusals that stop", refusals)
		await Check.runs("what the relay must not send is not taken", unreadable)
		await Check.runs("a quiet socket is opened again", quiet)
		await Check.runs("a request whose socket drops", dropped)
		await Check.runs("a phone connects, and leaves", phoneLeaves)
		await Check.runs("register", register)
		await Check.runs("join, with the client data hash bound to the device key", join)
		await Check.runs("HTTP answers to the upgrade", http)
		await Check.runs("stop", stop)
	}

	// MARK: Helpers

	static func manualOptions() -> RelayOptions {
		var options = RelayOptions()
		options.clock = ManualClock()
		return options
	}

	static func json(_ text: String) throws -> JSONValue { try JSON.parse(text) }

	/// Plays the relay through a Mac's handshake: checks its hello and its proof, and answers `ready`.
	@discardableResult
	static func macReady(_ rig: Rig, ready: String = #"{"ready":{"devices":[],"left":[],"pending":true,"mail":0}}"#) async throws -> MemorySocket {
		let socket = try await rig.connector.next("the Mac's socket")
		Check.equal(socket.pairing, Formats.pairing, "the socket names its pairing, for the Pi2-Pairing header")
		Check.equal(try await socket.nextText("hello"), RelayOutgoing.hello(pairing: Formats.pairing, device: nil, role: .mac, build: RelayBuild("200")!).text, "the Mac's hello")
		let challenge = Bytes.random(32)
		socket.say(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#)
		let proof = try json(try await socket.nextText("the Mac's proof"))
		let signature = Base64URL.decode(proof["proof"]?["signature"]?.stringValue ?? "", count: 64) ?? Data()
		let text = try RelayProof.text(.mac, pairing: Formats.pairing, device: nil, challenge: challenge)
		Check.that(try relayKey.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: text), "the Mac signs the challenge's proof text with its relay key")
		socket.say(ready)
		_ = try await rig.events.next("ready") { if case .macReady = $0 { true } else { nil } }
		return socket
	}

	static func phoneReady(_ rig: Rig) async throws -> (MemorySocket, Data) {
		let socket = try await rig.connector.next("the phone's socket")
		Check.equal(
			try await socket.nextText("hello"), RelayOutgoing.hello(pairing: Formats.pairing, device: Formats.device, role: .device, build: RelayBuild("200")!).text,
			"the phone's hello")
		let challenge = Bytes.random(32)
		socket.say(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#)
		let proof = try json(try await socket.nextText("the phone's proof"))
		let signature = Base64URL.decode(proof["proof"]?["signature"]?.stringValue ?? "", count: 64) ?? Data()
		let text = try RelayProof.text(.device, pairing: Formats.pairing, device: Formats.device, challenge: challenge)
		Check.that(try deviceKey.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: text), "the phone signs the challenge's proof text with its device key")
		socket.say(#"{"ready":{"mac":true,"mail":2}}"#)
		let ready = try await rig.events.next("ready") { if case let .deviceReady(online, mail) = $0 { (online, mail) } else { nil } }
		Check.that(ready == (true, 2), "the phone's ready says the Mac is there and two items wait")
		return (socket, challenge)
	}

	/// The next `disconnected` event's reason and time.
	static func disconnected(_ rig: Rig) async throws -> (RelayDrop, Int64) {
		do {
			return try await rig.events.next("disconnected") { if case let .disconnected(drop, at) = $0 { (drop, at) } else { nil } }
		} catch let timeout as Timeout {
			throw Timeout(what: "\(timeout.what), after \(rig.events.all), sleepers until \(rig.clock.deadlines.map { $0 - 1_800_000_000_000 })")
		}
	}

	static func stopped(_ rig: Rig) async throws -> RelayStop {
		try await rig.events.next("stopped") { if case let .stopped(reason) = $0 { reason } else { nil } }
	}

	// MARK: Checks

	static func macConnects() async throws {
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await rig.connector.next("the Mac's socket")
		_ = try await socket.nextText("hello")
		Check.holds(await !rig.client.isReady, "not ready before its proof is taken")
		await Check.throwsError("a request before ready", .notConnected) { try await rig.client.closeJoin() }
		let challenge = Bytes.random(32)
		socket.say(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#)
		_ = try await socket.nextText("proof")
		socket.say(#"{"pong":{}}"#)
		socket.say(#"{"ready":{"devices":[{"device":"dev_EBESExQVFhcYGRobHB0eHw","online":false}],"left":["dev_EBESExQVFhcYGRobHB0eHw"],"pending":false,"mail":1}}"#)
		let ready = try await rig.events.next("ready") { if case let .macReady(ready) = $0 { ready } else { nil } }
		Check.equal(ready, RelayMacReady(devices: [RelayDevicePresence(device: Formats.device, online: false)], left: [Formats.device], pending: false, mail: 1), "ready, as the relay said it")
		Check.holds(await rig.client.isReady, "ready once the relay says so")
		await Check.throwsError("a phone's request from the Mac", .wrongEnd) { try await rig.client.setPushToken(String(repeating: "0a", count: 32), environment: .production) }
		await Check.throwsError("a put to the Mac from the Mac", .wrongEnd) { try await rig.client.put(Formats.sealed, id: Formats.item, to: .mac) }
		await rig.client.stop()
	}

	static func macRequests() async throws {
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await macReady(rig)
		let hash = Data(repeating: 3, count: 32)

		let opened = Task { try await rig.client.openJoin(tokenHash: hash, expires: 1_800_000_300_000) }
		Check.equal(try await socket.nextText("openJoin"), RelayOutgoing.openJoin(tokenHash: hash, expires: 1_800_000_300_000).text, "openJoin as sent")
		// The next request waits for this one's answer.
		let closed = Task { try await rig.client.closeJoin() }
		Check.holds(try await socket.sent.take(seconds: 0.2) == nil, "a second request waits for the first's answer")
		socket.say(#"{"ok":{"what":"openJoin"}}"#)
		try await opened.value
		Check.equal(try await socket.nextText("closeJoin"), #"{"closeJoin":{}}"#, "closeJoin, once openJoin was answered")
		socket.say(#"{"refused":{"what":"closeJoin","why":"unavailable"}}"#)
		await Check.throwsError("a request refused", .refused(.unavailable)) { try await closed.value }

		let added = Task { try await rig.client.addDevice(Formats.device, deviceKey: deviceKey.publicKey, attestKeyId: Formats.keyID) }
		_ = try await socket.nextText("addDevice")
		socket.say(#"{"ok":{"what":"addDevice"}}"#)
		try await added.value
		let removed = Task { try await rig.client.removeDevice(Formats.device) }
		Check.equal(try await socket.nextText("removeDevice"), RelayOutgoing.removeDevice(Formats.device).text, "removeDevice as sent")
		socket.say(#"{"ok":{"what":"removeDevice"}}"#)
		try await removed.value
		let state = Task { try await rig.client.putState(Formats.sealed, id: Formats.item, for: Formats.device) }
		Check.equal(try await socket.nextText("state"), RelayOutgoing.state(device: Formats.device, id: Formats.item, item: Formats.sealed).text, "state as sent")
		socket.say(#"{"ok":{"what":"state"}}"#)
		try await state.value
		await Check.throwsError("what the relay would refuse is not sent", .invalid(RemoteKitError("relay openJoin", "a token hash is not 32 bytes"))) {
			try await rig.client.openJoin(tokenHash: Data(count: 31), expires: 1)
		}
		Check.holds(try await socket.sent.take(seconds: 0.1) == nil, "and nothing went to the relay")

		let deleted = Task { try await rig.client.deletePairing() }
		_ = try await socket.nextText("deletePairing")
		socket.say(#"{"ok":{"what":"deletePairing"}}"#)
		socket.say(#"{"refused":{"why":"deleted"}}"#)
		socket.hangUp(code: 4008, reason: "deleted")
		try await deleted.value
		Check.equal(try await stopped(rig), .refused(.deleted), "a deleted pairing stops the client")
		Check.holds(try await rig.connector.sockets.take(seconds: 0.2) == nil, "and it does not connect again")
	}

	static func mailbox() async throws {
		let item2 = ItemID.random()
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await macReady(rig)
		let sealed = Base64URL.encode(Formats.sealed)
		func taking(_ answer: [String]) async throws -> RelayTaken {
			let taken = Task { try await rig.client.take() }
			Check.equal(try await socket.nextText("take"), #"{"take":{}}"#, "take as sent")
			for line in answer { socket.say(line) }
			return try await taken.value
		}
		let first = try await taking([
			#"{"item":{"from":"dev_EBESExQVFhcYGRobHB0eHw","id":"\#(Formats.item.text)","item":"\#(sealed)","presence":true}}"#,
			#"{"item":{"from":"dev_EBESExQVFhcYGRobHB0eHw","id":"\#(item2.text)","item":"\#(sealed)","presence":false}}"#,
			#"{"taken":{"count":2}}"#,
		])
		Check.equal(first.items.map(\.id), [Formats.item, item2], "the items taken, oldest first")
		Check.equal(first.items.map(\.presence), [true, false], "with their flags")
		Check.equal(first.repeats, 0, "none a repeat")
		let second = try await taking([
			#"{"item":{"from":"dev_EBESExQVFhcYGRobHB0eHw","id":"\#(item2.text)","item":"\#(sealed)","presence":false}}"#,
			#"{"taken":{"count":1}}"#,
		])
		Check.that(second.items.isEmpty && second.repeats == 1, "an item handed over again is dropped as a repeat")
		Check.holds(await rig.client.itemMemory.count == 2, "the memory holds the two taken")
		let none = try await taking([#"{"taken":{"count":0}}"#])
		Check.that(none.items.isEmpty && none.state == nil, "an empty mailbox")

		let put = Task { try await rig.client.put(Formats.sealed, id: Formats.item, to: .device(Formats.device)) }
		_ = try await socket.nextText("put")
		socket.say(#"{"ok":{"what":"put"}}"#)
		Check.equal(try await put.value, .stored, "a put stored")
		let again = Task { try await rig.client.put(Formats.sealed, id: Formats.item, to: .device(Formats.device)) }
		_ = try await socket.nextText("put again")
		socket.say(#"{"refused":{"what":"put","why":"exists"}}"#)
		Check.equal(try await again.value, .alreadyThere, "a put sent again after a drop, already stored")
		let full = Task { try await rig.client.put(Formats.sealed, id: item2, to: .device(Formats.device)) }
		_ = try await socket.nextText("put to a full mailbox")
		socket.say(#"{"refused":{"what":"put","why":"mailbox-full"}}"#)
		await Check.throwsError("a put to a full mailbox", .refused(.mailboxFull)) { try await full.value }

		// A count that is not what came is not a take.
		let wrong = Task { try await rig.client.take() }
		_ = try await socket.nextText("take, answered wrongly")
		socket.say(#"{"taken":{"count":1}}"#)
		await Check.throwsError("a take whose count is not what came", .disconnected) { try await wrong.value }
		Check.equal(try await disconnected(rig).0, .unreadable, "and the socket is opened again")
		await rig.client.stop()

		// A phone's mailbox brings its state, and its memory carries over from a client before.
		var memory = RelayItemMemory()
		_ = memory.isNew(RelayMailItem(from: .mac, id: item2, item: Formats.sealed, presence: false), at: rig.clock.now())
		let phone = Rig(.device(Formats.pairing, Formats.device), memory: memory)
		await phone.client.start()
		let (phoneSocket, _) = try await phoneReady(phone)
		let taken = Task { try await phone.client.take() }
		_ = try await phoneSocket.nextText("take")
		phoneSocket.say(#"{"item":{"from":"mac","id":"\#(item2.text)","item":"\#(sealed)","presence":false}}"#)
		phoneSocket.say(#"{"item":{"from":"mac","id":"\#(Formats.item.text)","item":"\#(sealed)","presence":false}}"#)
		phoneSocket.say(#"{"state":{"id":"\#(item2.text)","item":"\#(sealed)"}}"#)
		phoneSocket.say(#"{"taken":{"count":3}}"#)
		let result = try await taken.value
		Check.equal(result.items.map(\.id), [Formats.item], "a repeat of an item taken by the client before is dropped")
		Check.equal(result.state, RelayStateItem(id: item2, item: Formats.sealed), "the state is handed over, whatever its id")
		let put2 = Task { try await phone.client.put(Formats.sealed, id: Formats.item, to: .mac, presence: true) }
		Check.equal(try await phoneSocket.nextText("put"), RelayOutgoing.put(to: .mac, id: Formats.item, item: Formats.sealed, presence: true).text, "a phone's put, marked presence")
		phoneSocket.say(#"{"ok":{"what":"put"}}"#)
		_ = try await put2.value
		await Check.throwsError("a put to a device from a phone", .wrongEnd) { try await phone.client.put(Formats.sealed, id: Formats.item, to: .device(Formats.device)) }
		await phone.client.stop()
	}

	static func bytesAndNotices() async throws {
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await macReady(rig)
		let deviceBytes = Base64URL.decode(String(Formats.device.text.dropFirst(4)), count: 16)!
		socket.sayBytes(deviceBytes + Data([1, 2, 3]))
		let data = try await rig.events.next("data") { if case let .data(from, bytes) = $0 { (from, bytes) } else { nil } }
		Check.that(data.0 == Formats.device && data.1 == Data([1, 2, 3]), "a phone's bytes reach the Mac with its id taken off")
		try await rig.client.send(Data([4, 5]), to: Formats.device)
		Check.equal(try await socket.nextBytes("bytes to a phone"), deviceBytes + Data([4, 5]), "the Mac's bytes go with the phone's id in front")
		await Check.throwsError("empty bytes are not sent", .invalid(RemoteKitError("relay data", "empty or too long"))) { try await rig.client.send(Data(), to: Formats.device) }
		await Check.throwsError("nor more than a message holds", .invalid(RemoteKitError("relay data", "empty or too long"))) {
			try await rig.client.send(Data(count: RelayLimits.maxBinary), to: Formats.device)
		}
		let notices: [(String, RelayEvent)] = [
			(#"{"online":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, .online(Formats.device)),
			(#"{"offline":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, .offline(Formats.device)),
			(#"{"left":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#, .left(Formats.device)),
			(#"{"anotherMac":{}}"#, .anotherMac),
			(#"{"held":{"device":"dev_EBESExQVFhcYGRobHB0eHw","until":1800000005000}}"#, .held(Formats.device, until: 1_800_000_005_000)),
			(#"{"mail":{}}"#, .mail),
			(
				#"{"joined":{"device":"dev_EBESExQVFhcYGRobHB0eHw","deviceKey":"\#(Formats.keyText)","keyId":"\#(Formats.keyID.text)"}}"#,
				.phoneJoined(RelayJoinNotice(slot: Formats.device, deviceKey: Formats.key.publicKey, keyId: Formats.keyID))
			),
		]
		for (line, expected) in notices {
			socket.say(line)
			Check.equal(try await rig.events.next("a notice"), expected, "a notice: \(line)")
		}
		await rig.client.stop()

		let phone = Rig(.device(Formats.pairing, Formats.device))
		await phone.client.start()
		let (phoneSocket, _) = try await phoneReady(phone)
		phoneSocket.sayBytes(Data([9, 9]))
		Check.equal(try await phone.events.next("data"), .data(from: nil, Data([9, 9])), "the Mac's bytes reach the phone as they are")
		try await phone.client.send(Data([7]))
		Check.equal(try await phoneSocket.nextBytes("a phone's bytes"), Data([7]), "a phone's bytes go as they are")
		phoneSocket.say(#"{"mac":{"online":false}}"#)
		Check.equal(try await phone.events.next("mac"), .macOnline(false), "the phone hears the Mac went")
		await Check.throwsError("a Mac's send from a phone", .wrongEnd) { try await phone.client.send(Data([1]), to: Formats.device) }
		await phone.client.stop()
	}

	static func busy() async throws {
		let rig = Rig(.device(Formats.pairing, Formats.device))
		await rig.client.start()
		let (socket, _) = try await phoneReady(rig)
		let until = rig.clock.now() + 4_000
		socket.say(#"{"busy":{"until":\#(until)}}"#)
		socket.hangUp(code: 4010, reason: "busy")
		let (drop, at) = try await disconnected(rig)
		Check.equal(drop, .busy(until: until), "busy is a drop, not a broken pairing")
		Check.equal(at, until, "and the client comes back at the relay's time (no jitter in this check)")
		try await rig.clock.waitForSleeper(until: at)
		rig.clock.advance(3_999)
		Check.holds(try await rig.connector.sockets.take(seconds: 0.2) == nil, "not a moment before")
		rig.clock.advance(1)
		_ = try await phoneReady(rig)
		await rig.client.stop()

		// A phone held off for the day is answered busy at its hello, and waits the hour.
		let held = Rig(.device(Formats.pairing, Formats.device))
		await held.client.start()
		let first = try await held.connector.next("socket")
		_ = try await first.nextText("hello")
		let hour = held.clock.now() + 3_600_000
		first.say(#"{"busy":{"until":\#(hour)}}"#)
		first.hangUp(code: 4010, reason: "busy")
		Check.equal(try await disconnected(held).1, hour, "busy at hello waits until the relay's time too")
		await held.client.stop()
	}

	static func refusals() async throws {
		// Tried again, with backoff.
		for why in ["unavailable", "timeout", "too-many"] {
			let rig = Rig(.mac(Formats.pairing))
			await rig.client.start()
			let socket = try await rig.connector.next("socket")
			_ = try await socket.nextText("hello")
			socket.say(#"{"refused":{"why":"\#(why)"}}"#)
			socket.hangUp(code: 4001, reason: why)
			let (drop, at) = try await disconnected(rig)
			Check.equal(drop, .refused(RelayWhy(word: why)!), "\(why) is tried again")
			Check.equal(at - rig.clock.now(), 500, "after the first backoff")
			try await rig.clock.waitForSleeper(until: at)
			rig.clock.advance(500)
			let next = try await rig.connector.next("the socket again")
			_ = try await next.nextText("hello again")
			next.hangUp()
			let (lost, later) = try await disconnected(rig)
			Check.equal(lost, .lost, "a socket that closes without a word is lost")
			Check.equal(later - rig.clock.now(), 1_000, "and the wait doubles")
			await rig.client.stop()
		}

		// Another Mac connected: wait for the relay to give up on a quiet one.
		let other = Rig(.mac(Formats.pairing))
		await other.client.start()
		let socket = try await other.connector.next("socket")
		_ = try await socket.nextText("hello")
		socket.say(#"{"challenge":"\#(Base64URL.encode(Bytes.random(32)))"}"#)
		_ = try await socket.nextText("proof")
		socket.say(#"{"refused":{"why":"another-mac"}}"#)
		socket.hangUp(code: 4004, reason: "another-mac")
		let (drop, at) = try await disconnected(other)
		Check.equal(drop, .refused(.anotherMac), "another Mac connected is tried again")
		Check.equal(at - other.clock.now(), 30_000, "after half a minute, not the first backoff")
		await other.client.stop()

		// Stopped: trying again cannot help.
		for why in ["not-listed", "unknown-pairing", "signature", "update-required", "removed", "left", "deleted", "replaced", "malformed", "a-word-from-a-newer-relay"] {
			let rig = Rig(.device(Formats.pairing, Formats.device))
			await rig.client.start()
			let socket = try await rig.connector.next("socket")
			_ = try await socket.nextText("hello")
			socket.say(#"{"refused":{"why":"\#(why)"}}"#)
			socket.hangUp(code: 4002, reason: why)
			Check.equal(try await stopped(rig), .refused(RelayWhy(word: why)!), "\(why) stops the client")
			Check.holds(try await rig.connector.sockets.take(seconds: 0.1) == nil, "\(why): no socket after")
		}

		// The refusal's message lost, its word still the closing's reason.
		let reason = Rig(.device(Formats.pairing, Formats.device))
		await reason.client.start()
		let closing = try await reason.connector.next("socket")
		_ = try await closing.nextText("hello")
		closing.hangUp(code: 4002, reason: "not-listed")
		Check.equal(try await stopped(reason), .refused(.notListed), "a closing's reason is read as its refusal")
	}

	static func unreadable() async throws {
		let cases: [(String, (MemorySocket) -> Void)] = [
			("an answer to no request", { $0.say(#"{"ok":{"what":"put"}}"#) }),
			("a second ready", { $0.say(#"{"ready":{"devices":[],"left":[],"pending":true,"mail":0}}"#) }),
			("a challenge once ready", { $0.say(#"{"challenge":"\#(Base64URL.encode(Data(count: 32)))"}"#) }),
			("a phone's notice", { $0.say(#"{"mac":{"online":true}}"#) }),
			("bytes with no device's id", { $0.sayBytes(Data(count: 16)) }),
			("bytes too long", { $0.sayBytes(Data(count: RelayLimits.maxBinary + 1)) }),
			("white space", { $0.say(#"{"mail": {}}"#) }),
			("anything after a refusal but the closing", {
				$0.say(#"{"refused":{"why":"not-listed"}}"#)
				$0.say(#"{"mail":{}}"#)
			}),
		]
		for (name, act) in cases {
			let rig = Rig(.mac(Formats.pairing))
			await rig.client.start()
			let socket = try await macReady(rig)
			act(socket)
			Check.equal(try await disconnected(rig).0, .unreadable, "\(name) is not read, and the socket is opened again")
			Check.that(socket.isClosedByClient, "\(name): the client closed the socket")
			await rig.client.stop()
		}

		// A challenge that is not 32 bytes is not signed.
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await rig.connector.next("socket")
		_ = try await socket.nextText("hello")
		socket.say(#"{"challenge":"\#(Base64URL.encode(Data(count: 31)))"}"#)
		Check.equal(try await disconnected(rig).0, .unreadable, "a challenge of 31 bytes is not taken")
		Check.that(socket.sent.waiting.isEmpty, "and nothing was signed over it")
		await rig.client.stop()
	}

	static func quiet() async throws {
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let started = rig.clock.now()
		let socket = try await macReady(rig)
		try await rig.clock.waitForSleeper(until: started + 30_000)
		rig.clock.advance(30_000)
		Check.equal(try await socket.nextText("a ping"), #"{"ping":{}}"#, "the Mac pings every 30 seconds")
		socket.say(#"{"pong":{}}"#)
		// No answer from here. The pong was heard at 30 or 60 seconds (it may be read after the clock moved on), so the
		// first look at least 75 seconds after it, at 120 or 150, finds the socket quiet; until then each look pings.
		var look = started + 60_000
		var pings = 0
		while true {
			try await rig.clock.waitForSleeper(until: look)
			rig.clock.advance(look - rig.clock.now())
			guard (try? await socket.nextText("a ping or the closing")) != nil else { break }
			pings += 1
			look += 30_000
			guard look <= started + 150_000 else { throw Timeout(what: "the socket taken for dead") }
		}
		Check.holds(rig.clock.now() - started >= 120_000, "not before 75 seconds without a word (pinged \(pings) more times)")
		Check.equal(try await disconnected(rig).0, .quiet, "a socket that has heard nothing for 75 seconds is taken for dead")
		Check.that(socket.isClosedByClient, "and closed")
		await rig.client.stop()

		// A handshake the relay never answers.
		let hang = Rig(.mac(Formats.pairing))
		await hang.client.start()
		let start = hang.clock.now()
		let hung = try await hang.connector.next("socket")
		_ = try await hung.nextText("hello")
		try await hang.clock.waitForSleeper(until: start + 30_000)
		hang.clock.advance(30_000)
		Check.equal(try await disconnected(hang).0, .quiet, "a hello unanswered for 30 seconds")
		await hang.client.stop()

		// A request the relay never answers.
		let slow = Rig(.mac(Formats.pairing))
		await slow.client.start()
		let begun = slow.clock.now()
		let slowSocket = try await macReady(slow)
		let request = Task { try await slow.client.closeJoin() }
		_ = try await slowSocket.nextText("closeJoin")
		try await slow.clock.waitForSleeper(until: begun + 30_000)
		slow.clock.advance(30_000)
		await Check.throwsError("a request unanswered for 30 seconds", .disconnected) { try await request.value }
		Check.equal(try await disconnected(slow).0, .quiet, "takes its socket for dead")
		await slow.client.stop()
	}

	static func dropped() async throws {
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await macReady(rig)
		let request = Task { try await rig.client.openJoin(tokenHash: Data(count: 32), expires: 1) }
		_ = try await socket.nextText("openJoin")
		socket.hangUp()
		await Check.throwsError("a request whose socket drops before its answer", .disconnected) { try await request.value }
		let (drop, at) = try await disconnected(rig)
		Check.equal(drop, .lost, "the socket lost")
		try await rig.clock.waitForSleeper(until: at)
		rig.clock.advance(at - rig.clock.now())
		try await macReady(rig)
		let again = Task { try await rig.client.closeJoin() }
		await rig.client.stop()
		await Check.throwsError("a request when stopped", .stopped) { try await again.value }
	}

	static func phoneLeaves() async throws {
		let rig = Rig(.device(Formats.pairing, Formats.device))
		await rig.client.start()
		let (socket, challenge) = try await phoneReady(rig)
		let token = Task { try await rig.client.setPushToken(String(repeating: "ab", count: 32), environment: .development) }
		Check.equal(try await socket.nextText("token"), RelayOutgoing.token(apns: String(repeating: "ab", count: 32), environment: .development).text, "token as sent")
		socket.say(#"{"ok":{"what":"token"}}"#)
		try await token.value
		let left = Task { try await rig.client.leave() }
		let leave = try json(try await socket.nextText("leave"))
		let signature = Base64URL.decode(leave["leave"]?["signature"]?.stringValue ?? "", count: 64) ?? Data()
		let text = try RelayProof.text(.leave, pairing: Formats.pairing, device: Formats.device, challenge: challenge)
		Check.that(try deviceKey.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: text), "leave is signed over this connection's challenge")
		socket.say(#"{"refused":{"why":"left"}}"#)
		socket.hangUp(code: 4008, reason: "left")
		try await left.value
		Check.equal(try await stopped(rig), .refused(.left), "and the client stops")
	}

	static func register() async throws {
		let connector = MemoryConnector()
		let options = manualOptions()
		let registered = Task { try await RelayClient.register(relay: url, build: RelayBuild("200")!, relayKey: RelaySigner(relayKey), connector: connector, options: options) }
		let socket = try await connector.next("socket")
		Check.that(socket.pairing == nil, "a registration names no pairing: no Pi2-Pairing header")
		Check.equal(try await socket.nextText("register"), RelayOutgoing.register(build: RelayBuild("200")!, relayKey: relayKey.publicKey).text, "register as sent")
		let challenge = Bytes.random(32)
		socket.say(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#)
		let proof = try json(try await socket.nextText("proof"))
		let signature = Base64URL.decode(proof["proof"]?["signature"]?.stringValue ?? "", count: 64) ?? Data()
		Check.that(
			try relayKey.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: RelayProof.text(.register, pairing: nil, device: nil, challenge: challenge)),
			"register's proof, with the relay key")
		socket.say(#"{"registered":{"pairing":"\#(Formats.pairing.text)"}}"#)
		Check.equal(try await registered.value, Formats.pairing, "the new pairing's id")
		Check.that(socket.isClosedByClient, "the registering socket is closed")

		let old = Task { try await RelayClient.register(relay: url, build: RelayBuild("1")!, relayKey: RelaySigner(relayKey), connector: connector, options: options) }
		let oldSocket = try await connector.next("socket")
		_ = try await oldSocket.nextText("register")
		oldSocket.say(#"{"refused":{"why":"update-required"}}"#)
		oldSocket.hangUp(code: 4003, reason: "update-required")
		await Check.throwsError("register below the minimum build", .refused(.updateRequired)) { try await old.value }

		connector.failNext(RelaySocketClosed(httpStatus: 429))
		await Check.throwsError("too many registrations from one address", .http(429)) {
			try await RelayClient.register(relay: url, build: RelayBuild("200")!, relayKey: RelaySigner(relayKey), connector: connector, options: options)
		}
		_ = try await connector.next("the failed socket")

		let wrongKey = RelaySigner(publicKey: P256.Signing.PrivateKey().publicKey, sign: { try relayKey.sign($0) })
		let wrong = Task { try await RelayClient.register(relay: url, build: RelayBuild("200")!, relayKey: wrongKey, connector: connector, options: options) }
		let wrongSocket = try await connector.next("socket")
		_ = try await wrongSocket.nextText("register")
		wrongSocket.say(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#)
		await Check.throwsError("a key that signs as another is found before the relay refuses it", .cannotSign) { try await wrong.value }
		Check.that(wrongSocket.sent.waiting.isEmpty, "and its signature is not sent")
	}

	static func join() async throws {
		let connector = MemoryConnector()
		let options = manualOptions()
		let token = Bytes.random(32)
		let seen = Queue<Data>()
		let joining = Task { try await RelayClient.join(
			relay: url, pairing: Formats.pairing, build: RelayBuild("200")!, deviceKey: deviceKey.publicKey, token: token,
			attest: { hash in
				seen.put(hash)
				return RelayAttestation(attestation: Data([1, 2, 3]), keyId: Formats.keyID)
			}, connector: connector, options: options) }
		let socket = try await connector.next("socket")
		Check.equal(socket.pairing, Formats.pairing, "a join names its pairing")
		Check.equal(
			try await socket.nextText("hello"), RelayOutgoing.hello(pairing: Formats.pairing, device: nil, role: .device, build: RelayBuild("200")!).text,
			"a joining phone's hello, with no device")
		let challenge = Bytes.random(32)
		socket.say(#"{"challenge":"\#(Base64URL.encode(challenge))"}"#)
		Check.equal(try await seen.take(seconds: 10), PairingSecrets.joinClientDataHash(challenge: challenge, deviceKey: deviceKey.publicKey), "App Attest is asked for the join's client data hash")
		Check.equal(
			try await socket.nextText("join"),
			RelayOutgoing.join(pairing: Formats.pairing, deviceKey: deviceKey.publicKey, attestation: Data([1, 2, 3]), keyId: Formats.keyID, token: token).text, "join as sent")
		socket.say(#"{"joined":{"device":"\#(Formats.device.text)"}}"#)
		let link = try await joining.value
		Check.equal(link.slot, Formats.device, "the slot the relay gave")
		let events = Inbox(link.events)
		socket.sayBytes(Data([1]))
		Check.equal(try await events.next("data"), .data(Data([1])), "the Mac's bytes on a joined socket")
		try await link.send(Data([2]))
		Check.equal(try await socket.nextBytes("bytes"), Data([2]), "a joined phone's bytes")
		socket.say(#"{"mac":{"online":true}}"#)
		Check.equal(try await events.next("mac"), .macOnline(true), "a joined phone hears of the Mac")
		socket.say(#"{"refused":{"why":"window-ended"}}"#)
		socket.hangUp(code: 4008, reason: "window-ended")
		Check.equal(try await events.next("end"), .ended(.refused(.windowEnded)), "a window that ended before the Mac added the phone")

		let refused = Task { try await RelayClient.join(
			relay: url, pairing: Formats.pairing, build: RelayBuild("200")!, deviceKey: deviceKey.publicKey, token: token,
			attest: { _ in RelayAttestation(attestation: Data([1]), keyId: Formats.keyID) }, connector: connector, options: options) }
		let second = try await connector.next("socket")
		_ = try await second.nextText("hello")
		second.say(#"{"refused":{"why":"window-closed"}}"#)
		second.hangUp(code: 4002, reason: "window-closed")
		await Check.throwsError("a join with no window open", .refused(.windowClosed)) { try await refused.value }
	}

	static func http() async throws {
		let rig = Rig(.mac(Formats.pairing))
		rig.connector.failNext(RelaySocketClosed(httpStatus: 503))
		rig.connector.failNext(RelaySocketClosed(httpStatus: 403))
		await rig.client.start()
		Check.equal(try await disconnected(rig).0, .http(503), "a relay missing a setting is tried again")
		_ = try await rig.connector.next("the first socket")
		let at = rig.clock.now() + 500
		try await rig.clock.waitForSleeper(until: at)
		rig.clock.advance(500)
		Check.equal(try await stopped(rig), .http(403), "403, as for a web page's Origin, stops it: the client sends none, so it is a fault")
	}

	static func stop() async throws {
		let rig = Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await macReady(rig)
		let request = Task { try await rig.client.closeJoin() }
		_ = try await socket.nextText("closeJoin")
		await rig.client.stop()
		await Check.throwsError("a request in flight when stopped", .stopped) { try await request.value }
		Check.equal(try await stopped(rig), .stopped, "stopped by its user")
		Check.that(socket.isClosedByClient, "its socket closed")
		Check.holds(try await rig.connector.sockets.take(seconds: 0.1) == nil, "and nothing opened after")
		await rig.client.start()
		Check.holds(try await rig.connector.sockets.take(seconds: 0.1) == nil, "a stopped client does not start again")
	}
}
