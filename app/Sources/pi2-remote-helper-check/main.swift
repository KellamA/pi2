// Checks pi² Remote (#675, docs/pi2-remote.md, docs/iphone.md 10's tests for P7):
//
// - in this process: the listener's address ranges and limits, the minimum build, the Bonjour tag, the data folder,
//   a release build's Keychain and Secure Enclave logic with stand-ins for both, a development build's key files,
//   the control connection's session lines, the parent's code check on this process's own connection, that no source
//   file reads an argument or a variable, and that a development build's executable names no call that asks macOS for
//   anything (Keychain, Secure Enclave, Bonjour);
// - the helper as a process: it exits before reading any key when not started by the engine (no descriptor 3, a pipe,
//   a file, another process's socket, no engine.pid, another process's pid in it), whatever its arguments and
//   environment say; then, with this check as its engine and a phone made with RemoteKit, in loopback mode: the
//   listener on 127.0.0.1 alone, pairing (the exact challenge, wrong tries counted and not), attaching (`received`
//   left out), a session's lines both ways, resuming, sessionEnd, the resume window, revocation, its own list of devices;
// - with `--engine <engine/src/main.ts>`: a real engine on a temporary data folder, which starts the helper from a
//   stand-in app bundle, and a phone that pairs and attaches over loopback through it.
//
//   cd app && swift build --product pi2-remote-helper && swift build --product pi2-remote-helper-check
//   .build/debug/pi2-remote-helper-check [--engine ../engine/src/main.ts] [--verbose]
//
// It touches no Keychain, advertises nothing, listens on and connects to 127.0.0.1 alone, and works in a temporary
// folder it removes. It takes about two minutes, one of them the resume window.

import Darwin
import Foundation
import pi2_remote

var arguments = Array(CommandLine.arguments.dropFirst())
var engineMain: String?
var helperPath: String?
while let argument = arguments.first {
	arguments.removeFirst()
	switch argument {
	case "--verbose": Check.verbose = true
	case "--engine":
		guard let value = arguments.first else { print("--engine needs engine/src/main.ts"); exit(2) }
		engineMain = URL(fileURLWithPath: value).standardizedFileURL.path
		arguments.removeFirst()
	case "--helper":
		guard let value = arguments.first else { print("--helper needs a path"); exit(2) }
		helperPath = value
		arguments.removeFirst()
	default:
		print("unknown argument \(argument)\nusage: pi2-remote-helper-check [--engine <engine/src/main.ts>] [--helper <pi2-remote-helper>] [--verbose]")
		exit(2)
	}
}

guard BuildKind.compiledForDevelopment else {
	print("pi2-remote-helper-check checks a development build: build it without -c release")
	exit(2)
}

// pi² Remote in a development build reads its engine's data folder from the engine's own environment, as it was when
// the engine started: this check is its engine, so it starts itself again with a temporary data folder in its own.
let marker = "PI2_REMOTE_CHECK_ROOT"
if ProcessInfo.processInfo.environment[marker] == nil {
	let root = temporaryFolder("p2rc")
	let home = root.appendingPathComponent("home", isDirectory: true)
	try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
	var environment = ProcessInfo.processInfo.environment
	environment[marker] = root.path
	environment["PI2_HOME"] = home.path
	let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
	let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
	execve(AppBundle.ownExecutable()!.path, argv, envp)
	print("the check could not start itself again: \(String(cString: strerror(errno)))")
	exit(1)
}

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment[marker]!, isDirectory: true)
let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI2_HOME"]!, isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

let built = URL(fileURLWithPath: helperPath ?? AppBundle.ownExecutable()!.deletingLastPathComponent().appendingPathComponent("pi2-remote-helper").path)
guard FileManager.default.isExecutableFile(atPath: built.path) else {
	print("no pi² Remote at \(built.path): swift build --product pi2-remote-helper first")
	exit(2)
}
// The helper as build.sh puts it in the app's bundle.
let bundled = root.appendingPathComponent("pi2 check.app/Contents/Helpers/pi² Remote.app/Contents/MacOS/pi² Remote")
try! FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.copyItem(at: built, to: bundled)

let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("pi2-remote")
Units.run(sources: sources, helper: built)
Starts.refusals(helper: bundled, home: home)
Flows.run(helper: bundled, home: home)
if let engineMain { RealEngine.run(engineMain: engineMain, helper: built, root: root) }

try? FileManager.default.removeItem(at: root)
print("\(Check.passed) passed, \(Check.failed.count) failed")
exit(Check.failed.isEmpty ? 0 : 1)
