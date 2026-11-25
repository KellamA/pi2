import Darwin
import Dispatch
import Foundation
import RemoteKit
import pi2_remote

/// What phones' unfinished lines may make pi² Remote hold, and for how long (#908): pi² Remote in this process, with its
/// home listener on 127.0.0.1, this check its engine and its phones, over loopback. Its budget and its times are made
/// small, so that each case takes a second or two rather than 256 MiB or half a minute: 1.5 seconds with nothing more
/// of a line, 256 KiB a second the slowest link, and a budget of 3 MiB, then 8 MiB, in whole frames (a frame carries
/// 65,516 bytes of a line). The helper as a process, with its own times, is checked in Flows: a stalled line ended
/// within the resume window's wait.
enum Unfinished {
	static let frame = Frame.maxBodyLength

	/// Kept for the rest of the check: pi² Remote's queue and listener hold it unowned.
	nonisolated(unsafe) static var keptAlive: [(Remote, FakeEngine)] = []

	/// A line the phone may send, `frames` whole frames and a little more: all its messages but the last leave it
	/// unfinished, holding `frames` frames.
	static func line(frames: Int, id: String) -> Data {
		let head = Data("{\"id\":\"\(id)\",\"method\":\"engine.info\",\"params\":{\"pad\":\"".utf8), tail = Data("\"}}".utf8)
		return head + Data(repeating: UInt8(ascii: "u"), count: frames * frame + 10 - head.count - tail.count) + tail
	}

	/// A line as pi² Remote passes it on to the engine, in its session.
	static func carried(_ line: Data, session: String) -> Data { Data("{\"session\":\"\(session)\",\"message\":".utf8) + line + Data("}".utf8) }

