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
