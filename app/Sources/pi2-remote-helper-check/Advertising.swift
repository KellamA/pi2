import CryptoKit
import Darwin
import Dispatch
import Foundation
import RemoteKit
import pi2_remote

/// The home tag as pi² Remote would advertise it, across revocations, failed writes and restarts (#845; #675's security
/// read, S1 and S3). A development build advertises nothing, so this runs pi² Remote in this process, on the release
/// build's vault with the stand-in Keychain (which can refuse writes) and an advertiser that records what it is asked
/// to advertise. A "restart" is a new pi² Remote on the same stand-in Keychain; the one before is dropped as it is,
/// with nothing written after its last step, as a crash leaves it.
enum Advertising {
	/// Records every tag it is asked to advertise, and what is advertised now.
	final class Recorder: Advertiser, @unchecked Sendable {
		private let lock = NSLock()
		private var all: [String] = []
		private var now: String?

		func advertise(port: UInt16, txt: Data) {
			let text = String(decoding: txt, as: UTF8.self)
			let tag = text.range(of: "t=").map { String(text[$0.upperBound...]) } ?? "?"
			lock.withLock {
				all.append(tag)
				now = tag
			}
		}

		func stop() { lock.withLock { now = nil } }

		var tags: [String] { lock.withLock { all } }
		var current: String? { lock.withLock { now } }
	}

	/// A pi² Remote in this process, its check-side engine, and what it advertises.
	struct Running {
		let remote: Remote
		let engine: FakeEngine
		let recorder: Recorder

		/// Waits for pi² Remote's queue to have done what `condition` waits for.
		func until(_ condition: @escaping (Remote) -> Bool, within seconds: Double = 10) -> Bool {
			let deadline = Date().addingTimeInterval(seconds)
			while Date() < deadline {
				if remote.queue.sync(execute: { condition(remote) }) { return true }
				usleep(10000)
			}
			return false
		}

		var homeKey: HomeKey? { remote.queue.sync { remote.homeKey } }
		var devices: [String] { remote.queue.sync { remote.devices.map(\.id.text) } }
	}

	/// Kept for the rest of the check: a pi² Remote's queue and listener hold it unowned.
	nonisolated(unsafe) static var keptAlive: [Running] = []

	static let pairing = PairingID.random()

	static func tag(_ key: HomeKey?) -> String? { key.map { HomeTag.tag(key: $0, pairing: pairing, date: Date()) } }

	/// Starts pi² Remote on `items`, with `devices` as the engine's start lists them.
	static func start(_ items: Units.MemoryItems, devices: [DeviceID]) -> Running? {
		let vault = KeychainVault(items: items, enclave: Units.StandInEnclave(available: false))
		let queue = DispatchQueue(label: "check-remote")
		let (mine, theirs) = socketPair()
		let link = EngineLink(io: SocketIO(descriptor: theirs, queue: queue))
		let recorder = Recorder()
		guard let keys = try? vault.macKeys(), let remote = try? Remote(kind: .development, keys: keys, vault: vault, engine: link, queue: queue, advertiser: recorder) else { return nil }
		let running = Running(remote: remote, engine: FakeEngine(descriptor: mine), recorder: recorder)
		keptAlive.append(running)
		let start = JSONValue.object([
			("event", .string("remote")), ("kind", .string("start")), ("relay", .string("ws://127.0.0.1:9/v1")), ("switches", Flows.switches),
			("pairing", .string(pairing.text)), ("devices", .array(devices.map { .object([("id", .string($0.text))]) })), ("minimumBuild", .string("1")),
		])
		queue.sync {
			remote.begin(start)
			link.start()
		}
		guard let hello = running.engine.request("remote.hello") else { return nil }
		running.engine.answer(hello.id)
		return running
	}

	static func paired(_ running: Running, _ device: DeviceID) {
		running.engine.event("paired", [("device", PhoneKeys().paired(id: device))])
	}

