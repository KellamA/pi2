import CryptoKit
import Darwin
import Foundation
import RemoteKit
import pi2_remote

/// The "done when" of #675: a test client attaches over loopback, through a real engine. The engine (engine/src/main.ts,
/// a development engine) runs on a temporary data folder with test switches of its own (App Attest's stand-in), its
/// app bundle a stand-in holding the pi² Remote this check was built with, as build.sh puts it in the app. This check
/// is the app (a stand-in pi2-peer takes its connection for the app's) and the phone (RemoteKit, over TCP to
/// 127.0.0.1). Nothing of the installed pi² is touched: no data folder but the temporary one, a Keychain service of the
/// check's own, and pi² Remote in loopback mode.
enum RealEngine {
	static let team = "ABCDE12345"

	/// The engine's socket, as the app talks to it.
	final class App {
		let lines: LineReader
		private var next = 1

		init?(socket path: String) {
			guard path.utf8.count < 104 else { return nil }
			let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
			var address = sockaddr_un()
			address.sun_family = sa_family_t(AF_UNIX)
			withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
			let done = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
			guard done == 0 else {
				close(descriptor)
				return nil
			}
			lines = LineReader(descriptor: descriptor)
		}

		/// A request and its answer: the result, or the engine's error as a failure.
		func call(_ method: String, _ params: JSONValue = .object([]), within seconds: Double = 120) -> Result<JSONValue, Refused> {
			let id = next
			next += 1
			lines.write(JSON.write(.object([("id", .integer(Int64(id))), ("method", .string(method)), ("params", params)])))
			let deadline = Date().addingTimeInterval(seconds)
			while let line = lines.next(within: max(0, deadline.timeIntervalSinceNow)) {
				guard let value = try? JSON.parse(line), value["id"]?.integerValue == Int64(id) else { continue }
				if let error = value["error"] { return .failure(Refused(error.stringValue ?? JSON.text(error))) }
				return .success(value["result"] ?? .null)
			}
			return .failure(Refused("no answer to \(method)"))
		}
	}

