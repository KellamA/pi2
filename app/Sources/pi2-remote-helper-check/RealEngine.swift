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

		/// Runs `body` while another thread reads and drops what the engine sends this connection, as the app reads all it
		/// is sent, so that the check sees the engine as it runs beside pi². Not read, the connection's buffer fills, and
		/// the engine keeps in memory all it owes the app until it is read: some 140 MB in the long-line steps, where the
		/// engine tells the app of a phone's text of 64 MiB and more. The engine no longer waits on an app that does not
		/// read (#927, engine/test/appstall.ts). No `call` within `body`.
		func drained(_ body: () -> Void) {
			final class Stop: @unchecked Sendable {
				let lock = NSLock()
				var asked = false
				var done = false
				var isAsked: Bool { lock.withLock { asked } }
			}
			let stop = Stop()
			let descriptor = lines.descriptor
			Thread {
				var buffer = [UInt8](repeating: 0, count: 65536)
				while !stop.isAsked {
					if readable(descriptor, within: 0.1), read(descriptor, &buffer, buffer.count) <= 0 { break }
				}
				stop.lock.withLock { stop.done = true }
			}.start()
			defer {
				stop.lock.withLock { stop.asked = true }
				while !stop.lock.withLock({ stop.done }) { usleep(20_000) }
			}
			body()
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
		// Each folder as text: an array literal added to the split's result once made it an array of characters' arrays,
		// so that PATH was never searched and only the two folders after it were.
		let folders: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
		for folder in folders {
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

	/// Every line `phone` gets until the answer to `id`, each parsed whole: nil for one that is not.
	static func until(_ id: String, on phone: Phone, within seconds: Double = 240) -> (answer: JSONValue?, lines: [JSONValue?]) {
		var lines: [JSONValue?] = []
		let deadline = Date().addingTimeInterval(seconds)
		while let line = phone.line(within: max(0, deadline.timeIntervalSinceNow)) {
			let value = try? JSON.parse(line)
			if value?["id"]?.stringValue == id { return (value, lines) }
			lines.append(value)
		}
		return (nil, lines)
	}

	/// A demo conversation the Mac makes and `phone` opens, as the phone's app does (newest first); its id.
	static func opened(app: App, phone: Phone, ask: (Phone, String, String, String) -> JSONValue?) -> Int64? {
		guard case let .success(made) = app.call("conversation.create", .object([("model", .object([("provider", .string("demo")), ("modelId", .string("demo-1"))]))])), let id = made["id"]?.integerValue,
		      ask(phone, "open \(id)", "conversation.open", "{\"id\":\(id),\"newestFirst\":true}")?["result"] != nil
		else { return nil }
		return id
	}

	/// A message of `text` alone; the demo model answers `/work 0` with a line of its own, without quoting the text.
	static func submit(_ id: String, _ conversation: Int64, _ text: String) -> Data {
		Data("{\"id\":\"\(id)\",\"method\":\"submit\",\"params\":{\"id\":\(conversation),\"text\":\"\(text)\"}}".utf8)
	}

	/// The person's own text in a `conversation` event for `conversation`, if it carries one.
	static func userText(_ line: JSONValue?, _ conversation: Int64) -> String? {
		guard line?["event"]?.stringValue == "conversation", line?["id"]?.integerValue == conversation, case let .array(items)? = line?["items"] else { return nil }
		return items.first { $0["kind"]?.stringValue == "user" }?["text"]?.stringValue
	}

	/// The longest line the engine writes pi² Remote, and a phone takes from the Mac.
	static let lineToHelper = 64 * 1024 * 1024

	/// What the engine answers a phone for a message of more than 1 MB of typed text (#924, `typedRefusal` in answers.ts).
	static func tooLong(_ size: String) -> String {
		"A message from a phone can carry at most 1 MB of typed text; this one has \(size). Shorten it, or send it from the Mac."
	}

	/// `app.call` on a thread of its own while `body` reads a phone on this one, so that neither end waits on the other's
	/// reading: the engine's answer to the app and its lines to the phone go at once.
	static func callAside(_ app: App, _ method: String, _ params: JSONValue, while body: () -> Void) -> Result<JSONValue, Refused> {
		final class Aside: @unchecked Sendable {
			let app: App
			let params: JSONValue
			var result: Result<JSONValue, Refused> = .failure(Refused("not answered"))
			let done = DispatchSemaphore(value: 0)
			init(app: App, params: JSONValue) {
				self.app = app
				self.params = params
			}
		}
		let aside = Aside(app: app, params: params)
		Thread {
			aside.result = aside.app.call(method, aside.params, within: 600)
			aside.done.signal()
		}.start()
		body()
		aside.done.wait()
		return aside.result
	}

	/// A typed text over 64 MiB (#919), through the real engine and pi² Remote. From an attached phone the engine refuses
	/// it, in words the phone shows, since a phone's typed text is at most 1 MB (#924); from the Mac's own app it is taken,
	/// and its echo to the phone's session, which has the conversation open, would be longer than pi² Remote takes from
	/// the engine, and a phone from the Mac. The engine writes no such line: pi² Remote keeps running, the phone's session
	/// goes on with no cut line, and another device's session is untouched. The other device is given back, still
	/// attached, for `typedTextUnder`.
	static func typedTextOver(app: App, engine: Child, remote: (pid: pid_t, command: String)?, home: URL, phone: Phone, ask: (Phone, String, String, String) -> JSONValue?, pairAnother: () -> (Phone, String)?) -> (Phone, String)? {
		Check.section("a typed text over 64 MiB, through the real engine: refused from a phone, taken from the Mac (#919, #924)")
		guard let (other, otherSession) = pairAnother() else {
			Check.expect(false, "a second device paired and attached")
			return nil
		}
		Check.expect(true, "a second device paired and attached")
		guard let over = opened(app: app, phone: phone, ask: ask) else {
			Check.expect(false, "the phone opened a conversation")
			return nil
		}
		let overText = "/work 0 1000 " + String(repeating: "o", count: 65 * 1024 * 1024)
		var beforeOver: [JSONValue?] = []
		// The app reads what it is sent meanwhile, as pi² does.
		app.drained {
			let line = submit("o1", over, overText)
			Check.expect(line.count > lineToHelper && line.count <= Remote.phoneLineLimit, "the phone's line is over 64 MiB and under its 72 MiB", "\(line.count) bytes")
			phone.sendLine(line)
			let (overAnswer, lines) = until("o1", on: phone)
			beforeOver = lines
			Check.expect(overAnswer?["error"]?.stringValue == tooLong("65.0 MB"), "a typed text of 65 MiB from an attached phone is refused by the engine, in words the phone shows", overAnswer.map(JSON.text) ?? "no answer")
		}
		// The same text from the Mac's own app, while the phone reads what it is sent.
		var fromMac: [JSONValue?] = []
		let taken = callAside(app, "submit", .object([("id", .integer(over)), ("text", .string(overText))])) {
			phone.sendLine(Data(#"{"id":"o2","method":"engine.info","params":{}}"#.utf8))
			fromMac = until("o2", on: phone).lines
		}
		var tookIt = false
		if case .success = taken { tookIt = true }
		Check.expect(tookIt, "the same text from the Mac's own app is taken", "\(taken)")
		app.drained {
			phone.sendLine(Data(#"{"id":"o3","method":"engine.info","params":{}}"#.utf8))
			let (afterOver, rest) = until("o3", on: phone)
			let seen = beforeOver + fromMac + rest
			Check.expect(afterOver?["result"]?["pid"]?.integerValue == Int64(engine.pid), "the phone's session goes on: it asks, and is answered")
			Check.expect(!seen.contains { $0 == nil }, "every line the phone got was whole")
			Check.expect(!seen.contains { userText($0, over) != nil }, "and none was the text's echo: it is not sent")
			other.sendLine(Data(#"{"id":"x1","method":"engine.info","params":{}}"#.utf8))
			let (otherInfo, otherLines) = until("x1", on: other)
			Check.expect(otherInfo?["result"]?["pid"]?.integerValue == Int64(engine.pid) && !otherLines.contains { $0 == nil }, "another device's session is untouched: it asks and is answered, every line whole", "\(otherInfo.map(JSON.text) ?? "no answer"), \(otherLines.count) lines")
			let now = children(of: engine.pid).first { $0.command.contains("pi² Remote") }
			Check.expect(remote != nil && now?.pid == remote?.pid && kill(remote!.pid, 0) == 0, "pi² Remote is still running, the same process", "\(String(describing: remote?.pid)) then \(String(describing: now?.pid))")
			let log = (try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
			Check.expect(!log.contains("longer than"), "its log has no line from the engine too long")
			let said = engine.stderrText.split(separator: "\n").first { $0.contains("remote: a device's conversation event of") && $0.contains("was not written to pi² Remote, which takes lines of at most \(lineToHelper)") }
			Check.expect(said != nil && !engine.stderrText.contains("oooooooo"), "the engine's log says the event was not written, by its kind and size alone", said.map(String.init) ?? "")
		}
		return (other, otherSession)
	}

	/// A typed text whose echo is just under 64 MiB comes back to `phone` whole (#919): the echo's own fields measured on
	/// a short message first, the text filling the rest but for 4 KiB. Sent from the Mac's own app, since a phone's typed
	/// text is at most 1 MB (#924). On the second device, at the end, so that the steps before it read no line of tens of
	/// megabytes they do not expect.
	static func typedTextUnder(app: App, phone: Phone, session: String, ask: (Phone, String, String, String) -> JSONValue?) {
		Check.section("a typed text from the Mac just under 64 MiB, to a phone through the real engine (#919, #924)")
		guard let under = opened(app: app, phone: phone, ask: ask) else { return Check.expect(false, "the phone opened a conversation") }
		var measured: String?
		app.drained {
			let wrapping = "{\"session\":\"\(session)\",\"message\":}".utf8.count
			let short = "/work 0 1000 t"
			phone.sendLine(submit("u1", under, short))
			var shortAnswer: JSONValue?
			var shortEcho: Int?
			var answered = false
			while shortAnswer == nil || shortEcho == nil || !answered, let line = phone.line(within: 60) {
				let value = try? JSON.parse(line)
				if value?["id"]?.stringValue == "u1" { shortAnswer = value }
				if userText(value, under) == short { shortEcho = line.count }
				if value?["event"]?.stringValue == "conversation", JSON.text(value!).contains("Done: I ran it 0 times") { answered = true }
			}
			guard shortAnswer?["result"] != nil, let shortEcho, answered else {
				return Check.expect(false, "a short message is taken, echoed and answered", "\(shortAnswer.map(JSON.text) ?? "no answer"), echo \(shortEcho.map(String.init) ?? "none"), answered \(answered)")
			}
			let fields = shortEcho + wrapping - short.utf8.count
			measured = "/work 0 1000 " + String(repeating: "u", count: lineToHelper - fields - 4096 - 13)
		}
		guard let underText = measured else { return }
		var underEcho: JSONValue?
		let underAnswer = callAside(app, "submit", .object([("id", .integer(under)), ("text", .string(underText))])) {
			while underEcho == nil, let line = phone.line(within: 240) {
				if let value = try? JSON.parse(line), userText(value, under) != nil { underEcho = value }
			}
		}
		var tookIt = false
		if case .success = underAnswer { tookIt = true }
		Check.expect(tookIt && userText(underEcho, under) == underText, "a typed text from the Mac whose echo is just under 64 MiB (\(underText.utf8.count) bytes) comes back to the phone whole", "\(underAnswer)")
	}

	static func run(engineMain: String, helper: URL, root: URL) {
		Check.section("through a real engine: a phone pairs and attaches over loopback (#675's done when)")
		guard let (engine, app, home) = startEngine(engineMain: engineMain, helper: helper, root: root, name: "e") else { return }
		defer { engine.stop() }
		home675(engine: engine, app: app, home: home)
	}

	/// A development engine on a temporary data folder of its own, `root/<name>`, its app bundle a stand-in holding this
	/// check's pi² Remote; this check is its app.
	static func startEngine(engineMain: String, helper: URL, root: URL, name: String) -> (Child, App, URL)? {
		guard let node = findNode() else {
			Check.expect(false, "a node to run the engine with is on the PATH")
			return nil
		}
		let home = root.appendingPathComponent(name, isDirectory: true)
		try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let bundle = root.appendingPathComponent("pi2 engine check \(name).app", isDirectory: true)
		let helpers = bundle.appendingPathComponent("Contents/Helpers/pi² Remote.app/Contents/MacOS", isDirectory: true)
		try! FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
		try! FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
		try! FileManager.default.copyItem(at: helper, to: helpers.appendingPathComponent("pi² Remote"))
		helperInfo(helpers.appendingPathComponent("pi² Remote"))
		let peer = bundle.appendingPathComponent("Contents/MacOS/pi2-peer")
		try! "#!/bin/sh\necho '{\"app\":true,\"why\":\"a stand-in takes every connection for the app'\"'\"'s\"}'\n".write(to: peer, atomically: true, encoding: .utf8)
		chmod(peer.path, 0o755)
		let awake = root.appendingPathComponent("awake-\(name).sh")
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
		let socketPath = home.appendingPathComponent("engine.sock").path
		var app: App?
		let started = Date()
		while app == nil, Date().timeIntervalSince(started) < 240, engine.running {
			if FileManager.default.fileExists(atPath: socketPath) { app = App(socket: socketPath) }
			if app == nil { usleep(200_000) }
		}
		guard let app else {
			Check.expect(false, "the engine started and listened", engine.stderrText)
			engine.stop()
			return nil
		}
		Check.expect(true, "the engine started on a temporary data folder")
		return (engine, app, home)
	}

	static func home675(engine: Child, app: App, home: URL) {

		// The relay switch off: the home path alone, so that pi² Remote dials no relay at 127.0.0.1:9, where any process may
		// listen (#921's security read); it makes the pairing's id itself, and the payload still names the address.
		guard case .success = app.call("devices.set", .object([("on", .bool(true)), ("preview", .bool(true)), ("relay", .bool(false)), ("relayAddress", .string("ws://127.0.0.1:9/v1"))])) else {
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
		// What a message on the Mac may carry (#904): ten pictures of 5 MiB, through pi² Remote, taken by the engine.
		if case let .success(made) = app.call("conversation.create", .object([("model", .object([("provider", .string("demo")), ("modelId", .string("demo-1"))]))])),
		   let conversation = made["id"]?.integerValue {
			let pictures = Flows.tenPictures(conversation: Int(conversation), id: "p10")
			let sentAt = Date()
			connected.sendLine(pictures)
			var answered: JSONValue?
			while answered == nil, let line = connected.line(within: 120) {
				if let value = try? JSON.parse(line), value["id"]?.stringValue == "p10" { answered = value }
			}
			Check.expect(answered?["result"] != nil, "a phone's message of ten pictures of 5 MiB (\(pictures.count / 1024 / 1024) MiB) is taken by the engine", (answered.map(JSON.text) ?? "no answer") + String(format: ", in %.1f s", Date().timeIntervalSince(sentAt)))
		} else {
			Check.expect(false, "the Mac made a conversation for the phone's pictures")
		}
		let another = typedTextOver(app: app, engine: engine, remote: remote, home: home, phone: connected, ask: ask) {
			guard case let .success(window) = app.call("devices.pairStart", within: 180), let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text) else { return nil }
			let keys = PhoneKeys()
			guard let phone = Phone(port: port), let paired = phone.pair(payload: payload, keys: keys, team: team) else { return nil }
			var confirmed: Result<JSONValue, Refused> = .failure(Refused("not tried"))
			for _ in 0 ..< 300 {
				confirmed = app.call("devices.pairConfirm", .object([("digits", .string(PairingSecrets.digits(secret: payload.secret, binding: paired.binding)))]))
				if case let .failure(why) = confirmed, why.description.contains("No phone is waiting") { usleep(200_000) } else { break }
			}
			guard case let .success(confirmation) = confirmed, let id = confirmation["device"]?.stringValue, let device = DeviceID(id), phone.line() != nil, phone.event() == .bye,
			      let other = Phone(port: port), let challenge = other.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey),
			      let attached = other.attach(pairing: payload.pairing, device: device, keys: keys, challenge: challenge)
			else { return nil }
			while let line = other.line(within: 60), let value = try? JSON.parse(line), value["event"]?.stringValue != "device" {}
			return (other, attached.session.text)
		}

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

		// A claim waiting while the person cancels the pairing on the Mac: the engine's word for it reaches the phone (#881).
		if case let .success(again) = app.call("devices.pairStart", within: 180), let text = again["payload"]?.stringValue, let third = try? PairingPayload.parse(text),
		   let claimer = Phone(port: port), claimer.pair(payload: third, keys: PhoneKeys(), team: team) != nil {
			var waiting = false
			for _ in 0 ..< 100 where !waiting {
				if case let .success(state) = app.call("devices.watch"), state["pairingWindow"]?["claim"]?.isNull == false { waiting = true }
				if !waiting { usleep(100_000) }
			}
			Check.expect(waiting, "the third claim waits for the digits on the Mac")
			_ = app.call("devices.pairCancel")
			if let line = claimer.line(within: 30), case let .pairRefused(refusal)? = try? ControlLine.parse(line, from: .mac) {
				Check.expect(refusal.why == .cancelled && claimer.event() == .bye && claimer.homeKey == nil, "a claim the person cancels on the Mac is told pairRefused cancelled by pi² Remote, from the engine's word, then bye")
			} else {
				Check.expect(false, "a claim the person cancels on the Mac is told so")
			}
		} else {
			Check.expect(false, "a third pairing window opened and its claim was sent")
		}

		let log = (try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
		Check.expect(log.contains("a development build") && !log.contains(Base64URL.encode(payload.secret)) && !log.contains(digits), "pi² Remote's log holds neither the pairing's secret nor the digits", log)

		if let (other, session) = another { typedTextUnder(app: app, phone: other, session: session, ask: ask) }
		newFaceIDKey(app: app, home: home, port: port, ask: ask)
		offerRefusals(app: app, port: port)
		acceptedWhileAway(app: app, engine: engine, home: home, port: port)

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

	/// A new Face ID key through the real engine (#891), accepted on the Mac through the engine's own request, as the Mac's
	/// app does: a phone pairs and attaches; offers a new key on a channel, which the engine takes and answers waiting,
	/// which the phone is told as `refused` `presence`, with no session; an attach under the waiting key is refused
	/// `presence`; the person accepts it (`devices.acceptPresenceKey`), the engine tells pi² Remote and ends the session
	/// opened under the old key; the phone attaches under the new key and is answered; the same key offered again is
	/// answered `presenceKeyAccepted`. Five handshakes of a device paired for it, within its six a minute.
	/// A phone paired through the real engine, the digits it shows typed on the Mac.
	static func pairPhone(app: App, port: UInt16) -> (payload: PairingPayload, device: DeviceID, keys: PhoneKeys)? {
		guard case let .success(window) = app.call("devices.pairStart", within: 180), let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text) else { return nil }
		let keys = PhoneKeys()
		guard let pairing = Phone(port: port), let paired = pairing.pair(payload: payload, keys: keys, team: team) else { return nil }
		var confirmed: Result<JSONValue, Refused> = .failure(Refused("not tried"))
		for _ in 0 ..< 300 {
			confirmed = app.call("devices.pairConfirm", .object([("digits", .string(PairingSecrets.digits(secret: payload.secret, binding: paired.binding)))]))
			if case let .failure(why) = confirmed, why.description.contains("No phone is waiting") { usleep(200_000) } else { break }
		}
		guard case let .success(confirmation) = confirmed, let id = confirmation["device"]?.stringValue, let device = DeviceID(id), pairing.line() != nil, pairing.event() == .bye else { return nil }
		return (payload, device, keys)
	}

	/// Whether the last `offer(byeAlone: true)` was ended with `bye` alone.
	nonisolated(unsafe) static var lastByeAlone = false

	/// An offer of `key` by `device` on a new channel; the line the phone reads before `bye`. With `byeAlone`, a channel
	/// ended with `bye` and no line sets `lastByeAlone`.
	static func offer(_ key: P256.Signing.PrivateKey, port: UInt16, payload: PairingPayload, device: DeviceID, keys: PhoneKeys, at: Date = Date(), build: String? = nil, byeAlone: Bool = false) -> ControlLine? {
		lastByeAlone = false
		guard let phone = Phone(port: port), let challenge = phone.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey) else { return nil }
		let made = try! PresenceKeyOffer.make(
			pairing: payload.pairing, device: device, binding: phone.channel!.handshakeHash, challenge: challenge, build: build ?? keys.build, at: at, deviceKey: keys.device, offeredKey: key)
		phone.sendLine(ControlLine.presenceKey(made).line)
		if byeAlone {
			let first = phone.event(within: 10)
			if first == .bye {
				lastByeAlone = phone.closesWithin(10)
				return nil
			}
			guard case let .line(line)? = first else { return nil }
			return try? ControlLine.parse(line, from: .mac)
		}
		return Flows.lastLine(phone)
	}

	/// An attach by `device`, its presence signed by `presence`, on a new channel: `attached` (with the home key read
	/// after it), or `refused`, or nil for anything else.
	static func attachUnder(_ presence: P256.Signing.PrivateKey, port: UInt16, payload: PairingPayload, device: DeviceID, keys: PhoneKeys) -> ControlLine? {
		guard let phone = Phone(port: port), let challenge = phone.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey) else { return nil }
		let claim = try! AttachClaim.make(
			pairing: payload.pairing, device: device, session: nil, received: nil, binding: phone.channel!.handshakeHash, challenge: challenge, build: keys.build,
			deviceKey: keys.device, presenceKey: presence)
		phone.sendLine(ControlLine.attach(claim).line)
		guard case let .line(line)? = phone.event(within: 30), let read = try? ControlLine.parse(line, from: .mac) else { return nil }
		if case .attached = read { phone.readHomeKey() }
		phone.end()
		return read
	}

	/// Whether pi² Remote has said hello to the engine, as the Devices page has it.
	static func helperRunning(_ app: App) -> Bool? {
		guard case let .success(state) = app.call("devices.watch") else { return nil }
		return state["helper"]?["running"]?.boolValue
	}

	/// The port pi² Remote's home listener was last started on, by remote.log, and how many times it has been.
	static func listening(_ home: URL) -> (count: Int, port: UInt16?) {
		let lines = ((try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("listening on 127.0.0.1, port ") }
		return (lines.count, lines.last.flatMap { $0.split(separator: " ").last.flatMap { UInt16($0) } })
	}

	/// A new Face ID key the person accepts while pi² Remote is away (#891's security read): the engine's `presenceKey`
	/// event is lost, and pi² Remote takes the key from the engine's `start` when it is started again. First Reach from an
	/// iPhone turned off, the key accepted, Reach turned on again; then pi² Remote killed and the next key accepted before
	/// the engine starts it again (a second, by its restart's wait). Each time an attach under the new key gets a session,
	/// one under the old key none.
	static func acceptedWhileAway(app: App, engine: Child, home: URL, port: UInt16) {
		Check.section("a new Face ID key accepted while pi² Remote is away is on its list once it starts again (#891)")
		guard let (payload, device, keys) = pairPhone(app: app, port: port) else { return Check.expect(false, "a phone paired for the keys accepted while pi² Remote is away") }
		func until(_ what: String, _ condition: () -> Bool) -> Bool {
			for _ in 0 ..< 600 where !condition() { usleep(100_000) }
			let held = condition()
			if !held { Check.expect(false, what) }
			return held
		}
		func sessionUnder(_ key: P256.Signing.PrivateKey, port: UInt16, _ what: String) {
			let answer = attachUnder(key, port: port, payload: payload, device: device, keys: keys)
			if case .attached? = answer { Check.expect(true, what) } else { Check.expect(false, what, "\(String(describing: answer))") }
		}
		func noSessionUnder(_ key: P256.Signing.PrivateKey, port: UInt16, _ what: String) {
			let answer = attachUnder(key, port: port, payload: payload, device: device, keys: keys)
			if case let .refused(refusal)? = answer { Check.expect(refusal.reason == .presence, what) } else { Check.expect(false, what, "\(String(describing: answer))") }
		}

		// Reach off while the key waits; accepted; Reach on.
		let first = P256.Signing.PrivateKey()
		if case let .refused(refusal)? = offer(first, port: port, payload: payload, device: device, keys: keys) { Check.expect(refusal.reason == .presence, "the new key waits on the Mac") }
		let started = listening(home).count
		guard case .success = app.call("devices.set", .object([("on", .bool(false))])), until("pi² Remote stops with Reach off", { helperRunning(app) == false }) else { return }
		guard case .success = app.call("devices.acceptPresenceKey", .object([("device", .string(device.text))])) else { return Check.expect(false, "the key is accepted on the Mac while Reach is off") }
		guard case .success = app.call("devices.set", .object([("on", .bool(true)), ("preview", .bool(true)), ("relay", .bool(false)), ("relayAddress", .string("ws://127.0.0.1:9/v1"))])),
		      until("pi² Remote starts again with Reach on", { helperRunning(app) == true && listening(home).count > started }), let again = listening(home).port
		else { return }
		Check.expect(Flows.keptPresenceKey(home, device) == .some(first.publicKey.derRepresentation), "the key accepted while Reach was off is on pi² Remote's own list, from the engine's start")
		noSessionUnder(keys.presence, port: again, "an attach under the old key gets no session")
		sessionUnder(first, port: again, "after Reach on, an attach under the key accepted while it was off gets a session")

		// pi² Remote killed, the next key accepted before the engine starts it again.
		let second = P256.Signing.PrivateKey()
		if case let .refused(refusal)? = offer(second, port: again, payload: payload, device: device, keys: keys) { Check.expect(refusal.reason == .presence, "the next new key waits on the Mac") }
		guard let remote = children(of: engine.pid).first(where: { $0.command.contains("pi² Remote") }) else { return Check.expect(false, "pi² Remote runs") }
		let restarted = listening(home).count
		kill(remote.pid, SIGKILL)
		guard until("the engine sees pi² Remote gone", { helperRunning(app) == false }) else { return }
		guard case .success = app.call("devices.acceptPresenceKey", .object([("device", .string(device.text))])) else { return Check.expect(false, "the key is accepted on the Mac while pi² Remote is gone") }
		guard until("the engine starts pi² Remote again", { helperRunning(app) == true && listening(home).count > restarted }), let third = listening(home).port else { return }
		Check.expect(Flows.keptPresenceKey(home, device) == .some(second.publicKey.derRepresentation), "the key accepted while pi² Remote was gone is on its list, from the engine's start")
		noSessionUnder(first, port: third, "an attach under the key before it gets no session")
		noSessionUnder(keys.presence, port: third, "nor one under the first key")
		sessionUnder(second, port: third, "after the restart, an attach under the key accepted while pi² Remote was gone gets a session")
		if case .failure = app.call("devices.revoke", .object([("device", .string(device.text))])) { Check.expect(false, "the device is revoked at the end") }
	}

	/// The engine's refusals of an offer, through the real engine and pi² Remote, each told the phone by its reason in place
	/// of a bare `bye` (#891): a second key while one waits `presence`, a clock three minutes off `clock`, an offer from a
	/// suspended device `suspended`; and a build below the minimum `update`, which pi² Remote's own check of the minimum the
	/// engine gave it says first. A device paired for it, its fifth counted refusal suspending it; resumed and revoked at
	/// the end. It waits out one minute, so that its eighth handshake is within the six a minute pi² Remote takes.
	static func offerRefusals(app: App, port: UInt16) {
		Check.section("an offer's refusals through the real engine, each told the phone by its reason (#891)")
		guard let (payload, device, keys) = pairPhone(app: app, port: port) else { return Check.expect(false, "a phone paired for the offer's refusals") }
		func told(_ line: ControlLine?, _ reason: Refusal.Reason, _ what: String) {
			if case let .refused(refusal)? = line {
				Check.expect(refusal.reason == reason, "\(what) is told refused \(reason.rawValue), then bye", "\(String(describing: refusal.reason))")
			} else {
				Check.expect(false, "\(what) is told refused \(reason.rawValue)", "\(String(describing: line))")
			}
		}
		let first = P256.Signing.PrivateKey()
		told(offer(first, port: port, payload: payload, device: device, keys: keys), .presence, "a first new key, which the engine takes to wait,")
		// A second key while one waits: never `presence`, since the key that waits is not this phone's; `bye` alone.
		let second = offer(P256.Signing.PrivateKey(), port: port, payload: payload, device: device, keys: keys, byeAlone: true)
		Check.expect(second == nil && lastByeAlone, "a second key while one waits is told no reason: bye alone", "\(String(describing: second))")
		told(offer(first, port: port, payload: payload, device: device, keys: keys, build: "0"), .update, "a build below the minimum")
		for _ in 0 ..< 3 {
			told(offer(first, port: port, payload: payload, device: device, keys: keys, at: Date().addingTimeInterval(180)), .clock, "a clock three minutes ahead")
		}
		// Six handshakes so far; four refusals counted (the second key, three clocks). After a minute, a fifth suspends.
		sleep(61)
		told(offer(first, port: port, payload: payload, device: device, keys: keys, at: Date().addingTimeInterval(-180)), .clock, "a clock three minutes behind, the fifth counted refusal,")
		var suspended = false
		for _ in 0 ..< 100 where !suspended {
			if case let .success(state) = app.call("devices.watch"), case let .array(devices)? = state["devices"] {
				suspended = devices.first { $0["id"]?.stringValue == device.text }?["suspendedAt"]?.isNull == false
			}
			if !suspended { usleep(100_000) }
		}
		Check.expect(suspended, "five counted refusals of offers suspend the device")
		told(offer(first, port: port, payload: payload, device: device, keys: keys), .suspended, "an offer from a suspended device")
		_ = app.call("devices.resume", .object([("device", .string(device.text))]))
		if case .failure = app.call("devices.revoke", .object([("device", .string(device.text))])) { Check.expect(false, "the offer's device is revoked at the end") }
	}

	static func newFaceIDKey(app: App, home: URL, port: UInt16, ask: (Phone, String, String, String) -> JSONValue?) {
		Check.section("a new Face ID key through the real engine, accepted on the Mac (#891)")
		guard let (payload, device, keys) = pairPhone(app: app, port: port) else { return Check.expect(false, "the new key's phone pairs") }
		func connect() -> (Phone, Data)? {
			guard let phone = Phone(port: port), let challenge = phone.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey) else { return nil }
			return (phone, challenge)
		}
		guard let (first, challenge) = connect(), first.attach(pairing: payload.pairing, device: device, keys: keys, challenge: challenge) != nil else {
			return Check.expect(false, "the new key's phone attaches under its first key")
		}
		while let line = first.line(within: 60), let value = try? JSON.parse(line), value["event"]?.stringValue != "device" {}

		let newKey = P256.Signing.PrivateKey()
		func offer() -> ControlLine? {
			guard let (phone, challenge) = connect() else { return nil }
			let made = try! PresenceKeyOffer.make(
				pairing: payload.pairing, device: device, binding: phone.channel!.handshakeHash, challenge: challenge, build: keys.build, deviceKey: keys.device, offeredKey: newKey)
			phone.sendLine(ControlLine.presenceKey(made).line)
			return Flows.lastLine(phone)
		}
		func pending() -> String? {
			guard case let .success(state) = app.call("devices.watch"), case let .array(devices)? = state["devices"] else { return nil }
			return devices.first { $0["id"]?.stringValue == device.text }?["pendingPresenceKey"]?.stringValue
		}
		if case let .refused(refusal)? = offer() {
			Check.expect(refusal.reason == .presence, "the engine takes the offer through pi² Remote and answers it waiting, which the phone is told as refused presence, then bye")
		} else {
			Check.expect(false, "the offer is answered refused presence: the key waits on the Mac")
		}
		Check.expect(pending() == PublicKeys.text(newKey.publicKey), "the engine's record of the device holds the offered key as waiting, the key the phone wrote")
		Check.expect(Flows.keptPresenceKey(home, device) == .some(keys.presence.publicKey.derRepresentation), "and pi² Remote's own list still the old key")

		if let (early, challenge) = connect() {
			let claim = try! AttachClaim.make(
				pairing: payload.pairing, device: device, session: nil, received: nil, binding: early.channel!.handshakeHash, challenge: challenge, build: keys.build,
				deviceKey: keys.device, presenceKey: newKey)
			early.sendLine(ControlLine.attach(claim).line)
			if case let .refused(refusal)? = Flows.lastLine(early) {
				Check.expect(refusal.reason == .presence, "an attach under the waiting key is refused presence")
			} else {
				Check.expect(false, "an attach under the waiting key is refused presence")
			}
		}

		guard case .success = app.call("devices.acceptPresenceKey", .object([("device", .string(device.text))])) else { return Check.expect(false, "the person accepts the new key on the Mac") }
		var closed = false
		while !closed, let event = first.event(within: 30) { if event == .bye { closed = true } }
		Check.expect(closed, "accepting it ends the session opened under the old key")
		let listedBy = Date().addingTimeInterval(10)
		while Flows.keptPresenceKey(home, device) != .some(newKey.publicKey.derRepresentation), Date() < listedBy { usleep(20000) }
		Check.expect(Flows.keptPresenceKey(home, device) == .some(newKey.publicKey.derRepresentation), "pi² Remote takes the engine's presenceKey event: the new key is on its own list")

		var newKeys = keys
		newKeys.presence = newKey
		if let (again, challenge) = connect(), again.attach(pairing: payload.pairing, device: device, keys: newKeys, challenge: challenge) != nil {
			let info = ask(again, "fk1", "engine.info", "{}")
			Check.expect(info?["result"] != nil, "the phone attaches under the new key and is answered", info.map(JSON.text) ?? "no answer")
		} else {
			Check.expect(false, "the phone attaches under the new key once it was accepted")
		}
		if case .presenceKeyAccepted? = offer() {
			Check.expect(pending() == nil, "the key in use offered again is answered presenceKeyAccepted, then bye, and nothing waits")
		} else {
			Check.expect(false, "the key in use offered again is answered presenceKeyAccepted")
		}
		if case .failure = app.call("devices.revoke", .object([("device", .string(device.text))])) { Check.expect(false, "the new key's device is revoked at the end") }
	}

	/// The relay path through a real engine (#678): a phone pairs through the relay on this computer, with the digits it
	/// shows typed on the Mac, attaches over it, asks the engine, leaves a request in the Mac's mailbox that the engine
	/// checks and answers with a receipt, and is revoked; the Devices page is told what the relay path does.
	static func run(engineMain: String, helper: URL, root: URL, relay: URL) {
		Check.section("through a real engine and the relay on this computer: pairing, a session and the mailbox (#678)")
		guard let (engine, app, home) = startEngine(engineMain: engineMain, helper: helper, root: root, name: "er") else { return }
		defer { engine.stop() }
		guard case .success = app.call("devices.set", .object([("on", .bool(true)), ("preview", .bool(true)), ("relayAddress", .string(relay.absoluteString))])) else {
			return Check.expect(false, "remote access turned on, with the relay on this computer")
		}
		let opened = app.call("devices.pairStart", within: 180)
		guard case let .success(window) = opened, let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text) else {
			return Check.expect(false, "the engine opened a pairing through pi² Remote and the relay", "\(opened); \(engine.stderrText.suffix(2000))")
		}
		Check.expect(payload.relay == relay.absoluteString, "the payload names the relay")
		let registration = FileManager.default.contents(atPath: home.appendingPathComponent("remote-devices.json").path).flatMap { try? KeptDevices(data: $0) }?.registration
		Check.expect(registration?.pairing == payload.pairing, "and the pairing pi² Remote registered there, kept with its address")
		let keys = PhoneKeys()
		guard let link = Relayed.join(relay, pairing: payload.pairing, secret: payload.secret, keys: keys) else { return Check.expect(false, "the phone joins the relay's window") }
		let joined = RelayWire(link: link)
		let phone = Phone(relay: joined)
		guard let paired = phone.pair(payload: payload, keys: keys, team: team) else { return Check.expect(false, "the phone's pairing handshake over the relay") }
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
		guard let line = phone.line(), case let .paired(answer)? = try? ControlLine.parse(line) else { return Check.expect(false, "the phone is told it is paired over the relay") }
		Check.expect(answer.device == device, "the phone is told over the relay that it is paired, with its device id")
		joined.close()
		guard let wire = Relayed.connect(relay, pairing: payload.pairing, device: device, keys: keys) else {
			return Check.expect(false, "the phone connects to the relay as a listed device")
		}
		let connected = Phone(relay: wire)
		guard let challenge = connected.connect(pairing: payload.pairing, device: device, keys: keys, macChannel: payload.channelKey, identity: payload.identityKey),
		      let attached = connected.attach(pairing: payload.pairing, device: device, keys: keys, challenge: challenge)
		else { return Check.expect(false, "the phone attaches over the relay") }
		Check.expect(!attached.resume, "the phone attached over the relay in a new session (\(attached.session))")
		var greeting: [JSONValue] = []
		while let line = connected.line(within: 60), let value = try? JSON.parse(line) {
			greeting.append(value)
			if value["event"]?.stringValue == "device" { break }
		}
		Check.expect(greeting.last?["event"]?.stringValue == "device" && greeting.last?["relay"]?.boolValue == true, "it is greeted over the relay, then sent its device event", "\(greeting.count) lines")
		connected.sendLine(Data(#"{"id":"q1","method":"engine.info","params":{}}"#.utf8))
		var info: JSONValue?
		while let line = connected.line(within: 60) {
			if let value = try? JSON.parse(line), value["id"]?.stringValue == "q1" {
				info = value
				break
			}
		}
		Check.expect(info?["result"]?["pid"]?.integerValue == Int64(engine.pid), "and asks the engine over the relay", info.map(JSON.text) ?? "none")
		if case let .success(state) = app.call("devices.watch") {
			var sessions: [JSONValue] = []
			if case let .array(items)? = state["sessions"] { sessions = items }
			Check.expect(sessions.contains { $0["device"]?.stringValue == device.text && $0["path"]?.stringValue == "relay" }, "the Devices page shows the session on the relay path", JSON.text(state["sessions"] ?? .null))
			Check.expect(state["helper"]?["relay"]?["state"]?.stringValue == "ready", "and the relay path ready", JSON.text(state["helper"] ?? .null))
		}

		// The mailbox: a request the phone leaves while it holds no channel, which the engine checks and answers.
		guard let client = wire.client else { return }
		let id = ItemID.random()
		let request = try! RequestItem.make(method: "abort", params: .object([("id", .integer(987_654))]), pairing: payload.pairing, device: device, id: id, deviceKey: keys.device, presenceKey: keys.presence)
		let item = try! SealedItem.seal(request.plaintext, to: ItemAddress(pairing: payload.pairing, reader: .mac, id: id), readerKey: payload.recordKey, writerKey: keys.record)
		let put = blocking { try await client.put(item, id: id, to: .mac) }
		Check.expect((try? put.get()) == .stored, "the phone leaves a request in the Mac's mailbox")
		let pairing = payload.pairing, identity = payload.identityKey, macRecord = payload.recordKey, reader = keys.record
		var receipt: MacItem?
		for _ in 0 ..< 40 where receipt == nil {
			usleep(500_000)
			let taken = blocking { () async throws -> MacItem? in
				let found = Locked<MacItem?>(nil)
				_ = try await client.take { taken in
					var done = Set<ItemID>()
					for item in taken.items {
						if let opened = try? SealedItem.openMacItem(item.item, at: ItemAddress(pairing: pairing, reader: .device(device), id: item.id), readerKey: reader, writerRecordKey: macRecord, identityKey: identity) {
							found.set(opened)
							done.insert(item.id)
						}
					}
					return done
				}
				return found.get()
			}
			receipt = (try? taken.get()) ?? nil
		}
		Check.expect(receipt?.kind == "receipt" && receipt?.body["nonce"]?.stringValue == id.text && receipt?.body["outcome"]?.stringValue == "failed",
		             "the engine checked it again, handled it (an abort of no conversation fails) and left the phone a receipt, signed by the Mac and sealed for it", receipt.map { JSON.text($0.body) } ?? "none")

		guard case .success = app.call("devices.revoke", .object([("device", .string(device.text))])) else { return Check.expect(false, "the device is revoked on the Mac") }
		var told = false
		while let event = connected.event(within: 30) {
			if case let .line(line) = event, case let .revoked(revocation)? = try? ControlLine.parse(line) {
				told = (try? revocation.verify(identityKey: payload.identityKey, pairing: payload.pairing, device: device)) != nil
			}
			if event == .bye { break }
		}
		Check.expect(told, "a device revoked on the Mac is told so over the relay, and its channel ends")
		let removed = wire.ended(within: 15)
		Check.expect(removed?.contains("removed") == true, "and the relay removes its slot", removed ?? "still open")
		leave(app: app, relay: relay)
		guard case .success = app.call("devices.set", .object([("on", .bool(false))])) else { return Check.expect(false, "remote access turned off") }
	}

	/// A phone unpaired on the phone (#929): another phone pairs through the relay and sends `leave`, whose notice the relay
	/// passes on to pi² Remote, which verifies it against its own list and tells the engine, which checks it again (the
	/// leave text as the phone's RemoteKit wrote it, read by the engine's own code) and revokes the device, logged as
	/// unpaired on the phone.
	static func leave(app: App, relay: URL) {
		Check.section("through a real engine and the relay: a phone unpaired on the phone is revoked on its signed leave (#929)")
		let opened = app.call("devices.pairStart", within: 180)
		guard case let .success(window) = opened, let text = window["payload"]?.stringValue, let payload = try? PairingPayload.parse(text) else {
			return Check.expect(false, "a second pairing opened through the relay", "\(opened)")
		}
		let keys = PhoneKeys()
		guard let link = Relayed.join(relay, pairing: payload.pairing, secret: payload.secret, keys: keys) else { return Check.expect(false, "the second phone joins the relay's window") }
		let joined = RelayWire(link: link)
		let phone = Phone(relay: joined)
		guard let paired = phone.pair(payload: payload, keys: keys, team: team) else { return Check.expect(false, "the second phone's pairing handshake over the relay") }
		let digits = PairingSecrets.digits(secret: payload.secret, binding: paired.binding)
		var confirmed: Result<JSONValue, Refused> = .failure(Refused("not tried"))
		let confirmStart = Date()
		repeat {
			confirmed = app.call("devices.pairConfirm", .object([("digits", .string(digits))]))
			if case let .failure(why) = confirmed, why.description.contains("No phone is waiting") { usleep(200_000) } else { break }
		} while Date().timeIntervalSince(confirmStart) < 60
		guard case let .success(confirmation) = confirmed, let deviceText = confirmation["device"]?.stringValue, let device = DeviceID(deviceText) else {
			return Check.expect(false, "the second phone is paired", "\(confirmed)")
		}
		_ = phone.line()
		joined.close()
		guard let wire = Relayed.connect(relay, pairing: payload.pairing, device: device, keys: keys), let client = wire.client else {
			return Check.expect(false, "the second phone connects to the relay as a listed device")
		}
		let left = blocking { try await client.leave(mac: payload.identityKey) }
		Check.expect((try? left.get()) != nil, "the phone sends the relay its leave, with the notice for its Mac", "\(left)")
		var record: JSONValue?
		let began = Date()
		while record?["revokedAt"]?.integerValue == nil, Date().timeIntervalSince(began) < 30 {
			if case let .success(state) = app.call("devices.watch"), case let .array(devices)? = state["devices"] {
				record = devices.first { $0["id"]?.stringValue == device.text }
			}
			if record?["revokedAt"]?.integerValue == nil { usleep(250_000) }
		}
		Check.expect(record?["revokedAt"]?.integerValue != nil && record?["deviceKey"]?.stringValue == "", "the engine revokes the device on its notice, checked again against its own record, and the Devices page is told", record.map(JSON.text) ?? "none")
		if case let .success(log) = app.call("devices.log", .object([("device", .string(device.text))])), case let .array(entries)? = log["entries"] {
			let leaves = entries.filter { $0["method"]?.stringValue == "leave" }
			Check.expect(leaves.count == 1 && leaves.first?["summary"]?.stringValue == "Unpaired itself on the phone" && leaves.first?["path"]?.stringValue == "relay", "the devices' log says, once, that it unpaired itself on the phone", JSON.text(.array(leaves)))
		} else {
			Check.expect(false, "the devices' log is read")
		}
	}
}
