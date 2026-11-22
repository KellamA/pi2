
import CryptoKit
import Foundation
import RemoteKit

/// What a hostile relay, or a caller that does not read, must not be able to make of the client (#678's security read):
/// unbounded growth, a reconnection that never waits, a join link that hangs, a leave that waits for ever, a take past
/// what a mailbox holds, and an address in clear.
enum Hostile {
	static func run() async {
		Check.section("A hostile relay, in memory")
		await Check.runs("repeated notices are reported once", repeats)
		await Check.runs("a caller that does not read holds no more than the bound", unread)
		await Check.runs("busy with a time already past still backs off", busyPast)
		await Check.runs("a take past what a mailbox holds is not taken", takeBound)
		await Check.runs("leave answered before it waits", leaveAtOnce)
		await Check.runs("a join link that hears nothing ends", quietLink)
		await Check.runs("a join link that nobody reads ends", unreadLink)
		await Check.runs("only wss, or ws to this computer", addresses)
	}

	static func options(_ clock: ManualClock, buffer: Int = 256) -> RelayOptions {
		var options = RelayOptions()
		options.clock = clock
		options.random = { 0 }
		options.eventBuffer = buffer
		return options
	}

	static func repeats() async throws {
		let rig = Sessions.Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await Sessions.macReady(rig)
		for _ in 0..<5_000 { socket.say(#"{"mail":{}}"#) }
		for _ in 0..<100 { socket.say(#"{"online":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#) }
		socket.say(#"{"anotherMac":{}}"#)
		_ = try await rig.events.next("the marker") { $0 == .anotherMac ? true : nil }
		Check.equal(rig.events.all.filter { $0 == .mail }.count, 1, "5,000 mail notices are one until the next take")
		Check.equal(rig.events.all.filter { $0 == .online(Formats.device) }.count, 1, "100 notices that a device is online are one")
		let taken = Task { try await rig.client.take() }
		_ = try await socket.nextText("take")
		socket.say(#"{"taken":{"count":0}}"#)
		_ = try await taken.value
		socket.say(#"{"mail":{}}"#)
		socket.say(#"{"offline":{"device":"dev_EBESExQVFhcYGRobHB0eHw"}}"#)
		_ = try await rig.events.next("offline") { $0 == .offline(Formats.device) ? true : nil }
		Check.equal(rig.events.all.filter { $0 == .mail }.count, 2, "after a take, mail is reported again")
		await rig.client.stop()
	}

	static func unread() async throws {
		let clock = ManualClock()
		let connector = MemoryConnector()
		let client = try RelayClient(
			relay: Sessions.url, role: .mac(Formats.pairing), build: RelayBuild("200")!, signer: RelaySigner(Sessions.relayKey), connector: connector,
			options: options(clock, buffer: 8))
		await client.start()
		let socket = try await connector.next("socket")
		_ = try await socket.nextText("hello")
		socket.say(#"{"challenge":"\#(Base64URL.encode(Bytes.random(32)))"}"#)
		_ = try await socket.nextText("proof")
		socket.say(#"{"ready":{"devices":[],"left":[],"pending":true,"mail":0}}"#)
		let device = Base64URL.decode(String(Formats.device.text.dropFirst(4)), count: 16)!
		// Each a channel message of 64 KB, which nobody reads.
		for _ in 0..<50 { socket.sayBytes(device + Data(count: 64 * 1024)) }
		let limit = Date().addingTimeInterval(10)
		while !socket.isClosedByClient, Date() < limit { try await Task.sleep(for: .milliseconds(5)) }
		Check.that(socket.isClosedByClient, "past the bound, the client closes the socket rather than hold more")
		// It comes back through the backoff, not at once.
		Check.holds(try await connector.sockets.take(seconds: 0.2) == nil, "and does not open another at once")
		let deadline = try await waitForAnySleeper(clock)
		clock.advance(deadline - clock.now())
		_ = try await connector.next("the socket again")
		await client.stop()
		Check.holds(await client.stopReason == .stopped, "why it stopped can be read when its events could not hold it")
		var held = 0
		var sawStopped = false
		for await event in client.events {
			held += 1
			if case .stopped = event { sawStopped = true }
		}
		Check.that(held <= 8, "a caller that did not read finds no more than the bound (\(held))")
		Check.that(!sawStopped || held <= 8, "and stopped only if there was room")
	}

	/// The time the run loop sleeps until, once it sleeps: the latest of the sleepers' times.
	static func waitForAnySleeper(_ clock: ManualClock) async throws -> Int64 {
		let limit = Date().addingTimeInterval(10)
		while Date() < limit {
			if let latest = clock.deadlines.max() { return latest }
			try await Task.sleep(for: .milliseconds(2))
		}
		throw Timeout(what: "a sleeper")
	}

	static func busyPast() async throws {
		let rig = Sessions.Rig(.device(Formats.pairing, Formats.device))
		await rig.client.start()
		var waits: [Int64] = []
		for _ in 0..<4 {
			let socket = try await rig.connector.next("socket")
			_ = try await socket.nextText("hello")
			socket.say(#"{"busy":{"until":1}}"#)
			socket.hangUp(code: 4010, reason: "busy")
			let (drop, at) = try await Sessions.disconnected(rig)
			Check.equal(drop, .busy(until: 1), "busy, with a time long past")
			waits.append(at - rig.clock.now())
			try await rig.clock.waitForSleeper(until: at)
			rig.clock.advance(at - rig.clock.now())
		}
		Check.equal(waits, [500, 1_000, 2_000, 4_000], "each busy with a time past waits the backoff, which grows")
		await rig.client.stop()
	}

	static func takeBound() async throws {
		let rig = Sessions.Rig(.mac(Formats.pairing))
		await rig.client.start()
		let socket = try await Sessions.macReady(rig)
		let taken = Task { try await rig.client.take() }
		_ = try await socket.nextText("take")
		let sealed = Base64URL.encode(Formats.sealed)
		for _ in 0...RelayLimits.macMailbox {
			socket.say(#"{"item":{"from":"dev_EBESExQVFhcYGRobHB0eHw","id":"\#(ItemID.random().text)","item":"\#(sealed)","presence":false}}"#)
		}
		await Check.throwsError("201 items in one take, more than the Mac's mailbox holds", .disconnected) { try await taken.value }
		Check.equal(try await Sessions.disconnected(rig).0, .unreadable, "and the socket is opened again")
		await rig.client.stop()
	}

	static func leaveAtOnce() async throws {
		let rig = Sessions.Rig(.device(Formats.pairing, Formats.device))
		await rig.client.start()
		let (socket, _) = try await Sessions.phoneReady(rig)
		// The relay answers the leave as it arrives, before the client could start waiting for it.
		socket.onSend.withLock {
			$0 = { frame in
				guard case let .text(text) = frame, text.hasPrefix(#"{"leave""#) else { return }
				socket.say(#"{"refused":{"why":"left"}}"#)
				socket.hangUp(code: 4008, reason: "left")
			}
		}
		let left = Task { try await rig.client.leave() }
		let finished = Task {
			try await Task.sleep(for: .seconds(10))
			left.cancel()
		}
		try await left.value
		finished.cancel()
		Check.equal(try await Sessions.stopped(rig), .refused(.left), "leave returns, and the client stops")
	}

	static func quietLink() async throws {
		let clock = ManualClock()
		let connector = MemoryConnector()
		let joining = Task {
			try await RelayClient.join(
				relay: Sessions.url, pairing: Formats.pairing, build: RelayBuild("200")!, deviceKey: Sessions.deviceKey.publicKey, token: Data(count: 32),
				attest: { _ in RelayAttestation(attestation: Data([1]), keyId: Formats.keyID) }, connector: connector, options: options(clock))
		}
		let socket = try await connector.next("socket")
		_ = try await socket.nextText("hello")
		socket.say(#"{"challenge":"\#(Base64URL.encode(Bytes.random(32)))"}"#)
		_ = try await socket.nextText("join")
		socket.say(#"{"joined":{"device":"\#(Formats.device.text)"}}"#)
		let link = try await joining.value
		let events = Inbox(link.events)
		let start = clock.now()
		// Pings go unanswered: at 75 seconds without a word, the next look ends the link.
		for look in 1...3 {
			try await clock.waitForSleeper(until: start + Int64(look) * 30_000)
			clock.advance(30_000)
			if look < 3 { Check.equal(try await socket.nextText("a ping"), #"{"ping":{}}"#, "the link pings") }
		}
		Check.equal(try await events.next("the end"), .ended(.quiet), "a join link that heard nothing for 75 seconds ends")
		Check.that(socket.isClosedByClient, "and closes its socket")
	}

	static func unreadLink() async throws {
		let clock = ManualClock()
		let connector = MemoryConnector()
		let joining = Task {
			try await RelayClient.join(
				relay: Sessions.url, pairing: Formats.pairing, build: RelayBuild("200")!, deviceKey: Sessions.deviceKey.publicKey, token: Data(count: 32),
				attest: { _ in RelayAttestation(attestation: Data([1]), keyId: Formats.keyID) }, connector: connector, options: options(clock, buffer: 4))
		}
		let socket = try await connector.next("socket")
		_ = try await socket.nextText("hello")
		socket.say(#"{"challenge":"\#(Base64URL.encode(Bytes.random(32)))"}"#)
		_ = try await socket.nextText("join")
		socket.say(#"{"joined":{"device":"\#(Formats.device.text)"}}"#)
		let link = try await joining.value
		for _ in 0..<20 { socket.sayBytes(Data(count: 1024)) }
		let limit = Date().addingTimeInterval(10)
		while await link.endReason == nil, Date() < limit { try await Task.sleep(for: .milliseconds(5)) }
		Check.holds(await link.endReason == .overflow, "a join link whose events nobody reads ends past the bound")
	}

	static func addresses() async throws {
		let good = ["wss://relay.example/v1", "ws://127.0.0.1:8787/v1", "ws://localhost:1/v1", "ws://[::1]:1/v1"]
		let bad = ["ws://relay.example/v1", "http://127.0.0.1/v1", "https://relay.example/v1", "wss://user:secret@relay.example/v1", "wss:///v1", "wss://relay.example/v1?x=1", "ws://192.168.1.2/v1"]
		for text in good { Check.that(RelayEndpoint.isAllowed(URL(string: text)!), "a relay's address taken: \(text)") }
		for text in bad { Check.that(!RelayEndpoint.isAllowed(URL(string: text)!), "a relay's address refused: \(text)") }
		do {
			_ = try RelayClient(relay: URL(string: "ws://relay.example/v1")!, role: .mac(Formats.pairing), build: RelayBuild("1")!, signer: RelaySigner(Sessions.relayKey))
			Check.that(false, "a client for a relay in clear is not made")
		} catch {
			Check.that(error as? RelayClientError == .invalid(RemoteKitError("relay address", "not wss, or ws to this computer")), "a client for a relay in clear is not made")
		}
		await Check.throwsError("register at a relay in clear", .invalid(RemoteKitError("relay address", "not wss, or ws to this computer"))) {
			try await RelayClient.register(relay: URL(string: "ws://relay.example/v1")!, build: RelayBuild("200")!, relayKey: RelaySigner(Sessions.relayKey), connector: MemoryConnector())
		}
	}
}
