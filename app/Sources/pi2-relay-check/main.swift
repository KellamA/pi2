
// Checks RemoteKit's relay client (`RemoteKit/Relay`, #678).
//
// With no argument: the relay's messages as the client writes and reads them, the proof's text, the join's client
// data hash (one value shared with relay/test/join-hash.test.ts), the backoff, the memory of items taken, and the client
// against a relay the check plays itself, in memory, on a clock it moves. No network, no key store.
//
//   cd app && swift build --product pi2-relay-check && .build/debug/pi2-relay-check
//
// With `--relay <ws://127.0.0.1:port/v1>`: the protocol test (iphone.md 10), the client against the relay itself, which
// scripts/relay-protocol-test starts on this computer for it and stops after. Never a deployed relay.
//
// With `--sealed <ws://…> --markers <file> --out <file>`, or `--plant <ws://…> --out <file>`: the marker session of the
// sealed-bytes check (#683, Sealed.swift), which `scripts/relay-protocol-test --sealed` runs against the recording relay.

import Foundation

/// A relay on this computer, and only that.
func local(_ text: String) -> URL? {
	guard let url = URL(string: text), url.scheme == "ws", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "") else { return nil }
	return url
}

let arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--verbose" }
if arguments.isEmpty {
	Formats.run()
	await Sessions.run()
} else if arguments.count == 2, arguments[0] == "--relay", let url = local(arguments[1]) {
	await ProtocolTest.run(relay: url)
} else if arguments.count == 6, arguments[0] == "--sealed", let url = local(arguments[1]), arguments[2] == "--markers", arguments[4] == "--out" {
	await SealedSession.run(relay: url, markers: arguments[3], out: arguments[5])
} else if arguments.count == 4, arguments[0] == "--plant", let url = local(arguments[1]), arguments[2] == "--out" {
	await SealedSession.plant(relay: url, out: arguments[3])
} else {
	print("""
		usage: pi2-relay-check [--verbose] [--relay ws://127.0.0.1:<port>/v1]
		       pi2-relay-check --sealed ws://127.0.0.1:<port>/v1 --markers <file> --out <file>
		       pi2-relay-check --plant ws://127.0.0.1:<port>/v1 --out <file>
		(a relay on this computer only)
		""")
	exit(2)
}
print("\(Check.passed) passed, \(Check.failed.count) failed")
exit(Check.failed.isEmpty ? 0 : 1)
