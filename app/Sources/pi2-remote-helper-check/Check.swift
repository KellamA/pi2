import Darwin
import Foundation

/// What the check found, and how it says so: one line a failure, a count at the end.
enum Check {
	nonisolated(unsafe) static var passed = 0
	nonisolated(unsafe) static var failed: [String] = []
	nonisolated(unsafe) static var verbose = false

	static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
		if condition {
			passed += 1
			if verbose { print("  ok \(what)") }
		} else {
			let more = detail()
			failed.append(what)
			print("FAIL \(what)\(more.isEmpty ? "" : ": \(more)")")
		}
	}

	static func section(_ name: String) { print("-- \(name)") }

	/// Stops the check at once: something it needs to go on did not happen.
	/// Run before the check stops early: its temporary folder goes.
	nonisolated(unsafe) static var cleanup: () -> Void = {}

	static func stop(_ why: String) -> Never {
		cleanup()
		print("FAIL \(why)")
		print("\(passed) passed, \(failed.count + 1) failed (stopped)")
		exit(1)
	}
}

/// Waits for `descriptor` to be readable, up to `seconds`.
func readable(_ descriptor: Int32, within seconds: Double) -> Bool {
	var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
	return poll(&poller, 1, Int32(seconds * 1000)) > 0
}

/// A temporary folder of the check's own, readable by this user alone.
func temporaryFolder(_ name: String) -> URL {
	let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
	// Short: an engine's socket in it must fit a Unix socket's 104 bytes.
	let folder = base.appendingPathComponent("\(name)-\(String(UInt32.random(in: 0 ... .max), radix: 36))", isDirectory: true)
	try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
	return folder
}

/// A process this check started, with what it wrote to standard error.
final class Child {
	let pid: pid_t
	private let errors: Int32
	private(set) var stderr = Data()
	private(set) var status: Int32?

	init(pid: pid_t, errors: Int32) {
		self.pid = pid
		self.errors = errors
	}

	/// Starts `executable` with `arguments` and `environment`, standard input from nothing, standard output nowhere,
	/// standard error to a pipe, and descriptor 3 as `three` when given. No other descriptor is inherited.
	static func spawn(_ executable: String, _ arguments: [String] = [], environment: [String: String] = [:], three: Int32? = nil, stdout: Int32? = nil) -> Child {
		var pipeEnds: [Int32] = [0, 0]
		guard pipe(&pipeEnds) == 0 else { Check.stop("a pipe could not be made") }
		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
		if let stdout { posix_spawn_file_actions_adddup2(&actions, stdout, 1) } else { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
		posix_spawn_file_actions_adddup2(&actions, pipeEnds[1], 2)
		if let three { posix_spawn_file_actions_adddup2(&actions, three, 3) }
		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
		let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
		let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
		var pid: pid_t = 0
		let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
		for pointer in argv { free(pointer) }
		for pointer in envp { free(pointer) }
		posix_spawn_file_actions_destroy(&actions)
		posix_spawnattr_destroy(&attributes)
		close(pipeEnds[1])
		guard status == 0 else { Check.stop("\(executable) could not be started (\(String(cString: strerror(status))))") }
		_ = fcntl(pipeEnds[0], F_SETFL, fcntl(pipeEnds[0], F_GETFL) | O_NONBLOCK)
		return Child(pid: pid, errors: pipeEnds[0])
	}

	private func drain() {
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = read(errors, &buffer, buffer.count)
			guard count > 0 else { return }
			stderr.append(contentsOf: buffer[0 ..< count])
		}
	}

	var stderrText: String {
		drain()
		return String(decoding: stderr, as: UTF8.self)
	}

	/// Waits for it to end, up to `seconds`; its exit code, or nil if it is still running.
	@discardableResult
	func wait(_ seconds: Double = 30) -> Int32? {
		if let status { return status }
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			drain()
			var raw: Int32 = 0
			let done = waitpid(pid, &raw, WNOHANG)
			if done == pid {
				drain()
				let exited = raw & 0x7F == 0
				status = exited ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
				close(errors)
				return status
			}
			usleep(20_000)
		}
		return nil
	}

	var running: Bool { status == nil && kill(pid, 0) == 0 && wait(0) == nil }

	func stop() {
		guard status == nil else { return }
		kill(pid, SIGTERM)
		if wait(10) == nil {
			kill(pid, SIGKILL)
			wait(10)
		}
	}
}