	static func findNode() -> String? {
		// As Strings: `split(…) + ["…"]` alone is taken as arrays of characters, which name no folder, so only the two
		// fallbacks were ever tried, whatever node the PATH named.
		for folder in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
			let candidate = "\(folder)/node"
			if access(candidate, X_OK) == 0 { return candidate }
		}
		return nil
	}

	static func children(of pid: pid_t) -> [(pid: pid_t, command: String)] {
		let output = Pipe()
		let ps = Process()
		ps.executableURL = URL(fileURLWithPath: "/bin/ps")
		ps.arguments = ["-axww", "-o", "pid=,ppid=,command="]
		ps.standardOutput = output
		ps.environment = ["LC_ALL": "en_US.UTF-8"]
		try? ps.run()
		let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		ps.waitUntilExit()
		return text.split(separator: "\n").compactMap { row in
			let parts = row.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard parts.count == 3, let child = pid_t(parts[0]), pid_t(parts[1]) == pid else { return nil }
			return (child, String(parts[2]))
		}
	}

	/// What `pid` listens on, by lsof: every TCP listener and every UDP socket it has.
	static func sockets(of pid: pid_t) -> [String] {
		let output = Pipe()
		let lsof = Process()
		lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
		lsof.arguments = ["-a", "-p", String(pid), "-i", "-n", "-P", "-F", "tn"]
		lsof.standardOutput = output
		lsof.standardError = FileHandle.nullDevice
		try? lsof.run()
		let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		lsof.waitUntilExit()
		return text.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
	}

	static func run(engineMain: String, helper: URL, root: URL) {
		Check.section("through a real engine: a phone pairs and attaches over loopback (#675's done when)")
		guard let node = findNode() else { return Check.expect(false, "a node to run the engine with is on the PATH") }
		let home = root.appendingPathComponent("e", isDirectory: true)
		try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let bundle = root.appendingPathComponent("pi2 engine check.app", isDirectory: true)
		let helpers = bundle.appendingPathComponent("Contents/Helpers/pi² Remote.app/Contents/MacOS", isDirectory: true)
		try! FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
		try! FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
		try! FileManager.default.copyItem(at: helper, to: helpers.appendingPathComponent("pi² Remote"))
		let peer = bundle.appendingPathComponent("Contents/MacOS/pi2-peer")
		try! "#!/bin/sh\necho '{\"app\":true,\"why\":\"a stand-in takes every connection for the app'\"'\"'s\"}'\n".write(to: peer, atomically: true, encoding: .utf8)
		chmod(peer.path, 0o755)
		let awake = root.appendingPathComponent("awake.sh")
		try! "#!/bin/sh\nwhile kill -0 \"$3\" 2>/dev/null; do sleep 1; done\n".write(to: awake, atomically: true, encoding: .utf8)
		chmod(awake.path, 0o755)
		let environment = [
			"PATH": "\(URL(fileURLWithPath: node).deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
			"HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
			"PI2_HOME": home.path,
			"PI2_KEYCHAIN_SERVICE": "dev.pi2.credentials.test-675-check",
			"PI2_APP_BUNDLE": bundle.path,
			"PI2_APP_ATTEST_STAND_IN": "1",
			"PI2_APP_ATTEST_TEAM": team,
			"PI2_AWAKE_PROGRAM": awake.path,
			"PI2_AWAKE_POWER": "ac",
		]
		let engine = Child.spawn(node, [engineMain], environment: environment)
		defer { engine.stop() }
		let socketPath = home.appendingPathComponent("engine.sock").path
		var app: App?
		let started = Date()
		while app == nil, Date().timeIntervalSince(started) < 240, engine.running {
			if FileManager.default.fileExists(atPath: socketPath) { app = App(socket: socketPath) }
			if app == nil { usleep(200_000) }
		}
		guard let app else { return Check.expect(false, "the engine started and listened", engine.stderrText) }
		Check.expect(true, "the engine started on a temporary data folder")

		guard case .success = app.call("devices.set", .object([("on", .bool(true)), ("preview", .bool(true)), ("relayAddress", .string("ws://127.0.0.1:9/v1"))])) else {
			return Check.expect(false, "remote access turned on")
		}
		let opened = app.call("devices.pairStart", within: 180)
		guard case let .success(window) = opened, let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text) else {
			return Check.expect(false, "the engine opened a pairing through pi² Remote", "\(opened); \(engine.stderrText.suffix(2000))")
		}
		let remote = children(of: engine.pid).first { $0.command.contains("pi² Remote") }
		Check.expect(remote != nil, "pi² Remote is the engine's own child, from the app's bundle", children(of: engine.pid).map(\.command).joined(separator: "; "))
		Check.expect(payload.addresses.count == 1 && payload.addresses[0].hasPrefix("127.0.0.1:"), "the payload names the home path on 127.0.0.1 alone", payload.addresses.joined(separator: ","))
		if let remote {
			let open = sockets(of: remote.pid)
			Check.expect(!open.isEmpty && open.allSatisfy { $0.hasPrefix("127.0.0.1:") }, "pi² Remote has no socket on any address but 127.0.0.1", open.joined(separator: ", "))
		}
		let keyFile = home.appendingPathComponent("remote-keys.json")
		Check.expect(FileManager.default.fileExists(atPath: keyFile.path), "its keys are in a file in the engine's temporary data folder")
		Check.expect(PublicKeys.text(payload.identityKey).isEmpty == false && payload.relay == "ws://127.0.0.1:9/v1", "the payload carries the Mac's identity key pi² Remote made")

		let address = payload.addresses[0]
		let port = UInt16(address.split(separator: ":").last!)!
		let keys = PhoneKeys()
		guard let phone = Phone(port: port), let paired = phone.pair(payload: payload, keys: keys, team: team) else {
			return Check.expect(false, "the phone's pairing handshake on the home path")
		}
		let digits = PairingSecrets.digits(secret: payload.secret, binding: paired.binding)
		var confirmed: Result<JSONValue, Refused> = .failure(Refused("not tried"))
		let confirmStart = Date()
		repeat {
			confirmed = app.call("devices.pairConfirm", .object([("digits", .string(digits))]))
			if case let .failure(why) = confirmed, why.description.contains("No phone is waiting") { usleep(200_000) } else { break }
		} while Date().timeIntervalSince(confirmStart) < 60
		guard case let .success(confirmation) = confirmed, let deviceText = confirmation["device"]?.stringValue, let device = DeviceID(deviceText) else {
			return Check.expect(false, "the digits the phone shows pair it on the Mac", "\(confirmed)")
		}
		guard let line = phone.line(), case let .paired(answer)? = try? ControlLine.parse(line) else { return Check.expect(false, "the phone is told it is paired") }
		Check.expect(answer.device == device && answer.pairing == payload.pairing, "the phone is told it is paired, with its device id")
		Check.expect(phone.event() == .bye, "then the pairing channel ends")

		guard let connected = Phone(port: port), let challenge = connected.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey),
		      let attached = connected.attach(pairing: payload.pairing, device: device, keys: keys, challenge: challenge)
		else { return Check.expect(false, "the phone attaches over loopback") }
		Check.expect(!attached.resume, "the phone attached in a new session of the engine's (\(attached.session))")
		var greeting: [JSONValue] = []
		while let line = connected.line(within: 60), let value = try? JSON.parse(line) {
			greeting.append(value)
			if value["event"]?.stringValue == "device" { break }
		}
		Check.expect(greeting.last?["event"]?.stringValue == "device" && greeting.last?["id"]?.stringValue == device.text, "it is greeted as the app is, then sent its device event", "\(greeting.count) lines")
		Check.expect(!greeting.contains { ["devices", "auth", "computer", "browser", "remote"].contains($0["event"]?.stringValue ?? "") }, "with none of the events kept from a phone")

		func ask(_ phone: Phone, _ id: String, _ method: String, _ params: String = "{}") -> JSONValue? {
			phone.sendLine(Data("{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":\(params)}".utf8))
			while let line = phone.line(within: 60) {
				if let value = try? JSON.parse(line), value["id"]?.stringValue == id { return value }
			}
			return nil
		}
		let info = ask(connected, "p1", "engine.info")
		Check.expect(info?["result"]?["pid"]?.integerValue == Int64(engine.pid) && info?["result"]?["main"] == nil, "the phone asks the engine, and is answered as a device", info.map(JSON.text) ?? "none")
		let refused = ask(connected, "p2", "variables.set", #"{"name":"X","value":"y"}"#)
		Check.expect(refused?["error"] != nil, "a request kept to the Mac is refused by the engine", refused.map(JSON.text) ?? "none")

		connected.sendAck(connected.received)
		usleep(500_000)
		let had = connected.received
		connected.end()
		usleep(500_000)
		guard let back = Phone(port: port), let again = back.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey),
		      let resumed = back.attach(pairing: payload.pairing, device: device, keys: keys, challenge: again, session: attached.session, received: had)
		else { return Check.expect(false, "the phone resumes on a new channel") }
		Check.expect(resumed.resume && resumed.session == attached.session, "the phone resumes its session on a new channel, signed again", "\(resumed)")
		let afterResume = ask(back, "p3", "engine.info")
		Check.expect(afterResume?["result"] != nil, "and goes on asking, with no new greeting")

		guard case .success = app.call("devices.revoke", .object([("device", .string(device.text))])) else { return Check.expect(false, "the device is revoked on the Mac") }
		var told = false
		while let event = back.event(within: 30) {
			if case let .line(line) = event, case let .revoked(revocation)? = try? ControlLine.parse(line) {
				told = (try? revocation.verify(identityKey: payload.identityKey, pairing: payload.pairing, device: device)) != nil
			}
			if event == .bye { break }
		}
		Check.expect(told, "a device revoked on the Mac is told so by pi² Remote, signed by the Mac's identity key, and its channel ends")

		// A claimer that proves the secret and sends no claim: pi² Remote's `remote.pairRefused`, which the engine takes and
		// closes the window on (#776's 28).
		if case let .success(again) = app.call("devices.pairStart", within: 180), let text = again["payload"]?.stringValue, let second = try? PairingPayload.parse(text),
		   let claimer = Phone(port: port) {
			let handshake = try! ChannelHandshake.pairingInitiator(payload: second, channelKey: PhoneKeys().channel)
			claimer.send(try! handshake.writeMessage())
			if let answer = claimer.message(), (try? handshake.readMessage(answer)) != nil, let channel = try? handshake.channel() {
				claimer.channel = channel
				_ = claimer.line()
				claimer.sendLine(Data(#"{"hello":1}"#.utf8))
				_ = claimer.closesWithin(10)
			}
			var closedWhy = ""
			for _ in 0 ..< 100 where closedWhy.isEmpty {
				if case let .success(state) = app.call("devices.watch"), state["pairingWindow"]?.isNull == true { closedWhy = state["closed"]?["why"]?.stringValue ?? "closed" }
				if closedWhy.isEmpty { usleep(100_000) }
			}
			Check.expect(closedWhy.contains("refused") && closedWhy.contains("not a claim to pair"), "the engine takes remote.pairRefused not-pair and closes the window", closedWhy)
		} else {
			Check.expect(false, "a second pairing window opened")
		}

		let log = (try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
		Check.expect(log.contains("a development build") && !log.contains(Base64URL.encode(payload.secret)) && !log.contains(digits), "pi² Remote's log holds neither the pairing's secret nor the digits", log)

		guard case .success = app.call("devices.set", .object([("on", .bool(false))])) else { return Check.expect(false, "remote access turned off") }
		if let remote {
			var gone = false
			for _ in 0 ..< 300 where !gone {
				gone = kill(remote.pid, 0) != 0
				if !gone { usleep(100_000) }
			}
			Check.expect(gone, "with remote access off, the engine stops pi² Remote")
		}
	}
}