	static func run() {
		Check.section("the home tag across revocations, failed writes and restarts, as a release build would advertise it (#845; S1, S3)")
		let logs = temporaryFolder("p2ra")
		defer { try? FileManager.default.removeItem(at: logs) }
		Log.shared.open(folder: logs)
		let items = Units.MemoryItems()
		func stored() -> KeptDevices? { items.items["devices"].flatMap { try? KeptDevices(data: $0) } }

		guard let first = start(items, devices: []) else { return Check.expect(false, "pi² Remote starts in this process") }
		Check.expect(first.recorder.tags.isEmpty, "before the first pairing, nothing is advertised")
		let x = DeviceID.random(), y = DeviceID.random()
		paired(first, x)
		paired(first, y)
		guard first.until({ $0.devices.count == 2 && $0.homeKey != nil }) else { return Check.expect(false, "two devices are paired") }
		let old = first.homeKey
		Check.expect(stored()?.homeKey == old && stored()?.devices.count == 2, "the home key is kept with the two devices")
		Check.expect(first.recorder.current == tag(old), "and its tag is advertised")

		// S1: the write of a revocation fails.
		items.refuseWrites = true
		first.engine.event("revoke", [("device", .string(x.text))])
		Check.expect(first.until { $0.devices.map(\.id) == [y] }, "a revocation whose write fails still drops the device at once")
		Check.expect(first.homeKey == nil && first.recorder.current == nil, "and stops advertising: the old key's tag is gone and none is put up")
		Check.expect(stored()?.homeKey == old && Set(stored()?.devices.map(\.id.text) ?? []) == [x.text, y.text], "on disk, the list and the key are as they were, together: the revoked device is still beside the key it holds")

		// A restart with the Keychain still refusing: nothing is advertised at all.
		guard let refused = start(items, devices: [y]) else { return Check.expect(false, "pi² Remote starts again") }
		Check.expect(refused.devices == [y.text] && refused.homeKey == nil, "the next start drops the revoked device, and with no new key kept, takes none")
		Check.expect(refused.recorder.tags.isEmpty, "and advertises nothing, never the old tag")

		// A restart once the Keychain takes writes again: a new key before anything is advertised.
		items.refuseWrites = false
		guard let second = start(items, devices: [y]) else { return Check.expect(false, "pi² Remote starts once more") }
		let renewed = second.homeKey
		Check.expect(renewed != nil && renewed != old && stored()?.homeKey == renewed && stored()?.devices.map(\.id) == [y], "the next start that can write keeps a new home key with the list")
		Check.expect(second.recorder.tags == [tag(renewed)!] && !second.recorder.tags.contains(tag(old)!), "and advertises its tag alone: the old tag never goes up again", second.recorder.tags.joined(separator: " "))

		// A crash right after a revocation's write: the new key is on disk with the list, and is the one advertised.
		let z = DeviceID.random()
		paired(second, z)
		guard second.until({ $0.devices.count == 2 }) else { return Check.expect(false, "a third device is paired") }
		second.engine.event("revoke", [("device", .string(z.text))])
		Check.expect(second.until { $0.devices.count == 1 && $0.homeKey != nil && $0.homeKey != renewed }, "a revocation that can write makes a new key at once")
		let afterRevoke = second.homeKey
		Check.expect(second.recorder.current == tag(afterRevoke), "and advertises its tag in place of the one before")
		guard let third = start(items, devices: [y]) else { return Check.expect(false, "pi² Remote starts after a crash") }
		Check.expect(third.homeKey == afterRevoke && third.recorder.tags == [tag(afterRevoke)!] && !third.recorder.tags.contains(tag(renewed)!), "a start after a crash that followed the revocation's write advertises the key written with it, never the revoked phone's")

		// S3: the last device revoked.
		third.engine.event("revoke", [("device", .string(y.text))])
		Check.expect(third.until { $0.devices.isEmpty && $0.homeKey == nil }, "after the last device is revoked, pi² Remote keeps no home key")
		Check.expect(third.recorder.current == nil && stored().map { $0.devices.isEmpty && $0.homeKey == nil } == true, "advertises nothing, and keeps no key no device holds")
		let w = DeviceID.random()
		paired(third, w)
		Check.expect(third.until { $0.devices.count == 1 && $0.homeKey != nil }, "the next first pairing makes a key")
		let fresh = third.homeKey
		Check.expect(fresh != afterRevoke && fresh != renewed && fresh != old && third.recorder.current == tag(fresh), "a new one, advertised once a device holds it")
	}
}
