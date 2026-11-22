import Darwin
import Foundation
import RemoteKit

/// pi² Remote started as a process: exiting before it reads any key unless the engine started it (5.5's tests for
/// P7, docs/iphone.md 10), then started as the engine starts it, with this check as its engine.
enum Starts {
	/// Arguments and variables a copy might be given to steer it. pi² Remote reads none of them: it is given the data
	/// folder of its parent's environment, and none of what these name.
	static let steering = ["--relay", "wss://relay.example/v1", "--mode", "release", "--home", "/tmp/elsewhere"]
	static let steeringEnvironment = ["PI2_HOME": "/tmp/pi2-remote-elsewhere", "PI2_REMOTE_MODE": "release", "PI2_RELAY": "wss://relay.example/v1", "PI2_KEYCHAIN_SERVICE": "dev.pi2.credentials"]

	static func keyFilesExist(_ home: URL) -> Bool {
		FileManager.default.fileExists(atPath: home.appendingPathComponent("remote-keys.json").path) || FileManager.default.fileExists(atPath: home.appendingPathComponent("remote-devices.json").path)
	}

	static func refusals(helper: URL, home: URL) {
		Check.section("a pi² Remote the engine did not start exits before it reads any key (5.5, 10)")
		let enginePID = home.appendingPathComponent("engine.pid")
		try? String(getpid()).write(to: enginePID, atomically: true, encoding: .utf8)

		func refused(_ what: String, three: Int32?, saying: String) {
			let child = Child.spawn(helper.path, steering, environment: steeringEnvironment, three: three)
			let code = child.wait()
			Check.expect(code == 78, "\(what): pi² Remote exits", "exit \(code.map(String.init) ?? "none"); \(child.stderrText)")
			Check.expect(child.stderrText.contains(saying), "\(what): it says \(saying)", child.stderrText)
			child.stop()
		}

		refused("with no descriptor 3", three: nil, saying: "descriptor 3 is not open")

		// Every check passed, and still not the engine's helper (#675's security read A, M1): an agent's command is the
		// engine's child with a socket pair to it as its standard output, and `exec … 3>&1` keeps its pid. Here this check
		// is that engine: a shell it started execs pi² Remote with its standard output as descriptor 3, and sends nothing;
		// beside it, a pi² Remote on a socket pair of the check's that sends nothing, and one sent another line first.
		let (execMine, execTheirs) = socketPair()
		let execed = Child.spawn("/bin/bash", ["-c", "exec \"$0\" 3>&1", helper.path], environment: steeringEnvironment, stdout: execTheirs)
		close(execTheirs)
		let (silentMine, silentTheirs) = socketPair()
		let silent = Child.spawn(helper.path, steering, environment: steeringEnvironment, three: silentTheirs)
		close(silentTheirs)
		let (otherMine, otherTheirs) = socketPair()
		let other = Child.spawn(helper.path, steering, environment: steeringEnvironment, three: otherTheirs)
		close(otherTheirs)
		_ = Data("{\"id\":1,\"result\":{}}\n".utf8).withUnsafeBytes { write(otherMine, $0.baseAddress, $0.count) }
		let otherCode = other.wait(30)
		Check.expect(otherCode == 78 && other.stderrText.contains("is not the engine's start"), "a pi² Remote whose first line is not the engine's start exits at once", "exit \(otherCode.map(String.init) ?? "none"); \(other.stderrText)")
		let began = Date()
		let execCode = execed.wait(40), silentCode = silent.wait(40)
		let waited = Date().timeIntervalSince(began)
		Check.expect(execCode == 78 && execed.stderrText.contains("start did not come within 10 seconds"), "a pi² Remote an agent's command execs with its standard output as descriptor 3 passes every check, is sent no start, and exits", "exit \(execCode.map(String.init) ?? "none"); \(execed.stderrText)")
		Check.expect(silentCode == 78 && silent.stderrText.contains("start did not come within 10 seconds") && waited >= 8, "a pi² Remote on the engine's socket pair that is sent nothing exits after ten seconds", String(format: "%.0f s; %@", waited, silent.stderrText))
		for child in [execed, silent, other] { child.stop() }
		for end in [execMine, silentMine, otherMine] { close(end) }
		Check.expect(!keyFilesExist(home) && !FileManager.default.fileExists(atPath: home.appendingPathComponent("remote.log").path), "none of the three read or made a key, read a list of devices, or wrote anything")

		var pipeEnds: [Int32] = [0, 0]
		pipe(&pipeEnds)
		refused("with a pipe as descriptor 3", three: pipeEnds[0], saying: "is not a socket")
		close(pipeEnds[0])
		close(pipeEnds[1])

		let file = open("/dev/null", O_RDONLY)
		refused("with a file as descriptor 3", three: file, saying: "is not a socket")
		close(file)

		// A connection whose other end is another process, here nc: the check (its parent) names itself in engine.pid.
		let socketPath = home.appendingPathComponent("other.sock").path
		let nc = Child.spawn("/usr/bin/nc", ["-lU", socketPath])
		var connected: Int32 = -1
		for _ in 0 ..< 250 where connected < 0 {
			let attempt = socket(AF_UNIX, SOCK_STREAM, 0)
			var address = sockaddr_un()
			address.sun_family = sa_family_t(AF_UNIX)
			withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
			let done = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(attempt, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
			if done == 0 { connected = attempt } else {
				close(attempt)
				usleep(20_000)
			}
		}
		if connected >= 0 {
			refused("with a connection whose other end is another process than its parent", three: connected, saying: "not the process that started pi² Remote")
			close(connected)
		} else {
			Check.expect(false, "nc listened on a socket of the check's own")
		}
		nc.stop()

		let (mine, theirs) = socketPair()
		unlink(enginePID.path)
		refused("started on a socket pair, with no engine.pid", three: theirs, saying: "no engine.pid")
		try? "1".write(to: enginePID, atomically: true, encoding: .utf8)
		refused("started on a socket pair by a process engine.pid does not name", three: theirs, saying: "is not the engine engine.pid names")
		try? String(getpid() + 1).write(to: enginePID, atomically: true, encoding: .utf8)
		refused("started by a process that is not the engine engine.pid names", three: theirs, saying: "is not the engine engine.pid names")
		close(mine)
		close(theirs)

		Check.expect(!keyFilesExist(home), "none of those read or made a key: no key file, no list of devices in the data folder")
		let log = (try? String(contentsOf: home.appendingPathComponent("remote.log"), encoding: .utf8)) ?? ""
		Check.expect(log.isEmpty, "nor opened the data folder's log", log)
		try? String(getpid()).write(to: enginePID, atomically: true, encoding: .utf8)
	}

	/// pi² Remote started as the engine starts it: descriptor 3 one end of a socket pair this check made, its parent this
	/// check, which engine.pid names, with what would steer it in its arguments and environment.
	static func start(helper: URL, home: URL) -> (Child, FakeEngine) {
		try? String(getpid()).write(to: home.appendingPathComponent("engine.pid"), atomically: true, encoding: .utf8)
		let (mine, theirs) = socketPair()
		let child = Child.spawn(helper.path, steering, environment: steeringEnvironment, three: theirs)
		close(theirs)
		return (child, FakeEngine(descriptor: mine))
	}
}