	static func run() {
		Check.section("phones' unfinished lines in pi² Remote, over loopback: the budget, a stall, a slow honest line, phones held back (#908)")
		let folder = temporaryFolder("p2ru")
		defer { try? FileManager.default.removeItem(at: folder) }
		Log.shared.open(folder: folder)
		// Flows' helpers read the home key and the log where pi² Remote keeps them: here, this folder.
		let home = Flows.home
		Flows.home = folder
		defer { Flows.home = home }
		let queue = DispatchQueue(label: "check-unfinished")
		let (mine, theirs) = socketPair()
		let link = EngineLink(io: SocketIO(descriptor: theirs, queue: queue))
		guard let vault = try? KeyVaults.forBuild(.development, folder: folder), let keys = try? vault.macKeys(),
		      let remote = try? Remote(kind: .development, keys: keys, vault: vault, engine: link, queue: queue, advertiser: nil)
		else { return Check.expect(false, "pi² Remote starts in this process") }
		let engine = FakeEngine(descriptor: mine)
		keptAlive.append((remote, engine))
		queue.sync { link.start() }
		guard let mac = Flows.hello(engine, pairing: PairingID.random()) else { return Check.expect(false, "pi² Remote in this process says hello") }

		/// Waits for pi² Remote's queue to have done what `condition` waits for.
		func until(within seconds: Double = 10, _ condition: @escaping (Remote) -> Bool) -> Bool {
			let deadline = Date().addingTimeInterval(seconds)
			while Date() < deadline {
				if queue.sync(execute: { condition(remote) }) { return true }
				usleep(5000)
			}
			return false
		}
		func attachedSession(_ id: String) -> Bool { queue.sync { remote.sessions[id]?.isAttached == true } }

		let defaults = queue.sync { (remote.lineBudget, remote.lineStalledAfter, remote.slowestLine) }
		Check.expect(defaults == (256 * 1024 * 1024, .seconds(30), 64 * 1024), "by default: 256 MiB of unfinished lines in all, 30 seconds with nothing more of one, 64 KiB a second the slowest link")
		queue.sync {
			remote.lineStalledAfter = .seconds(1.5)
			remote.slowestLine = 256 * 1024
		}

		// Five devices, paired as the engine says `paired` (no claim: the pairing itself is Flows').
		let devices = (0 ..< 5).map { _ in (DeviceID.random(), PhoneKeys()) }
		for (id, keys) in devices { engine.event("paired", [("device", keys.paired(id: id))]) }
		guard until({ $0.devices.count == 5 }) else { return Check.expect(false, "five devices are paired") }
		func attach(_ index: Int, _ session: String) -> Phone? {
			let (id, keys) = devices[index]
			return Flows.attach(engine, mac: mac, device: id, keys: keys, session: session)?.0
		}

		// An honest phone on a slow link: a piece every 0.1 s, about 640 KiB a second, is never cut.
		guard let honest = attach(2, "u_honest") else { return Check.expect(false, "a phone attaches") }
		let slowLine = line(frames: 8, id: "slow")
		let began = Date()
		for message in try! honest.channel!.seal(line: slowLine) {
			honest.send(message)
			usleep(100_000)
		}
		Check.expect(engine.sessionLine(within: 10)?.1 == carried(slowLine, session: "u_honest") && !honest.closed, "a phone sending a line slowly but steadily, a piece every tenth of a second, is not cut: the line reaches the engine whole", String(format: "in %.1f s", Date().timeIntervalSince(began)))

		// A stalled line, while phones are held back and after. Phones are held back by a line of 10 MiB the engine (this
		// check) does not read, all of it but its last frame sent before the stalled line begins, so that the stalled
		// line's clock runs as little as can be before they are; the stall is a minute until they are, on a loaded Mac.
		queue.sync { remote.lineStalledAfter = .seconds(60) }
		guard let stalled = attach(3, "u_stalled") else { return Check.expect(false, "a second phone attaches") }
		let flood = line(frames: 160, id: "flood")
		let floodMessages = try! honest.channel!.seal(line: flood)
		for message in floodMessages.dropLast() { honest.send(message) }
		let stalledMessages = try! stalled.channel!.seal(line: line(frames: 16, id: "stalled"))
		for message in stalledMessages.dropLast() { stalled.send(message) }
		Check.expect(until { $0.linesHeld == 176 * frame }, "a phone sends 16 frames of a line and stops: pi² Remote holds them, and 160 of another's")
		honest.send(floodMessages.last!)
		Check.expect(until { $0.phonesPaused }, "the other's line of 10 MiB, finished, the engine does not read: every attached phone is held back")
		queue.sync { remote.lineStalledAfter = .seconds(1.5) }
		Check.expect(stalled.message(within: 2) == nil && !stalled.closed && queue.sync(execute: { remote.linesHeld }) == 16 * frame, "while phones are held back, the stalled line's clock stands still: 2 seconds on, it is held and its connection open")
		Check.expect(engine.sessionLine(within: 30)?.1 == carried(flood, session: "u_honest"), "the engine reads the 10 MiB line")
		let drained = Date()
		Check.expect(until { !$0.phonesPaused }, "and phones are read again")
		Check.expect(stalled.event(within: 5) == .bye && stalled.closesWithin(2), "then, with nothing more of it for 1.5 seconds, the stalled line's connection is ended", String(format: "%.1f s after", Date().timeIntervalSince(drained)))
		Check.expect(Flows.logged("nothing more of a line from device \(devices[3].0) came for 1.5 seconds; its connection closed (said at most once a minute)"), "remote.log says so, by the device and the limit, nothing of the line")
		Check.expect(until { $0.linesHeld == 0 } && !attachedSession("u_stalled") && queue.sync(execute: { remote.sessions["u_stalled"] != nil }), "pi² Remote holds none of it, and the session waits for a resume")
		for session in ["u_honest", "u_stalled"] { engine.event("sessionClosed", [("session", .string(session)), ("why", .string("check"))]) }
		Check.expect(honest.event(within: 5) == .bye, "(the engine closes those sessions)")

		// The budget, with the stall's clock out of the way: two connections of one device, each holding most of a line.
		queue.sync {
			remote.lineStalledAfter = .seconds(60)
			remote.lineBudget = 3 * 1024 * 1024
		}
		guard let first = attach(0, "u_a1"), let second = attach(0, "u_a2") else { return Check.expect(false, "a device attaches two connections") }
		let firstMessages = try! first.channel!.seal(line: line(frames: 40, id: "a1"))
		let secondLine = line(frames: 40, id: "a2")
		let secondMessages = try! second.channel!.seal(line: secondLine)
		for message in firstMessages.prefix(30) { first.send(message) }
		for message in secondMessages.prefix(15) { second.send(message) }
		Check.expect(until { $0.linesHeld == 45 * frame } && !first.closed && !second.closed, "a device's two connections hold 30 and 15 frames of a line, within the budget of 3 MiB: both kept")
		for message in secondMessages[15 ..< 19] { second.send(message) }
		Check.expect(first.event(within: 5) == .bye && first.closesWithin(2), "the second's 19th frame passes the budget: the connection holding the most, the first, is ended")
		Check.expect(until { $0.linesHeld == 19 * frame } && attachedSession("u_a2") && !attachedSession("u_a1"), "the second is kept, and the first's session waits for a resume")
		Check.expect(Flows.logged("phones' unfinished lines held more than 3 MiB in all; the connection holding the most, of device \(devices[0].0), is closed (said at most once a minute)"), "remote.log says so")
		for message in secondMessages.dropFirst(19) { second.send(message) }
		Check.expect(engine.sessionLine(within: 10)?.1 == carried(secondLine, session: "u_a2"), "and the second's line reaches the engine whole")

		// Five devices, two connections each, each holding part of a line: never more than the budget held in all.
		queue.sync { remote.lineBudget = 8 * 1024 * 1024 }
		var phones: [(Phone, String)] = [(second, "u_a2")]
		for index in 1 ..< 10 {
			let session = "u_b\(index)"
			guard let phone = attach(index / 2, session) else { return Check.expect(false, "phone \(index) of five devices attaches") }
			phones.append((phone, session))
		}
		// Phone i holds 12 + i frames, one frame at a time, each held before the next is sent. Whenever more than the 128
		// frames of 8 MiB are held, the connection holding the most goes: at phone 8's fifth frame, phone 7 (19 frames);
		// at phone 9's fourth, phone 8 (20). What pi² Remote holds is compared with that after every frame.
		var model = [Int](repeating: 0, count: phones.count)
		var ended: [Int] = []
		var agreed = true
		sending: for (index, (phone, _)) in phones.enumerated() {
			let messages = try! phone.channel!.seal(line: line(frames: 40, id: "b\(index)"))
			for message in messages.prefix(12 + index) {
				phone.send(message)
				model[index] += 1
				if model.reduce(0, +) * frame > 8 * 1024 * 1024, let largest = model.indices.max(by: { model[$0] < model[$1] }) {
					model[largest] = 0
					ended.append(largest)
				}
				let expected = model.reduce(0, +) * frame
				guard until(within: 5, { $0.linesHeld == expected }) else {
					agreed = false
					break sending
				}
			}
		}
		Check.expect(agreed && ended == [7, 8], "ten connections of five devices, each holding part of a line: after every frame, pi² Remote holds no more than the budget, ending the connection holding the most each time it is passed", "\(queue.sync { remote.linesHeld } / frame) frames held")
		let kept = { (remote: Remote) in phones.filter { remote.sessions[$0.1]?.isAttached == true }.map(\.1) }
		Check.expect(until { kept($0).count == 8 } && phones[7].0.event(within: 5) == .bye && phones[8].0.event(within: 5) == .bye, "phones 7 and 8, each the one holding the most when the budget was passed, are ended; the other eight kept", "\(queue.sync { kept(remote) })")
	}
}
