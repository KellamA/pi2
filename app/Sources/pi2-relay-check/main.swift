
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

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--verbose" }
if arguments.isEmpty {
	Formats.run()
	await Sessions.run()
} else if arguments.count == 2, arguments[0] == "--relay", let url = URL(string: arguments[1]),
	url.scheme == "ws", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "")
{
	await ProtocolTest.run(relay: url)
} else {
	print("usage: pi2-relay-check [--verbose] [--relay ws://127.0.0.1:<port>/v1]   (a relay on this computer only)")
	exit(2)
}
print("\(Check.passed) passed, \(Check.failed.count) failed")
exit(Check.failed.isEmpty ? 0 : 1)
