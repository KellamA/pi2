import Darwin
import Foundation
import PeerKit

// Checks PeerKit and the pi2-peer helper (#504) on real connections to a Unix socket of its own, in a temporary
// folder: which process is at the other end of each, and whether it satisfies a given program's requirement. The
// stand-ins for "the app" are this program itself and /usr/bin/nc, each against its own code and the other's.
// Nothing is signed, nothing asks for a permission, and nothing outside the temporary folder is touched.

/// The nc this program started and has not stopped yet, stopped too if a check fails.
nonisolated(unsafe) var started: Process?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pi2-peer-check: \(message)\n".utf8))
    if let started, started.isRunning { started.terminate() }
    exit(1)
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { fail(message()) }
}

func step(_ message: String) { print("ok  \(message)") }

// A short path: macOS limits a socket's path to 103 bytes, and the usual temporary folder's is long.
let path = "/tmp/pi2-peer-\(getpid()).sock"
defer { unlink(path) }

func address() -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        _ = path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
    }
    return address
}

func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = address()
    return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}

unlink(path)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
check(server >= 0 && withAddress({ bind(server, $0, $1) }) == 0 && listen(server, 8) == 0, "could not listen on \(path): \(String(cString: strerror(errno)))")

/// A connection made from this process, and the engine's end of it.
func connectHere() -> (client: Int32, accepted: Int32) {
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    check(client >= 0 && withAddress({ connect(client, $0, $1) }) == 0, "could not connect: \(String(cString: strerror(errno)))")
    let accepted = accept(server, nil, nil)
    check(accepted >= 0, "could not accept")
    return (client, accepted)
}

/// A connection made by `/usr/bin/nc`, kept open until `close` is called, and the engine's end of it.
func connectFromNC() -> (accepted: Int32, pid: Int32, close: () -> Void) {
    let nc = Process()
    nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    nc.arguments = ["-U", path]
    let input = Pipe()
    nc.standardInput = input
    nc.standardOutput = FileHandle.nullDevice
    do { try nc.run() } catch { fail("could not start nc: \(error)") }
    started = nc
    let accepted = accept(server, nil, nil)
    check(accepted >= 0, "could not accept nc's connection")
    return (accepted, nc.processIdentifier, {
        // nc does not end when its input does; it is this program's own child, stopped by its process.
        nc.terminate()
        nc.waitUntilExit()
        try? input.fileHandleForWriting.close()
    })
}

let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
let nc = "/usr/bin/nc"

// ---- This process, against its own code and another's
let here = connectHere()
var verdict = PeerCheck.verdict(socket: here.accepted, app: me)
check(verdict.app && verdict.pid == getpid(), "this process is not taken for itself: \(verdict)")
verdict = PeerCheck.verdict(socket: here.accepted, app: nc)
check(!verdict.app && verdict.pid == getpid(), "this process is taken for nc: \(verdict)")
step("a connection from this process satisfies this program's requirement and not nc's")

// ---- Another process, against its own code and another's
let other = connectFromNC()
verdict = PeerCheck.verdict(socket: other.accepted, app: nc)
check(verdict.app && verdict.pid == other.pid, "nc is not taken for itself: \(verdict)")
verdict = PeerCheck.verdict(socket: other.accepted, app: me)
check(!verdict.app && verdict.pid == other.pid && verdict.why.contains("is not the app"), "nc is taken for this program: \(verdict)")
step("a connection from another process is judged by that process, not by who checks it")

// ---- What cannot be checked is never the app
other.close()
verdict = PeerCheck.verdict(socket: other.accepted, app: nc)
check(!verdict.app, "a process that has ended is still taken for the app: \(verdict)")
close(other.accepted)
verdict = PeerCheck.verdict(socket: here.accepted, app: "/tmp/pi2-peer-missing-\(getpid()).app")
check(!verdict.app && verdict.why.contains("could not be read"), "a missing app is satisfied: \(verdict)")
let notSocket = open(me, O_RDONLY)
verdict = PeerCheck.verdict(socket: notSocket, app: me)
check(!verdict.app && verdict.pid == nil, "a file that is not a socket has a peer: \(verdict)")
close(notSocket)
step("a process that has ended, a missing app and a descriptor that is not a socket are not the app")

// ---- The helper itself, as the engine starts it: the connection as descriptor 3, one line of JSON out
let helper = URL(fileURLWithPath: me).deletingLastPathComponent().appendingPathComponent("pi2-peer").path
check(FileManager.default.isExecutableFile(atPath: helper), "no pi2-peer beside this program; build it with swift build")

func runHelper(_ arguments: [String], socket: Int32) -> (status: Int32, output: String) {
    let output = Pipe()
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, socket, 3)
    let argv = ([helper] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    check(posix_spawn(&pid, helper, &actions, nil, argv, environ) == 0, "could not start pi2-peer")
    try? output.fileHandleForWriting.close()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return ((status >> 8) & 0xff, text)
}

func parsed(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

var run = runHelper([me], socket: here.accepted)
var answer = parsed(run.output)
check(run.status == 0 && answer["app"] as? Bool == true && answer["pid"] as? Int == Int(getpid()), "pi2-peer did not take this process for itself: \(run)")
run = runHelper([nc], socket: here.accepted)
answer = parsed(run.output)
check(run.status == 0 && answer["app"] as? Bool == false && (answer["why"] as? String)?.isEmpty == false, "pi2-peer took this process for nc: \(run)")
run = runHelper(["relative/path"], socket: here.accepted)
check(run.status == 2 && run.output.isEmpty, "pi2-peer took a relative path: \(run)")
step("pi2-peer answers one line of JSON about the connection it is given as descriptor 3")

close(here.client)
close(here.accepted)
close(server)
print("Peer checks passed.")
